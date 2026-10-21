#!/usr/bin/env bash
# Shared library for the libvirt lab harness (scripts/lab/virt/{up,down,status}.sh).
#
# The lab is libvirt guests on THIS laptop, on two private libvirt networks that are never bridged
# to the house LAN. Nothing here talks to the real hosts (poseidon / hercules-nas); rationale is in
# docs/decisions.md §1.1 + §2.4 and docs/lab.md.
#
# Sourced, never executed. Callers parse their own arguments and set DRY=1 for --dry-run; run()
# then prints the command instead of executing it.
#
# The libvirt daemon is SOCKET-ACTIVATED here (libvirtd.socket) and exits when idle
# (--timeout 120). That is normal, so this harness gates on a live connection test
# (libvirt_ready), never on `systemctl is-active libvirtd`.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
LAB_VIRT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_VIRT_LIB_DIR/../../.." && pwd)"
GUESTS_TABLE="${GUESTS_TABLE:-$LAB_VIRT_LIB_DIR/guests.tsv}"
CLOUD_INIT_DIR="$LAB_VIRT_LIB_DIR/cloud-init"
NWFILTER_DIR="$LAB_VIRT_LIB_DIR/nwfilter"
TALOS_LAB_INPUTS="${TALOS_LAB_INPUTS:-$REPO_ROOT/talos/inputs.lab.env}"
TALOS_LAB_OUT="${TALOS_LAB_OUT:-$REPO_ROOT/talos/out/lab}"

# ---------------------------------------------------------------------------
# libvirt connection
# ---------------------------------------------------------------------------
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
VIRSH_TIMEOUT="${VIRSH_TIMEOUT:-20}"
VIRSH_BIN="${VIRSH_BIN:-virsh}"
# Guest disk cache. `unsafe` ignores the guest's flushes: with `none`, every etcd fsync on the control
# plane waited behind whatever else was saturating the workstation's NVMe, etcd missed its deadlines
# and the API server dropped out mid-install (2026-10-20). A host crash loses the guests' disks, which
# are disposable. `LAB_DISK_CACHE=none` restores durable writes.
LAB_DISK_CACHE="${LAB_DISK_CACHE:-unsafe}"

# ---------------------------------------------------------------------------
# What this harness owns. down.sh may remove NOTHING else.
# ---------------------------------------------------------------------------
LAB_DOMAIN_PREFIX="lab-"
NET_LAB="homelab-lab"
NET_STORAGE="homelab-lab-storage"
NWFILTER_NAME="homelab-lab-isolate"
# The 10 GbE storage-link stand-in for the two nested fixtures (lab-pve <-> lab-truenas): a second,
# isolated network that carries only their extra NICs. Owned by the fixture scripts, not by guests.tsv.
NET_LINK="homelab-lab-link"

# Bridge names: at most 15 characters (kernel IFNAMSIZ), and they must match a prefix the host
# firewall already accepts. UFW's input policy is DROP and /etc/ufw/before.rules only allows
# libvirt bridges by name (`-i mlt+`); a bridge outside that prefix gets no DHCP/DNS from dnsmasq.
LAB_BRIDGE="mlt-lab"
STORAGE_BRIDGE="mlt-labstor"
LINK_BRIDGE="mlt-link"

# Addressing — docs/decisions.md §2.4. 10.99.100.0/24 and 10.99.101.0/30 are disjoint from
# 10.0.0.0/16 (house LAN) and 10.10.0.0/16 (server VLAN), so they can never collide with the real
# servers, and NAT keeps the house LAN away from the guests.
LAB_SUBNET="10.99.100.0/24"
LAB_GATEWAY="10.99.100.1"
LAB_DHCP_START="10.99.100.200"
LAB_DHCP_END="10.99.100.250"
LAB_METALLB_POOL="10.99.100.100-10.99.100.199"
STORAGE_SUBNET="10.99.101.0/30"
STORAGE_HOST_IP="10.99.101.1"
STORAGE_NAS_IP="10.99.101.2"
STORAGE_NETMASK="255.255.255.252"

# Where disks, ISOs and generated XML live. This directory MUST be traversable by the qemu user
# (libvirt-qemu): the system libvirt daemon runs qemu as that user. $HOME is mode 0700 here, so a
# directory under it can never be used — qemu would not be able to open the disk. /var/tmp is
# world-traversable and survives reboots.
LAB_VIRT_DIR="${LAB_VIRT_DIR:-/var/tmp/homelab-lab-virt}"

# Runtime behaviour knobs.
DRY="${DRY:-0}"
WITH_NWFILTER="${WITH_NWFILTER:-1}"
# 1 = each Talos node gets its guests.tsv address, default route and resolver as static config
# (talos_node_config), so the install does not depend on DHCP. 0 = DHCP only, as production.
STATIC_NET="${STATIC_NET:-1}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
RAM_HEADROOM_MIB="${RAM_HEADROOM_MIB:-1024}"

# Pinned guest images. Versions are verified against versions.yaml / a dated Debian build directory
# so the URL cannot silently drift. Recorded provenance (2026-10-16):
#   Talos  v1.14.4  metal-amd64.iso                 364195840 bytes, sha256 06b38dc4…b3230
#   Debian 12       debian-12-genericcloud-amd64-…qcow2  349044736 bytes, sha512 56c0bd55…c2b37
# The Debian SHA512SUMS for that build lives beside the image at
#   https://cloud.debian.org/images/cloud/bookworm/20261015-2632/SHA512SUMS
TALOS_VERSION_DEFAULT="v1.14.4"
DEBIAN_BUILD="20261015-2632"
DEBIAN_BASE_NAME="debian-12-genericcloud-amd64-${DEBIAN_BUILD}.qcow2"
DEBIAN_BASE_URL="https://cloud.debian.org/images/cloud/bookworm/${DEBIAN_BUILD}/${DEBIAN_BASE_NAME}"
DEBIAN_BASE_SHA512="56c0bd55b6623f2739f377e983d2872e7b208d0cb9c3ba4e93d3f72929026da03637c598b3bd472b29998c31c8a4c17d8e6ae1c556852a8b83a66a09bf5c2b37"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33mwarning:\033[0m %s\n' "$*" >&2; }
err()  { printf '   \033[31merror:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# run <cmd...> — execute, or print only, in --dry-run.
run() {
  if [ "$DRY" = 1 ]; then
    printf '   [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
undash() { if [ "$1" = "-" ]; then printf '%s' ""; else printf '%s' "$1"; fi; }

yaml_get() { awk -F'"' -v key="$1" '$0 ~ "^  " key ":" { print $2; exit }' "$REPO_ROOT/versions.yaml"; }

# read <path> — write stdin to <path>, or print it in --dry-run.
write_artifact() {
  local path="$1"
  if [ "$DRY" = 1 ]; then
    printf '\n   [dry-run] would write %s:\n' "$path"
    sed 's/^/      /'
  else
    mkdir -p "$(dirname "$path")"
    cat > "$path"
  fi
}

mem_available_mib() { awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo; }

is_lab_domain() {
  case "$1" in
    "$LAB_DOMAIN_PREFIX"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# libvirt availability
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing tool: $1${2:+ ($2)}"
}

libvirt_ready() {
  command -v "$VIRSH_BIN" >/dev/null 2>&1 || return 1
  timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" list >/dev/null 2>&1
}

libvirt_fix_hint() {
  err "cannot reach libvirt at $LIBVIRT_URI"
  note "the socket is expected to be enabled and socket-activated:"
  note "  systemctl is-enabled libvirtd.socket       # expect: enabled"
  note "  virsh -c $LIBVIRT_URI list                 # expect: a table (not an error)"
  note "  id -nG | tr ' ' '\n' | grep -x libvirt      # expect: libvirt (log out/in after joining)"
  note "no sudo is used by this harness, and the daemon self-exiting when idle is normal."
}

# check_libvirt <hard|soft> — 'soft' is used by --dry-run so a plan can still be printed.
check_libvirt() {
  local mode="${1:-hard}"
  if libvirt_ready; then
    note "libvirt: $LIBVIRT_URI reachable ($("$VIRSH_BIN" --version 2>/dev/null))"
    return 0
  fi
  if [ "$mode" = soft ]; then
    warn "libvirt at $LIBVIRT_URI is not reachable — printing the plan only (--dry-run)."
    libvirt_fix_hint
    return 0
  fi
  libvirt_fix_hint
  return 1
}

# Queries: never dry-run aware (they only read), never fatal.
virsh_q() { timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" "$@" 2>/dev/null; }

domain_exists()  { virsh_q dominfo "$1" >/dev/null 2>&1; }
network_exists() { virsh_q net-info "$1" >/dev/null 2>&1; }
network_active() { [ "$(virsh_q net-info "$1" | awk '/^Active:/{print $2}')" = "yes" ]; }
domain_running() { [ "$(virsh_q domstate "$1" 2>/dev/null || true)" = "running" ]; }
nwfilter_exists() { virsh_q nwfilter-dumpxml "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# guest table
# ---------------------------------------------------------------------------
GUEST_NAMES=()
GUEST_KIND=()
GUEST_VCPU=()
GUEST_MEM=()
GUEST_DISK=()
GUEST_MAC_LAB=()
GUEST_IP_LAB=()
GUEST_MAC_STORAGE=()
GUEST_IP_STORAGE=()

load_guests() {
  [ -r "$GUESTS_TABLE" ] || die "cannot read guest table: $GUESTS_TABLE"
  GUEST_NAMES=(); GUEST_KIND=(); GUEST_VCPU=(); GUEST_MEM=(); GUEST_DISK=()
  GUEST_MAC_LAB=(); GUEST_IP_LAB=(); GUEST_MAC_STORAGE=(); GUEST_IP_STORAGE=()

  local name kind vcpu mem disk mac_lab ip_lab mac_stor ip_stor
  while read -r name kind vcpu mem disk mac_lab ip_lab mac_stor ip_stor; do
    case "$name" in ''|'#'*) continue ;; esac
    is_lab_domain "$name" || die "guest '$name' must start with '$LAB_DOMAIN_PREFIX' ($GUESTS_TABLE)"
    case "$kind" in
      talos|debian) : ;;
      *) die "guest '$name' has unknown kind '$kind' (expected talos|debian)" ;;
    esac
    [ -n "$mac_lab" ] && [ -n "$ip_lab" ] || die "guest '$name' needs mac_lab and ip_lab"
    GUEST_NAMES+=("$name");          GUEST_KIND+=("$kind")
    GUEST_VCPU+=("$vcpu");           GUEST_MEM+=("$mem");    GUEST_DISK+=("$disk")
    GUEST_MAC_LAB+=("$mac_lab");     GUEST_IP_LAB+=("$ip_lab")
    GUEST_MAC_STORAGE+=("$(undash "$mac_stor")"); GUEST_IP_STORAGE+=("$(undash "$ip_stor")")
  done < "$GUESTS_TABLE"

  [ "${#GUEST_NAMES[@]}" -gt 0 ] || die "guest table $GUESTS_TABLE has no rows"
}

guest_index() {
  local want="$1" i
  for i in "${!GUEST_NAMES[@]}"; do
    if [ "${GUEST_NAMES[$i]}" = "$want" ]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

SELECTED=()

select_all() { SELECTED=("${GUEST_NAMES[@]}"); }

# select_only <comma,space separated names>
select_only() {
  local want="$1" tok i ok=0
  local -a toks=()
  IFS=', ' read -r -a toks <<<"$want"
  for tok in "${toks[@]}"; do
    [ -n "$tok" ] || continue
    ok=0
    for i in "${!GUEST_NAMES[@]}"; do
      if [ "${GUEST_NAMES[$i]}" = "$tok" ]; then ok=1; break; fi
    done
    [ "$ok" = 1 ] || die "unknown guest: $tok (see $GUESTS_TABLE)"
    local s seen=0
    for s in "${SELECTED[@]+"${SELECTED[@]}"}"; do
      [ "$s" = "$tok" ] && seen=1
    done
    [ "$seen" = 1 ] || SELECTED+=("$tok")
  done
  [ "${#SELECTED[@]}" -gt 0 ] || die "--only needs at least one guest name"
}

selected_indexes() {
  local -a out=()
  local n i
  for n in "${SELECTED[@]}"; do
    for i in "${!GUEST_NAMES[@]}"; do
      if [ "${GUEST_NAMES[$i]}" = "$n" ]; then out+=("$i"); break; fi
    done
  done
  if [ "${#out[@]}" -gt 0 ]; then printf '%s\n' "${out[@]}"; fi
}

selected_mem_mib() {
  local total=0 i
  while read -r i; do total=$((total + GUEST_MEM[i])); done < <(selected_indexes)
  printf '%d' "$total"
}

selected_disk_gib() {
  local total=0 i
  while read -r i; do total=$((total + GUEST_DISK[i])); done < <(selected_indexes)
  printf '%d' "$total"
}

# ---------------------------------------------------------------------------
# resource preflight (RAM is the binding constraint on this host)
# ---------------------------------------------------------------------------
plan_resources() {
  local i want avail free_mib
  want="$(selected_mem_mib)"
  avail="$(mem_available_mib)"
  log "resource plan"
  note "selected guests:"
  while read -r i; do
    printf '     %-14s %s vCPU  %5s MiB  %3s GiB disk  (%s)\n' \
      "${GUEST_NAMES[$i]}" "${GUEST_VCPU[$i]}" "${GUEST_MEM[$i]}" "${GUEST_DISK[$i]}" "${GUEST_KIND[$i]}"
  done < <(selected_indexes)
  note "requested RAM: ${want} MiB   host available: ${avail} MiB   headroom: ${RAM_HEADROOM_MIB} MiB"
  note "guest disks: $LAB_VIRT_DIR  (needs ~$(selected_disk_gib) GiB)"
  free_mib="$(df -Pm "$(dirname "$LAB_VIRT_DIR")" 2>/dev/null | awk 'NR==2{print $4}' || true)"
  [ -n "$free_mib" ] && note "filesystem free: ${free_mib} MiB"
}

# check_ram <hard|soft> — refuse to start more than the host can hold, unless --force.
check_ram() {
  local mode="${1:-hard}" want avail budget
  want="$(selected_mem_mib)"
  avail="$(mem_available_mib)"
  budget=$((avail - RAM_HEADROOM_MIB))
  if [ "$want" -le "$budget" ]; then return 0; fi
  warn "selected guests want ${want} MiB but only ${budget} MiB is safely free (${avail} MiB available minus ${RAM_HEADROOM_MIB} MiB headroom)."
  note "run them one at a time (docs/lab.md 'libvirt guests'), or free memory first, or pass --force."
  if [ "$mode" = soft ]; then
    warn "continuing because of --dry-run"
    return 0
  fi
  return 1
}

kind_is_running() {
  command -v kind >/dev/null 2>&1 || return 1
  kind get clusters 2>/dev/null | grep -q .
}

warn_about_kind() {
  if kind_is_running; then
    warn "a kind cluster is running — it is one of the biggest RAM consumers here."
    note "consider: just lab-down   (stops the kind lab) before starting libvirt guests."
  fi
}

# ---------------------------------------------------------------------------
# paths on disk
# ---------------------------------------------------------------------------
ensure_dirs() {
  run mkdir -p "$LAB_VIRT_DIR/images" "$LAB_VIRT_DIR/xml" "$LAB_VIRT_DIR/seed"
  if [ "$DRY" != 1 ]; then
    chmod 0755 "$LAB_VIRT_DIR"
  fi
  case "$LAB_VIRT_DIR" in
    "$HOME"|"$HOME"/*)
      warn "LAB_VIRT_DIR is under \$HOME, which is mode 0700 here."
      note "the qemu user (libvirt-qemu) will not be able to open disks there; use a world-traversable path."
      ;;
  esac
}

guest_disk_path()   { printf '%s/%s.qcow2' "$LAB_VIRT_DIR" "$1"; }
guest_seed_iso_path() { printf '%s/%s-seed.iso' "$LAB_VIRT_DIR" "$1"; }
talos_iso_path()    { printf '%s/images/talos-%s-metal-amd64.iso' "$LAB_VIRT_DIR" "$(talos_version)"; }
talos_version() {
  local v
  v="$(yaml_get talos)"
  printf '%s' "${v:-$TALOS_VERSION_DEFAULT}"
}

# ---------------------------------------------------------------------------
# image acquisition
# ---------------------------------------------------------------------------
download() {  # <url> <dest> <expected-bytes-or-empty>
  local url="$1" dest="$2" want="$3" have=""
  if [ -f "$dest" ]; then
    have="$(stat -c '%s' "$dest")"
    if [ -z "$want" ] || [ "$have" = "$want" ]; then
      note "have $(basename "$dest") ($have bytes)"
      return 0
    fi
    warn "$(basename "$dest") is $have bytes, expected $want — re-downloading"
    run rm -f "$dest"
  fi
  note "downloading $url"
  run curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$dest" "$url"
}

sha512_of() { sha512sum "$1" | awk '{print $1}'; }

ensure_talos_iso() {
  local iso url sums want have
  url="https://github.com/siderolabs/talos/releases/download/$(talos_version)/metal-amd64.iso"
  iso="$(talos_iso_path)"
  if [ "$DRY" != 1 ] && [ -f "$iso" ]; then
    note "have $(basename "$iso")"
    return 0
  fi
  download "$url" "$iso" ""
  if [ "$DRY" = 1 ]; then return 0; fi
  sums="$(mktemp)"
  if curl -fsSL --retry 3 -o "$sums" "https://github.com/siderolabs/talos/releases/download/$(talos_version)/sha256sum.txt"; then
    want="$(awk -v n="metal-amd64.iso" '{f=$NF; sub(/^\*/,"",f); if (f==n) print $1}' "$sums" | head -1)"
    if [ -n "$want" ]; then
      have="$(sha256sum "$iso" | awk '{print $1}')"
      [ "$want" = "$have" ] || die "sha256 mismatch for $(basename "$iso")"
      note "sha256 ok ($have)"
    else
      warn "no sha256 entry for metal-amd64.iso"
    fi
  else
    warn "could not fetch sha256sum.txt (continuing)"
  fi
  rm -f "$sums"
}

ensure_debian_base() {
  local base
  base="$LAB_VIRT_DIR/images/$DEBIAN_BASE_NAME"
  if [ "$DRY" != 1 ] && [ -f "$base" ]; then
    note "have $DEBIAN_BASE_NAME"
    return 0
  fi
  download "$DEBIAN_BASE_URL" "$base" "349044736"
  if [ "$DRY" = 1 ]; then return 0; fi
  local have
  have="$(sha512_of "$base")"
  [ "$have" = "$DEBIAN_BASE_SHA512" ] || die "sha512 mismatch for $DEBIAN_BASE_NAME"
  note "sha512 ok ($have)"
}

ensure_images() {
  local want_talos=0 want_debian=0 i
  while read -r i; do
    case "${GUEST_KIND[$i]}" in
      talos)  want_talos=1 ;;
      debian) want_debian=1 ;;
    esac
  done < <(selected_indexes)
  [ "$want_talos" = 1 ] && ensure_talos_iso
  [ "$want_debian" = 1 ] && ensure_debian_base
  return 0
}

# ---------------------------------------------------------------------------
# Talos configs (reuse scripts/talos/, lab inputs only)
# ---------------------------------------------------------------------------
ensure_talos_configs() {
  [ -f "$TALOS_LAB_INPUTS" ] || die "missing lab inputs: $TALOS_LAB_INPUTS"
  local args=()
  [ "$DRY" = 1 ] && args+=(--dry-run)
  note "generating Talos configs: TALOS_INPUTS=$(basename "$TALOS_LAB_INPUTS") TALOS_OUT_DIR=$TALOS_LAB_OUT"
  TALOS_INPUTS="$TALOS_LAB_INPUTS" TALOS_OUT_DIR="$TALOS_LAB_OUT" \
    run "$REPO_ROOT/scripts/talos/gen-configs.sh" "${args[@]+"${args[@]}"}"
  if [ "$DRY" != 1 ]; then
    TALOS_INPUTS="$TALOS_LAB_INPUTS" TALOS_OUT_DIR="$TALOS_LAB_OUT" \
      "$REPO_ROOT/scripts/talos/validate.sh" >/dev/null \
      || die "talosctl validate failed for the lab configs"
    note "configs validated (talosctl validate --mode metal)"
    # gen-configs.sh keeps existing output, so configs generated before WORKER_PATCH="" still carry
    # the 90 GiB UserVolumeConfig that the 40 GiB lab worker cannot provision.
    if grep -q 'kind: UserVolumeConfig' "$TALOS_LAB_OUT/worker.yaml" \
       && ( # shellcheck source=/dev/null
            . "$TALOS_LAB_INPUTS"; [ -z "${WORKER_PATCH-x}" ] ); then
      die "stale $TALOS_LAB_OUT/worker.yaml (has a UserVolumeConfig, but the lab sets WORKER_PATCH=\"\");" \
          "regenerate: TALOS_INPUTS=$TALOS_LAB_INPUTS TALOS_OUT_DIR=$TALOS_LAB_OUT scripts/talos/gen-configs.sh --force"
    fi
  fi
}

# ---------------------------------------------------------------------------
# XML
# ---------------------------------------------------------------------------
nwfilter_xml() { cat "$NWFILTER_DIR/$NWFILTER_NAME.xml"; }

network_xml_lab() {
  local hosts="" i
  for i in "${!GUEST_NAMES[@]}"; do
    [ -n "${GUEST_IP_LAB[$i]}" ] || continue
    hosts+="      <host mac='${GUEST_MAC_LAB[$i]}' name='${GUEST_NAMES[$i]}' ip='${GUEST_IP_LAB[$i]}'/>"$'\n'
  done
  cat <<EOF
<network>
  <name>${NET_LAB}</name>
  <!-- Lab network. NAT for outbound image/package pulls ONLY; never bridged to the house LAN, so
       libvirt forwards no inbound connection and no LAN device can reach a guest. 10.99.100.0/24
       is disjoint from 10.0.0.0/16 and 10.10.0.0/16 (docs/decisions.md §2.4), so it can never
       collide with, or route as, the real servers. -->
  <bridge name='${LAB_BRIDGE}' stp='on' delay='0'/>
  <domain name='${NET_LAB}' localOnly='yes'/>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address='${LAB_GATEWAY}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${LAB_DHCP_START}' end='${LAB_DHCP_END}'/>
${hosts}    </dhcp>
  </ip>
</network>
EOF
}

network_xml_storage() {
  cat <<EOF
<network>
  <name>${NET_STORAGE}</name>
  <!-- Isolated network (no forward element) modelling the dedicated point-to-point storage link.
       A /30 gives exactly two endpoints: ${STORAGE_HOST_IP} is the libvirt bridge, i.e. the lab's
       stand-in for the Proxmox end, and ${STORAGE_NAS_IP} is the NAS. No DHCP and no gateway on
       purpose. This network stays at MTU 1500; the jumbo-frame link is the separate NET_LINK network below.
       Bridge naming constraints (IFNAMSIZ + the UFW allow-list) are documented next to
       LAB_BRIDGE / STORAGE_BRIDGE at the top of this file. -->
  <bridge name='${STORAGE_BRIDGE}' stp='on' delay='0'/>
  <ip address='${STORAGE_HOST_IP}' netmask='${STORAGE_NETMASK}'/>
</network>
EOF
}

network_xml_link() {
  cat <<EOF
<network>
  <name>${NET_LINK}</name>
  <!-- Isolated L2 segment for the nested fixtures' storage NICs (no forward element, no DHCP, no
       NAT, no host address): lab-pve's vmbr1 and lab-truenas's port talk to each other and to nothing
       else. MTU 9000 is real here (a libvirt bridge carries jumbo frames), which is what lets the
       fixture prove the 10 GbE link's MTU. Bridge name: see LAB_BRIDGE. -->
  <mtu size='9000'/>
  <bridge name='${LINK_BRIDGE}' stp='off' delay='0'/>
</network>
EOF
}

ensure_link_network() {
  ensure_network "$NET_LINK" network_xml_link
}

# domain_xml <index>
domain_xml() {
  local i="$1"
  local name kind vcpu mem disk boot media disk_path filter nics iface2
  name="${GUEST_NAMES[$i]}"; kind="${GUEST_KIND[$i]}"
  vcpu="${GUEST_VCPU[$i]}"; mem="${GUEST_MEM[$i]}"; disk="${GUEST_DISK[$i]}"
  disk_path="$(guest_disk_path "$name")"
  # Talos boots its ISO from a SATA CD-ROM. The Debian seed is a read-only virtio disk instead: the
  # genericcloud image runs the cloud kernel, which does not see a SATA CD-ROM, so cloud-init found no
  # NoCloud datasource, configured no network and the guest never asked for a lease (2026-10-20).
  # NoCloud finds the `cidata` label on any block device.
  if [ "$kind" = "talos" ]; then
    boot="    <boot dev='hd'/>
    <boot dev='cdrom'/>"
    media="    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$(talos_iso_path)'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>"
  else
    boot="    <boot dev='hd'/>"
    media="    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='$(guest_seed_iso_path "$name")'/>
      <target dev='vdb' bus='virtio'/>
      <readonly/>
    </disk>"
  fi
  filter=""
  if [ "$WITH_NWFILTER" = 1 ]; then
    filter="      <filterref filter='${NWFILTER_NAME}'/>"$'\n'
  fi
  nics=1
  iface2=""
  if [ -n "${GUEST_IP_STORAGE[$i]}" ]; then
    nics=2
    iface2="    <interface type='network'>"$'\n'
    iface2+="      <source network='${NET_STORAGE}'/>"$'\n'
    iface2+="      <mac address='${GUEST_MAC_STORAGE[$i]}'/>"$'\n'
    iface2+="      <model type='virtio'/>"$'\n'
    iface2+="$filter"
    iface2+="    </interface>"$'\n'
  fi
  cat <<EOF
<domain type='kvm'>
  <name>${name}</name>
  <uuid>$(domain_uuid "${name}")</uuid>
  <description>homelab lab guest (${kind}) — disposable, created by scripts/lab/virt/up.sh ($nics NIC(s), ${disk} GiB).</description>
  <memory unit='MiB'>${mem}</memory>
  <currentMemory unit='MiB'>${mem}</currentMemory>
  <vcpu placement='static'>${vcpu}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
${boot}
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='${LAB_DISK_CACHE}' discard='unmap'/>
      <source file='${disk_path}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
${media}
    <interface type='network'>
      <source network='${NET_LAB}'/>
      <mac address='${GUEST_MAC_LAB[$i]}'/>
      <model type='virtio'/>
${filter}    </interface>
${iface2}    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <!-- The Talos schematic carries qemu-guest-agent, which waits for this channel and holds the node
         in "booting" without it (docs/decisions.md §3.5). Harmless on the Debian guest. -->
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <video>
      <model type='none'/>
    </video>
  </devices>
</domain>
EOF
}

# cloud-init network-config for the NAS: renders both NICs, matched by MAC so the interface names
# do not matter. Kept generated (not static) so the MACs live in exactly one place: guests.tsv.
nas_network_config() {
  local i
  i="$(guest_index lab-nas)" || die "guests.tsv has no lab-nas row"
  cat <<EOF
version: 2
ethernets:
  lab0:
    match:
      macaddress: "${GUEST_MAC_LAB[$i]}"
    dhcp4: true
    dhcp6: false
  storage0:
    match:
      macaddress: "${GUEST_MAC_STORAGE[$i]}"
    addresses:
      - ${GUEST_IP_STORAGE[$i]}/30
    dhcp4: false
    dhcp6: false
EOF
}

# ---------------------------------------------------------------------------
# libvirt mutations
# ---------------------------------------------------------------------------

# Deterministic UUID so that `virsh define` can UPDATE an already-defined domain. Without a <uuid>,
# libvirt assigns a fresh random one on every define and then refuses the update with
# "domain 'X' already exists with uuid Y" — which would break re-running up.sh after editing
# guests.tsv. A stable UUID also means the same guest keeps the same identity across rebuilds.
domain_uuid() {  # <name>
  local h vb vc
  h="$(printf 'homelab-lab/%s' "$1" | md5sum | cut -c1-32)"
  vb=$(( (0x${h:16:1} & 3) | 8 ))
  vc="$(printf '%x' "$vb")"
  printf '%s-%s-5%s-%s%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$vc" "${h:17:3}" "${h:20:12}"
}

# The serial console is a plain pty. It is intentionally NOT mirrored to a log file: libvirt
# creates such a file as root, mode 0600, so it is unreadable by the owner of this repo, and the
# guests here are headless anyway (see the smoke test notes in docs/lab.md — `virsh screenshot`
# against a temporary <video> device was what actually proved the Talos guest boots).

ensure_nwfilter() {
  local file="$LAB_VIRT_DIR/xml/$NWFILTER_NAME.xml" tmp
  if [ "$WITH_NWFILTER" != 1 ]; then
    warn "WITH_NWFILTER=0 — guests are NOT filtered against the house LAN / server VLAN."
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    nwfilter_xml | write_artifact "$file"
    run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" nwfilter-define "$file"
    return 0
  fi
  tmp="$file.tmp"
  nwfilter_xml > "$tmp"
  if nwfilter_exists "$NWFILTER_NAME"; then
    if cmp -s "$file" "$tmp"; then
      note "nwfilter $NWFILTER_NAME already defined (definition unchanged)"
      mv -f "$tmp" "$file"
      return 0
    fi
    warn "nwfilter $NWFILTER_NAME is defined with a different definition — redefining"
    run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" nwfilter-undefine "$NWFILTER_NAME"
  fi
  mv -f "$tmp" "$file"
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" nwfilter-define "$file"
}

# ensure_network <name> <xml-function> — define once, and redefine only when the generated XML
# actually differs from what was defined last time (the copy in LAB_VIRT_DIR/xml is that record).
# Without this, editing guests.tsv (a new address reservation, say) would silently do nothing.
ensure_network() {
  local name="$1" fn="$2" file="$LAB_VIRT_DIR/xml/$1.xml" tmp
  if [ "$DRY" = 1 ]; then
    "$fn" | write_artifact "$file"
    run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-define "$file"
    run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-start "$name"
    return 0
  fi
  tmp="$file.tmp"
  "$fn" > "$tmp"
  if network_exists "$name"; then
    if cmp -s "$file" "$tmp"; then
      note "network $name already defined (definition unchanged)"
      mv -f "$tmp" "$file"
      if network_active "$name"; then
        note "network $name already active"
        return 0
      fi
      run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-start "$name"
      return 0
    fi
    warn "network $name is defined with a different definition — redefining"
    if network_active "$name"; then
      run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-destroy "$name"
    fi
    run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-undefine "$name"
  fi
  mv -f "$tmp" "$file"
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-define "$file"
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-start "$name"
}

ensure_networks() {
  log "networks (isolated, never bridged to the house LAN)"
  ensure_network "$NET_LAB"     network_xml_lab
  ensure_network "$NET_STORAGE" network_xml_storage
}

# Dedicated lab-only ssh key for the NAS stand-in (never the user's own key): created once, mode 600
# in a 700 directory. The public half is injected into the seed at build time, so the tracked
# user-data stays free of keys. Access: `just lab-nas-ssh`.
lab_ssh_key_path() { printf '%s/ssh/lab_ed25519' "$LAB_VIRT_DIR"; }

ensure_lab_ssh_key() {
  local key
  key="$(lab_ssh_key_path)"
  [ -f "$key" ] && return 0
  mkdir -p "$(dirname "$key")"
  chmod 0700 "$(dirname "$key")"
  ssh-keygen -q -t ed25519 -N '' -C "homelab-lab lab-nas" -f "$key"
  chmod 0600 "$key"
}

# user-data for the seed: the tracked file plus a `users:` block carrying the lab key.
nas_user_data() {  # <tracked user-data>
  cat "$1"
  cat <<EOF

users:
  - name: debian
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$(lab_ssh_key_path).pub")
EOF
}

# The instance-id is derived from the seed content, so cloud-init re-runs (new ssh keys, new
# packages) on the next boot after the seed changed; an unchanged seed keeps the same id.
ensure_nas_seed_iso() {  # <name>
  local name="$1" dir iso id
  dir="$LAB_VIRT_DIR/seed/$name"
  iso="$(guest_seed_iso_path "$name")"
  if [ "$DRY" = 1 ]; then
    printf '\n   [dry-run] seed ISO for %s would be built from:\n' "$name"
    if [ -r "$CLOUD_INIT_DIR/$name/user-data" ]; then
      head -3 "$CLOUD_INIT_DIR/$name/user-data" | sed 's/^/      /'
    fi
    printf '      (+ users: debian with the generated lab key, + meta-data with a content-derived instance-id, + generated network-config)\n'
    printf '   [dry-run] xorriso -as mkisofs -output %s -volid cidata -joliet -rock user-data meta-data network-config\n' "$iso"
    return 0
  fi
  ensure_lab_ssh_key
  mkdir -p "$dir"
  nas_user_data "$CLOUD_INIT_DIR/$name/user-data" > "$dir/user-data.new"
  nas_network_config > "$dir/network-config.new"
  id="$(cat "$dir/user-data.new" "$dir/network-config.new" "$CLOUD_INIT_DIR/$name/meta-data" | sha256sum | cut -c1-12)"
  if [ -f "$iso" ] && [ -f "$dir/instance-id" ] && [ "$(cat "$dir/instance-id")" = "$id" ]; then
    rm -f "$dir/user-data.new" "$dir/network-config.new"
    note "have $(basename "$iso")"
    return 0
  fi
  mv "$dir/user-data.new" "$dir/user-data"
  mv "$dir/network-config.new" "$dir/network-config"
  sed "s/^instance-id:.*/instance-id: $name-$id/" "$CLOUD_INIT_DIR/$name/meta-data" > "$dir/meta-data"
  # Build beside the target and rename: the old ISO may belong to libvirt-qemu and be open in a
  # running guest, which keeps its old copy until the next boot.
  ( cd "$dir" && xorriso -as mkisofs -output "$iso.new" -volid cidata -joliet -rock \
      user-data meta-data network-config >/dev/null 2>&1 ) || die "xorriso failed building $iso"
  chmod 0644 "$iso.new"
  mv -f "$iso.new" "$iso"
  printf '%s\n' "$id" > "$dir/instance-id"
  note "built $(basename "$iso") (instance-id $name-$id; a running guest picks it up on its next boot)"
}

ensure_disk() {  # <index>
  local i="$1" name kind size path
  name="${GUEST_NAMES[$i]}"; kind="${GUEST_KIND[$i]}"; size="${GUEST_DISK[$i]}"
  path="$(guest_disk_path "$name")"
  if [ "$DRY" != 1 ] && [ -f "$path" ]; then
    note "disk exists: $path"
    return 0
  fi
  case "$kind" in
    talos)
      run qemu-img create -f qcow2 "$path" "${size}G"
      ;;
    debian)
      run cp --reflink=auto "$LAB_VIRT_DIR/images/$DEBIAN_BASE_NAME" "$path"
      run qemu-img resize "$path" "${size}G"
      ;;
  esac
}

ensure_domain() {  # <index>
  local i="$1" name file tmp
  name="${GUEST_NAMES[$i]}"
  file="$LAB_VIRT_DIR/xml/$name.xml"
  if [ "$DRY" = 1 ]; then
    domain_xml "$i" | write_artifact "$file"
    run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" define "$file"
    return 0
  fi
  tmp="$file.tmp"
  domain_xml "$i" > "$tmp"
  if domain_exists "$name" && cmp -s "$file" "$tmp"; then
    note "domain $name already defined (definition unchanged)"
    mv -f "$tmp" "$file"
    return 0
  fi
  if domain_running "$name"; then
    warn "domain $name is running with a different definition — the change takes effect on next boot"
  fi
  mv -f "$tmp" "$file"
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" define "$file"
}

start_domain() {
  local name="$1"
  if [ "$DRY" != 1 ] && domain_running "$name"; then
    note "domain $name already running"
    return 0
  fi
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" start "$name"
}

# ---------------------------------------------------------------------------
# readiness
# ---------------------------------------------------------------------------
# wait_lease <network> <mac> <expected-ip> — poll libvirt's DHCP leases.
wait_lease() {
  local net="$1" mac="$2" want_ip="$3" deadline ip
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while :; do
    ip="$(virsh_q net-dhcp-leases "$net" \
      | awk -v m="$mac" 'tolower($0) ~ tolower(m) {
          for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) { print $i; exit }
        }' | cut -d/ -f1)"
    if [ -n "$ip" ]; then
      printf '   DHCP lease on %s: %s (expected %s)\n' "$net" "$ip" "$want_ip" >&2
      [ "$ip" = "$want_ip" ] || printf '   warning: lease %s differs from the reservation %s\n' "$ip" "$want_ip" >&2
      printf '%s' "$ip"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      err "no DHCP lease for $mac on $net within ${WAIT_TIMEOUT}s"
      return 1
    fi
    sleep 3
  done
}

# wait_tcp <host> <port> — readiness probe using bash's /dev/tcp (no nc dependency).
wait_tcp() {
  local host="$1" port="$2" deadline
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while :; do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      note "tcp $host:$port is up"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      err "tcp $host:$port did not come up within ${WAIT_TIMEOUT}s"
      return 1
    fi
    sleep 3
  done
}

# ---------------------------------------------------------------------------
# Talos and NAS bring-up
# ---------------------------------------------------------------------------
talos_config_for() {  # <name> -> path
  case "$1" in
    *-cp) printf '%s/controlplane.yaml' "$TALOS_LAB_OUT" ;;
    *)    printf '%s/worker.yaml' "$TALOS_LAB_OUT" ;;
  esac
}

# talos_node_config <index> -> path. Writes <name>.yaml next to the generated configs: the role's
# config plus this guest's hostname and, with STATIC_NET=1, its address, default route and resolver.
# The link is selected by its MAC from guests.tsv, so the interface name (enp1s0 or otherwise) does
# not matter. Production keeps DHCP reservations; this is lab-only (docs/lab.md, known issues).
talos_node_config() {
  local i="$1" name ip mac base out patch
  name="${GUEST_NAMES[$i]}"; ip="${GUEST_IP_LAB[$i]}"; mac="${GUEST_MAC_LAB[$i]}"
  base="$(talos_config_for "$name")"
  out="$TALOS_LAB_OUT/$name.yaml"
  patch="$TALOS_LAB_OUT/$name.patch.yaml"
  [ -f "$base" ] || die "missing $base (run scripts/talos/gen-configs.sh)"
  {
    printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nhostname: %s\nauto: "off"\n' "$name"
    if [ "$STATIC_NET" = 1 ]; then
      cat <<EOF
---
apiVersion: v1alpha1
kind: LinkAliasConfig
name: lab0
selector:
  match: mac(link.permanent_addr) == "${mac}"
---
apiVersion: v1alpha1
kind: LinkConfig
name: lab0
up: true
addresses:
  - address: ${ip}/24
routes:
  - gateway: ${LAB_GATEWAY}
---
apiVersion: v1alpha1
kind: ResolverConfig
nameservers:
  - address: ${LAB_GATEWAY}
EOF
    fi
  } >"$patch"
  talosctl machineconfig patch "$base" --patch "@$patch" -o "$out" >/dev/null \
    || die "could not patch $base for $name"
  talosctl validate --mode metal --config "$out" >/dev/null \
    || die "talosctl validate failed for $out"
  chmod 600 "$out" "$patch"
  printf '%s' "$out"
}

talos_apply() {  # <index>
  local i="$1" name ip cfg
  name="${GUEST_NAMES[$i]}"; ip="${GUEST_IP_LAB[$i]}"
  cfg="$(talos_node_config "$i")"
  if [ "$STATIC_NET" = 1 ]; then
    note "$name: static ${ip}/24 via $LAB_GATEWAY (STATIC_NET=0 for DHCP only)"
  fi
  log "$name: apply-config (maintenance mode, --insecure)"
  run talosctl apply-config --insecure --nodes "$ip" --file "$cfg"
}

# The generated lab talosconfig carries `endpoints: []` (talosctl v1.14 does not put the endpoint
# there), so an authenticated call that passes only --nodes fails with
#   error constructing client: failed to determine endpoints
# --endpoints must therefore be given explicitly. docs/runbooks/talos-bootstrap.md does the same
# thing with `talosctl config endpoint <API_ENDPOINT>`; passing the flag keeps this stateless.
talos_wait_configured() {  # <ip>
  local ip="$1" deadline
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while :; do
    if talosctl --talosconfig "$TALOS_LAB_OUT/talosconfig" \
         --endpoints "$ip" --nodes "$ip" version >/dev/null 2>&1; then
      note "node $ip answered on the configured (authenticated) API"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      err "node $ip did not come back configured within ${WAIT_TIMEOUT}s"
      return 1
    fi
    sleep 5
  done
}

# The authenticated API answers as soon as apply-config is accepted, while the node is still running
# from the ISO and installing, so talos_wait_configured is not "ready to bootstrap": `talosctl bootstrap`
# then fails with *bootstrap is not available yet*. The machine stage does not tell the two apart
# (it reads `booting` before the install as well as after). The STATE volume does: its phase is
# `failed` while the node runs from the ISO and `ready` once it has rebooted from the installed disk,
# which is also when the etcd service first exists. Verified on lab-talos-cp, 2026-10-20.
talos_wait_installed() {  # <ip>
  local ip="$1" deadline phase="" last=""
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while :; do
    phase="$(talosctl --talosconfig "$TALOS_LAB_OUT/talosconfig" --endpoints "$ip" --nodes "$ip" \
      get volumestatus STATE -o jsonpath='{.spec.phase}' 2>/dev/null || true)"
    if [ -n "$phase" ] && [ "$phase" != "$last" ]; then note "node $ip STATE volume: $phase"; last="$phase"; fi
    if [ "$phase" = "ready" ]; then
      note "node $ip booted from its installed disk"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      err "node $ip did not finish installing within ${WAIT_TIMEOUT}s (STATE volume: ${last:-unknown})"
      return 1
    fi
    sleep 5
  done
}

# Point the lab talosconfig at a node. Every authenticated talosctl call needs an endpoint, and the
# generated talosconfig carries `endpoints: []`; the harness passes --endpoints itself, but
# scripts/talos/bootstrap.sh (pre-existing, and outside this harness) only takes --nodes, so the
# endpoint has to live in the talosconfig file for the bootstrap to work. That is what
# docs/runbooks/talos-bootstrap.md does with `talosctl config endpoint`. Use the bare node address:
# the Talos API is :50000, NOT the Kubernetes :6443 of CLUSTER_ENDPOINT. Idempotent.
talos_config_point_at() {  # <ip>
  local ip="$1"
  [ -f "$TALOS_LAB_OUT/talosconfig" ] || return 0
  run talosctl --talosconfig "$TALOS_LAB_OUT/talosconfig" config endpoint "$ip"
  run talosctl --talosconfig "$TALOS_LAB_OUT/talosconfig" config node "$ip"
}

# ---------------------------------------------------------------------------
# Addressing summary
# ---------------------------------------------------------------------------
show_addressing() {
  log "addressing (docs/decisions.md §2.4)"
  note "lab network     $NET_LAB     $LAB_SUBNET   gateway $LAB_GATEWAY   NAT (no LAN bridge)"
  note "MetalLB pool    $LAB_METALLB_POOL   (outside the DHCP range $LAB_DHCP_START-$LAB_DHCP_END)"
  note "storage link    $NET_STORAGE  $STORAGE_SUBNET   bridge $STORAGE_HOST_IP, NAS $STORAGE_NAS_IP"
  note "never used here: 10.0.0.0/16 (house LAN), 10.10.0.0/16 (server VLAN), 169.254.0.0/16,"
  note "                 172.16.0.0/12, 100.64.0.0/10 — the nwfilter drops them at the tap."
}

talos_endpoint() {
  # CLUSTER_ENDPOINT from the lab inputs (the CP address), for status output.
  # shellcheck source=/dev/null
  ( . "$TALOS_LAB_INPUTS" >/dev/null 2>&1 || true; printf '%s' "${CLUSTER_ENDPOINT:-}" )
}
