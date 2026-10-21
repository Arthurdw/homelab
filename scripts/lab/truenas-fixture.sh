#!/usr/bin/env bash
# L1 TrueNAS fixture: a disposable, real TrueNAS SCALE install running as a libvirt guest on THIS
# workstation, so infrastructure/environments/homelab/truenas can be planned and applied against a
# genuine JSON-RPC API (/api/current) before it goes near hercules-nas. The provider (truenas/truenas
# 1.5.14) needs SCALE >= 25.04; the real NAS runs 24.10, so this is the only place it can be proven
# (docs/lab.md "TrueNAS fixture").
#
# One libvirt domain, lab-truenas, on the homelab-lab network at 10.99.100.21 (static, set by the
# installer; no DHCP reservation, so the shared network definition is never touched). It is NOT in
# virt/guests.tsv: `just lab-virt-up` never creates it and virt/down.sh never removes it. This script
# owns it, and refuses any name without the lab- prefix.
#
# The install is unattended and uses the installer's own API: the pinned ISO (versions.yaml
# lab_fixture_images, sha256 verified) boots a live system that serves the installer as JSON-RPC on
# port 80 (/ws). virt/truenas-rpc.py drives it (adopt, install with the admin password and a static
# address). After the first boot `up` creates the pool `main` on a dedicated data disk (so the root's
# main/k8s dataset path is real) and an API key for the OpenTofu root. Random credentials go to
# talos/out/lab-truenas/ (gitignored, mode 700/600), never to a tracked file.
#
# Usage:
#   scripts/lab/truenas-fixture.sh up        # download, install (first run only), configure, wait
#   scripts/lab/truenas-fixture.sh status
#   scripts/lab/truenas-fixture.sh stop      # virsh shutdown; the disks are kept (frees the RAM)
#   scripts/lab/truenas-fixture.sh down      # remove the domain, its disks and the credentials
#   scripts/lab/truenas-fixture.sh down --purge   # also remove the ISO
#
# Env: LAB_TRUENAS_DIR (default talos/out/lab-truenas), LAB_TRUENAS_MEM_MIB (default 6144, refused
#      above 8192), LAB_TRUENAS_BOOT_GIB (default 20), LAB_TRUENAS_DATA_GIB (default 10), LAB_VIRT_DIR,
#      LIBVIRT_URI, WAIT_TIMEOUT
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/virt/lib.sh
. "$HERE/virt/lib.sh"

NAS_NAME="lab-truenas"
NAS_IP="10.99.100.21"
NAS_MAC="52:54:00:99:10:21"
NAS_PREFIX=24
NAS_ADMIN="truenas_admin"
NAS_POOL="main"
NAS_KEY_NAME="tofu"
MEM_MIB="${LAB_TRUENAS_MEM_MIB:-6144}"
BOOT_GIB="${LAB_TRUENAS_BOOT_GIB:-20}"
DATA_GIB="${LAB_TRUENAS_DATA_GIB:-10}"
OUT_DIR="${LAB_TRUENAS_DIR:-$REPO_ROOT/talos/out/lab-truenas}"
ENV_FILE="$OUT_DIR/fixture.env"
RPC="$HERE/virt/truenas-rpc.py"
INSTALLED="$LAB_VIRT_DIR/$NAS_NAME.installed"
ISO_DIR="$LAB_VIRT_DIR/images"
ISO_NAME="$(yaml_get truenas_scale_iso)"
ISO_URL="$(yaml_get truenas_scale_iso_url)"
ISO_SHA256="$(yaml_get truenas_scale_iso_sha256)"
ISO="$ISO_DIR/$ISO_NAME"
DISK="$(guest_disk_path "$NAS_NAME")"
DATA_DISK="$(guest_disk_path "$NAS_NAME-data")"

usage() { sed -n '2,31p' "$0"; }

# Everything below acts on the fixed names above, never on a name taken from outside.
is_lab_domain "$NAS_NAME" || die "refusing: '$NAS_NAME' does not carry the '$LAB_DOMAIN_PREFIX' prefix"
[ -n "$ISO_NAME" ] && [ -n "$ISO_URL" ] && [ -n "$ISO_SHA256" ] \
  || die "versions.yaml lab_fixture_images has no truenas_scale_iso / _url / _sha256 pin"
case "$MEM_MIB$BOOT_GIB$DATA_GIB" in *[!0-9]*) die "LAB_TRUENAS_MEM_MIB, _BOOT_GIB and _DATA_GIB must be numbers" ;; esac
# The workstation also runs the Talos lab guests; this guest must stay bounded.
[ "$MEM_MIB" -le 8192 ] || die "refusing: LAB_TRUENAS_MEM_MIB=$MEM_MIB is above the 8192 MiB cap"

state() {
  if domain_exists "$NAS_NAME"; then virsh_q domstate "$NAS_NAME" | tr -d '\n'; else echo undefined; fi
}

wait_state() {  # <wanted> <seconds>
  local want="$1" deadline=$(( $(date +%s) + $2 ))
  while [ "$(state)" != "$want" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# Serials matter: TrueNAS ignores a disk that has no serial number.
domain_xml_nas() {  # <with-install-iso: 1|0>
  local boot media="" filter=""
  boot="    <boot dev='hd'/>"
  if [ "$1" = 1 ]; then
    boot+=$'\n'"    <boot dev='cdrom'/>"
    media="    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$ISO'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>"
  fi
  if [ "$WITH_NWFILTER" = 1 ] && nwfilter_exists "$NWFILTER_NAME"; then
    filter="      <filterref filter='${NWFILTER_NAME}'/>"$'\n'
  fi
  cat <<XML
<domain type='kvm'>
  <name>${NAS_NAME}</name>
  <uuid>$(domain_uuid "$NAS_NAME")</uuid>
  <description>homelab L1 TrueNAS fixture (SCALE) — disposable, created by scripts/lab/truenas-fixture.sh.</description>
  <memory unit='MiB'>${MEM_MIB}</memory>
  <currentMemory unit='MiB'>${MEM_MIB}</currentMemory>
  <vcpu placement='static'>2</vcpu>
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
      <source file='${DISK}'/>
      <target dev='vda' bus='virtio'/>
      <serial>LABTRUENASBOOT01</serial>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='${LAB_DISK_CACHE}' discard='unmap'/>
      <source file='${DATA_DISK}'/>
      <target dev='vdb' bus='virtio'/>
      <serial>LABTRUENASDATA01</serial>
    </disk>
${media}
    <interface type='network'>
      <source network='${NET_LAB}'/>
      <mac address='${NAS_MAC}'/>
      <model type='virtio'/>
${filter}    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <video>
      <model type='vga'/>
    </video>
  </devices>
</domain>
XML
}

define_domain() {  # <with-install-iso>
  local file="$LAB_VIRT_DIR/xml/$NAS_NAME.xml"
  mkdir -p "$LAB_VIRT_DIR/xml"
  domain_xml_nas "$1" > "$file"
  virsh_q define "$file" >/dev/null || die "could not define $NAS_NAME"
}

write_credentials() {
  mkdir -p "$OUT_DIR"
  chmod 700 "$OUT_DIR"
  umask 077
  if [ ! -f "$ENV_FILE" ]; then
    cat >"$ENV_FILE" <<ENV
# L1 TrueNAS fixture credentials. Random, local to this workstation, never committed.
LAB_TRUENAS_ADMIN_USER=$NAS_ADMIN
LAB_TRUENAS_ADMIN_PASSWORD=$(openssl rand -hex 16)
LAB_TRUENAS_ENDPOINT=wss://$NAS_IP/api/current
ENV
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

ensure_iso() {
  mkdir -p "$ISO_DIR"
  if [ -f "$ISO" ] && [ "$(sha256sum "$ISO" | cut -d' ' -f1)" = "$ISO_SHA256" ]; then
    note "ISO present and verified ($ISO_NAME)"
    return 0
  fi
  note "downloading $ISO_URL (about 1.9 GiB)"
  curl -fL --retry 3 -o "$ISO.part" "$ISO_URL"
  if [ "$(sha256sum "$ISO.part" | cut -d' ' -f1)" != "$ISO_SHA256" ]; then
    rm -f "$ISO.part"
    die "sha256 of $ISO_NAME does not match the pin in versions.yaml"
  fi
  mv -f "$ISO.part" "$ISO"
  chmod 644 "$ISO"
  note "sha256 verified: $ISO_SHA256"
}

ensure_lab_network() {
  network_exists "$NET_LAB" || die "network $NET_LAB is not defined (run: just lab-virt-up --dry-run, or just lab-virt-up)"
  if ! network_active "$NET_LAB"; then
    note "starting network $NET_LAB (definition untouched)"
    virsh_q net-start "$NET_LAB" >/dev/null || die "could not start $NET_LAB"
  fi
}

# JSON in on stdin, JSON out on stdout. Credentials only travel through the environment.
rpc() {  # <url>   (calls on stdin)
  timeout 3600 python3 -I "$RPC" "$1"
}
rpc_auth() {  # <url>   (calls on stdin)
  TRUENAS_RPC_USER="$LAB_TRUENAS_ADMIN_USER" TRUENAS_RPC_PASSWORD="$LAB_TRUENAS_ADMIN_PASSWORD" python3 -I "$RPC" "$1"
}

live_ip() {  # the DHCP address the live installer got, from the libvirt lease table
  virsh_q net-dhcp-leases "$NET_LAB" 2>/dev/null | awk -v mac="$NAS_MAC" 'tolower($3)==tolower(mac) {split($5,a,"/"); ip=a[1]} END{print ip}'
}

install_nas() {
  log "unattended install (first run only)"
  [ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" "${BOOT_GIB}G" >/dev/null
  [ -f "$DATA_DISK" ] || qemu-img create -f qcow2 "$DATA_DISK" "${DATA_GIB}G" >/dev/null
  chmod 644 "$DISK" "$DATA_DISK"
  define_domain 1
  virsh_q start "$NAS_NAME" >/dev/null || die "could not start $NAS_NAME"
  note "booting the live installer"
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT )) ip=""
  until [ -n "$ip" ] && echo '[["system_info",[]]]' | timeout 30 python3 -I "$RPC" "ws://$ip/ws" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || die "the installer API did not answer in ${WAIT_TIMEOUT}s (virsh console $NAS_NAME)"
    sleep 5
    ip="$(live_ip)"
  done
  note "installer API up on $ip"
  local iface
  iface="$(echo '[["list_network_interfaces",[]]]' | rpc "ws://$ip/ws" | jq -r '.[0][0].name')"
  [ -n "$iface" ] && [ "$iface" != null ] || die "the installer lists no network interface"
  jq -n --arg pw "$LAB_TRUENAS_ADMIN_PASSWORD" --arg user "$LAB_TRUENAS_ADMIN_USER" --arg iface "$iface" \
        --arg ip "$NAS_IP" --argjson prefix "$NAS_PREFIX" '
    [["adopt", []],
     ["install", [{"disks": ["vda"], "set_pmbr": true,
                   "authentication": {"username": $user, "password": $pw},
                   "post_install": {"network_interfaces": [
                     {"name": $iface, "ipv4_dhcp": false, "ipv6_auto": false,
                      "aliases": [{"type": "INET", "address": $ip, "netmask": $prefix}]}]}}]]]' \
    | rpc "ws://$ip/ws" >/dev/null || die "the install failed (virsh console $NAS_NAME)"
  note "install finished; rebooting from the disk"
  virsh_q destroy "$NAS_NAME" >/dev/null || true
  : > "$INSTALLED"
}

wait_api() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT * 2 ))
  until echo '[["system.version",[]]]' | timeout 30 env TRUENAS_RPC_USER="$LAB_TRUENAS_ADMIN_USER" TRUENAS_RPC_PASSWORD="$LAB_TRUENAS_ADMIN_PASSWORD" python3 -I "$RPC" "wss://$NAS_IP/api/current" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || die "the TrueNAS API at $NAS_IP did not come up in $((WAIT_TIMEOUT * 2))s (virsh console $NAS_NAME)"
    sleep 5
  done
}

configure_nas() {
  log "configure the NAS"
  local url="wss://$NAS_IP/api/current" pools
  pools="$(echo '[["pool.query",[[["name","=","'"$NAS_POOL"'"]]]]]' | rpc_auth "$url" | jq '.[0] | length')"
  if [ "$pools" = 0 ]; then
    jq -n --arg pool "$NAS_POOL" '[["job:pool.create", [{"name": $pool, "topology": {"data": [{"type": "STRIPE", "disks": ["vdb"]}]}}]]]' \
      | rpc_auth "$url" >/dev/null || die "could not create pool $NAS_POOL"
    note "created pool $NAS_POOL on vdb"
  else
    note "pool $NAS_POOL already exists"
  fi
  if grep -q '^LAB_TRUENAS_API_KEY=' "$ENV_FILE"; then
    note "API key already recorded"
  else
    local key
    key="$(jq -n --arg n "$NAS_KEY_NAME" --arg u "$LAB_TRUENAS_ADMIN_USER" '[["api_key.create", [{"name": $n, "username": $u}]]]' \
      | rpc_auth "$url" | jq -r '.[0].key')"
    [ -n "$key" ] && [ "$key" != null ] || die "no API key returned"
    umask 077
    printf 'LAB_TRUENAS_API_KEY=%s\n' "$key" >> "$ENV_FILE"
    note "created API key '$NAS_KEY_NAME' (secret in $ENV_FILE)"
  fi
}

cmd_up() {
  require_cmd virsh; require_cmd curl; require_cmd openssl; require_cmd qemu-img; require_cmd jq; require_cmd python3
  check_libvirt hard || exit 1
  ensure_dirs
  if [ "$(state)" != running ]; then
    local avail
    avail="$(mem_available_mib)"
    [ "$avail" -ge $(( MEM_MIB + RAM_HEADROOM_MIB )) ] \
      || die "only $avail MiB available; need $MEM_MIB + $RAM_HEADROOM_MIB (stop other guests, or lower LAB_TRUENAS_MEM_MIB)"
  fi
  log "credentials ($OUT_DIR)"
  write_credentials
  log "installation media"
  if [ -f "$INSTALLED" ]; then note "already installed; the ISO is not needed"; else ensure_iso; fi
  log "network"
  ensure_lab_network
  [ -f "$INSTALLED" ] || install_nas
  log "start"
  [ -f "$DATA_DISK" ] || qemu-img create -f qcow2 "$DATA_DISK" "${DATA_GIB}G" >/dev/null
  chmod 644 "$DATA_DISK"
  define_domain 0
  if [ "$(state)" = running ]; then note "already running"; else virsh_q start "$NAS_NAME" >/dev/null || die "could not start"; fi
  wait_api
  configure_nas
  log "ready"
  note "API:   wss://$NAS_IP/api/current (self-signed)"
  note "key:   in $ENV_FILE (LAB_TRUENAS_API_KEY)"
  note "next:  just lab-truenas-plan"
}

cmd_status() {
  printf '%s: %s\n' "$NAS_NAME" "$(state)"
  [ -f "$INSTALLED" ] && echo "installed: yes" || echo "installed: no"
  if [ "$(state)" = running ]; then
    curl -sk --max-time 5 -o /dev/null -w 'https: HTTP %{http_code}\n' "https://$NAS_IP/" || echo "https: down"
  fi
}

cmd_stop() {
  [ "$(state)" = running ] || { note "$NAS_NAME is not running"; return 0; }
  virsh_q shutdown "$NAS_NAME" >/dev/null
  wait_state "shut off" 180 || { warn "no clean shutdown in 180s; forcing off"; virsh_q destroy "$NAS_NAME" >/dev/null; }
  note "$NAS_NAME is shut off; disks kept. Bring it back with: just lab-truenas"
}

cmd_down() {
  local purge=0
  [ "${1:-}" = "--purge" ] && purge=1
  if domain_exists "$NAS_NAME"; then
    [ "$(state)" = running ] && virsh_q destroy "$NAS_NAME" >/dev/null
    virsh_q undefine "$NAS_NAME" >/dev/null && note "removed domain $NAS_NAME"
  fi
  rm -f "$DISK" "$DATA_DISK" "$INSTALLED" "$LAB_VIRT_DIR/xml/$NAS_NAME.xml"
  rm -rf "$OUT_DIR"
  if [ "$purge" = 1 ]; then rm -f "$ISO"; fi
  note "removed the disks and $OUT_DIR${purge:+ (and, with --purge, the ISO)}"
}

case "${1:-}" in
  up) cmd_up ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  down) shift; cmd_down "$@" ;;
  -h|--help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
