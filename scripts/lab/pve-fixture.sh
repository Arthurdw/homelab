#!/usr/bin/env bash
# L1 Proxmox fixture: a disposable, real Proxmox VE install running as a nested libvirt guest on THIS
# workstation, so infrastructure/environments/homelab/proxmox (and modules/talos-vm) can be planned
# and applied against a genuine PVE API before they go near the real host (docs/PROJECT-PLAN.md
# Phase 3; docs/lab.md "Proxmox fixture").
#
# One libvirt domain, lab-pve, on the homelab-lab network at 10.99.100.20 (static, set by the
# installer; no DHCP reservation, so the shared network definition is never touched). It is NOT in
# virt/guests.tsv: `just lab-virt-up` never creates it and virt/down.sh never removes it. This script
# owns it, and refuses any name without the lab- prefix.
#
# The install is unattended and uses the official tooling: the pinned Proxmox VE ISO is verified
# against its published sha256 (versions.yaml lab_fixture_images), then rewritten by
# `proxmox-auto-install-assistant prepare-iso` (run in a throwaway debian:trixie-slim container) to
# carry an answer file. Random credentials are written to talos/out/lab-pve/ (gitignored, mode 700/600),
# never to a tracked file. After the first boot `up` makes vmbr0 VLAN-aware, and creates the
# terraform@pve user, a role and an API token for the OpenTofu root.
#
# Usage:
#   scripts/lab/pve-fixture.sh up        # download, build, install (first run only), configure, wait
#   scripts/lab/pve-fixture.sh status
#   scripts/lab/pve-fixture.sh stop      # virsh shutdown; the disk is kept (frees 4 GiB of RAM)
#   scripts/lab/pve-fixture.sh down      # remove the domain, its disk and the credentials
#   scripts/lab/pve-fixture.sh down --purge   # also remove the auto-install ISO and the stock ISO
#
# Env: LAB_PVE_DIR (default talos/out/lab-pve), LAB_PVE_MEM_MIB (default 4096, refused above 5120),
#      LAB_PVE_DISK_GIB (default 40), LAB_VIRT_DIR, LIBVIRT_URI, WAIT_TIMEOUT
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/virt/lib.sh
. "$HERE/virt/lib.sh"

PVE_NAME="lab-pve"
PVE_IP="10.99.100.20"
PVE_MAC="52:54:00:99:10:20"
PVE_LINK_MAC="52:54:00:99:10:30"   # the storage-link NIC (renamed nic2 inside the guest, as on poseidon)
PVE_FQDN="lab-pve.lab.internal"
PVE_NODE="lab-pve"
PVE_URL="https://${PVE_IP}:8006/"
PVE_USER="terraform@pve"
PVE_TOKEN_ID="tofu"
PVE_ROLE="TofuTalos"
MEM_MIB="${LAB_PVE_MEM_MIB:-4096}"
DISK_GIB="${LAB_PVE_DISK_GIB:-40}"
OUT_DIR="${LAB_PVE_DIR:-$REPO_ROOT/talos/out/lab-pve}"
ENV_FILE="$OUT_DIR/fixture.env"
SSH_KEY="$OUT_DIR/id_ed25519"
ANSWER="$OUT_DIR/answer.toml"
INSTALLED="$LAB_VIRT_DIR/$PVE_NAME.installed"
ISO_DIR="$LAB_VIRT_DIR/images"
ISO_NAME="$(yaml_get proxmox_ve_iso)"
ISO_URL="$(yaml_get proxmox_ve_iso_url)"
ISO_SHA256="$(yaml_get proxmox_ve_iso_sha256)"
ISO_STOCK="$ISO_DIR/$ISO_NAME"
ISO_AUTO="$ISO_DIR/${ISO_NAME%.iso}-auto-$PVE_NAME.iso"
DISK="$(guest_disk_path "$PVE_NAME")"

usage() { sed -n '2,29p' "$0"; }

# Everything below acts on the fixed names above, never on a name taken from outside.
is_lab_domain "$PVE_NAME" || die "refusing: '$PVE_NAME' does not carry the '$LAB_DOMAIN_PREFIX' prefix"
[ -n "$ISO_NAME" ] && [ -n "$ISO_URL" ] && [ -n "$ISO_SHA256" ] \
  || die "versions.yaml lab_fixture_images has no proxmox_ve_iso / _url / _sha256 pin"
case "$MEM_MIB$DISK_GIB" in *[!0-9]*) die "LAB_PVE_MEM_MIB and LAB_PVE_DISK_GIB must be numbers" ;; esac
# The workstation also runs the Talos lab guests (about 11 GiB); this guest must stay small.
[ "$MEM_MIB" -le 5120 ] || die "refusing: LAB_PVE_MEM_MIB=$MEM_MIB is above the 5120 MiB cap"

ssh_pve() {
  ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "root@$PVE_IP" "$@"
}

state() {
  if domain_exists "$PVE_NAME"; then virsh_q domstate "$PVE_NAME" | tr -d '\n'; else echo undefined; fi
}

wait_state() {  # <wanted> <seconds>
  local want="$1" deadline=$(( $(date +%s) + $2 ))
  while [ "$(state)" != "$want" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

domain_xml_pve() {  # <with-install-iso: 1|0>
  local boot media="" filter=""
  boot="    <boot dev='hd'/>"
  # The storage-link NIC is added after the install only, so the installer sees one NIC (the
  # management one). It sits on the isolated homelab-lab-link network and never carries a filterref.
  local link=""
  if [ "$1" = 0 ]; then
    link="    <interface type='network'>
      <source network='${NET_LINK}'/>
      <mac address='${PVE_LINK_MAC}'/>
      <model type='virtio'/>
    </interface>"
  fi
  if [ "$1" = 1 ]; then
    boot+=$'\n'"    <boot dev='cdrom'/>"
    media="    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$ISO_AUTO'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>"
  fi
  if [ "$WITH_NWFILTER" = 1 ] && nwfilter_exists "$NWFILTER_NAME"; then
    filter="      <filterref filter='${NWFILTER_NAME}'/>"$'\n'
  fi
  cat <<XML
<domain type='kvm'>
  <name>${PVE_NAME}</name>
  <uuid>$(domain_uuid "$PVE_NAME")</uuid>
  <description>homelab L1 Proxmox fixture (nested PVE) — disposable, created by scripts/lab/pve-fixture.sh.</description>
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
    </disk>
${media}
    <interface type='network'>
      <source network='${NET_LAB}'/>
      <mac address='${PVE_MAC}'/>
      <model type='virtio'/>
${filter}    </interface>
${link}
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
  local file="$LAB_VIRT_DIR/xml/$PVE_NAME.xml"
  mkdir -p "$LAB_VIRT_DIR/xml"
  domain_xml_pve "$1" > "$file"
  virsh_q define "$file" >/dev/null || die "could not define $PVE_NAME"
}

write_credentials() {
  mkdir -p "$OUT_DIR"
  chmod 700 "$OUT_DIR"
  umask 077
  [ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "$PVE_NAME fixture" -f "$SSH_KEY"
  if [ ! -f "$ENV_FILE" ]; then
    local pass
    pass="$(openssl rand -hex 16)"
    cat >"$ENV_FILE" <<ENV
# L1 Proxmox fixture credentials. Random, local to this workstation, never committed.
LAB_PVE_ROOT_PASSWORD=$pass
LAB_PVE_URL=$PVE_URL
LAB_PVE_NODE=$PVE_NODE
LAB_PVE_SSH_KEY=$SSH_KEY
ENV
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  cat >"$ANSWER" <<TOML
# Generated by scripts/lab/pve-fixture.sh. Holds a password hash: gitignored, mode 600.
[global]
keyboard = "en-us"
country = "be"
fqdn = "$PVE_FQDN"
mailto = "root@localhost"
timezone = "UTC"
root-password-hashed = "$(openssl passwd -6 "$LAB_PVE_ROOT_PASSWORD")"
root-ssh-keys = ["$(cat "$SSH_KEY.pub")"]
reboot-mode = "power-off"

[network]
source = "from-answer"
cidr = "$PVE_IP/24"
dns = "$LAB_GATEWAY"
gateway = "$LAB_GATEWAY"
filter.ID_NET_NAME_MAC = "*525400991020"

[disk-setup]
filesystem = "ext4"
disk-list = ["vda"]
lvm.swapsize = 1
lvm.maxroot = 12
lvm.minfree = 1
TOML
}

ensure_stock_iso() {
  mkdir -p "$ISO_DIR"
  if [ -f "$ISO_STOCK" ] && [ "$(sha256sum "$ISO_STOCK" | cut -d' ' -f1)" = "$ISO_SHA256" ]; then
    note "stock ISO present and verified ($ISO_NAME)"
    return 0
  fi
  note "downloading $ISO_URL (about 1.5 GiB)"
  curl -fL --retry 3 -o "$ISO_STOCK.part" "$ISO_URL"
  if [ "$(sha256sum "$ISO_STOCK.part" | cut -d' ' -f1)" != "$ISO_SHA256" ]; then
    rm -f "$ISO_STOCK.part"
    die "sha256 of $ISO_NAME does not match the pin in versions.yaml"
  fi
  mv -f "$ISO_STOCK.part" "$ISO_STOCK"
  chmod 644 "$ISO_STOCK"
  note "sha256 verified: $ISO_SHA256"
}

# prepare-iso runs in a throwaway container: the tool is not packaged for this workstation. The
# Proxmox apt key comes from enterprise.proxmox.com over TLS (download.proxmox.com fails its
# hostname check from here); the tool only reads the ISO and writes a new one.
ensure_auto_iso() {
  if [ -f "$ISO_AUTO" ] && [ "$ISO_AUTO" -nt "$ANSWER" ]; then
    note "auto-install ISO present ($(basename "$ISO_AUTO"))"
    return 0
  fi
  local work
  work="$(mktemp -d "$OUT_DIR/build.XXXXXX")"
  cp "$ANSWER" "$work/answer.toml"
  ln "$ISO_STOCK" "$work/in.iso" 2>/dev/null || cp "$ISO_STOCK" "$work/in.iso"
  note "building the auto-install ISO in a debian:trixie-slim container"
  docker run --rm -v "$work:/work" debian:trixie-slim bash -ec '
    apt-get update -qq >/dev/null
    apt-get install -y -qq curl ca-certificates xorriso >/dev/null
    curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
      -o /etc/apt/trusted.gpg.d/proxmox-archive-keyring-trixie.gpg
    echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve.list
    apt-get update -qq >/dev/null
    apt-get install -y -qq proxmox-auto-install-assistant >/dev/null
    echo "   proxmox-auto-install-assistant $(dpkg-query -W -f="\${Version}" proxmox-auto-install-assistant)"
    proxmox-auto-install-assistant validate-answer /work/answer.toml
    proxmox-auto-install-assistant prepare-iso /work/in.iso --fetch-from iso --answer-file /work/answer.toml --output /work/out.iso
    chmod 644 /work/out.iso'
  mv -f "$work/out.iso" "$ISO_AUTO"
  chmod 644 "$ISO_AUTO"
  rm -rf "$work"
}

ensure_lab_network() {
  network_exists "$NET_LAB" || die "network $NET_LAB is not defined (run: just lab-virt-up --dry-run, or just lab-virt-up)"
  if ! network_active "$NET_LAB"; then
    note "starting network $NET_LAB (definition untouched)"
    virsh_q net-start "$NET_LAB" >/dev/null || die "could not start $NET_LAB"
  fi
}

install_pve() {
  log "unattended install (first run only)"
  [ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" "${DISK_GIB}G" >/dev/null
  chmod 644 "$DISK"
  define_domain 1
  virsh_q start "$PVE_NAME" >/dev/null || die "could not start $PVE_NAME"
  note "installer running; it powers the guest off when done (up to 30 minutes)"
  wait_state "shut off" 1800 || die "the installer did not finish in 30 minutes (virsh console $PVE_NAME)"
  : > "$INSTALLED"
  # A fresh install has a new host key at the same address; the provider's SSH step reads the user's
  # known_hosts and refuses a changed key, so drop any entry from an earlier fixture.
  ssh-keygen -R "$PVE_IP" >/dev/null 2>&1 || true
  note "install finished"
}

wait_ssh() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  until ssh_pve true 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || die "ssh to $PVE_IP did not come up in ${WAIT_TIMEOUT}s"
    sleep 5
  done
  until ssh_pve 'pvesh get /version >/dev/null 2>&1 && systemctl is-active --quiet pveproxy'; do
    [ "$(date +%s)" -lt "$deadline" ] || die "pveproxy did not come up in ${WAIT_TIMEOUT}s"
    sleep 5
  done
}

configure_pve() {
  log "configure the host"
  # vmbr0 VLAN-aware, as the production bridge must be for the K8s VLAN tag (the lab sets the tag null).
  if ssh_pve "grep -q bridge-vlan-aware /etc/network/interfaces"; then
    note "vmbr0 already VLAN-aware"
  else
    ssh_pve "sed -i '/^iface vmbr0 inet static/,/^$/ s/^\\(\\s*bridge-fd .*\\)\$/\\1\\n\\tbridge-vlan-aware yes\\n\\tbridge-vids 2-4094/' /etc/network/interfaces && grep -q bridge-vlan-aware /etc/network/interfaces" \
      || die "could not make vmbr0 VLAN-aware"
    ssh_pve "ifreload -a" || true
    wait_ssh
    note "vmbr0 is now VLAN-aware (bridge-vids 2-4094)"
  fi
  # The storage-link NIC is called nic2 on poseidon (docs/hardware.md); pin the same name here by MAC
  # (a systemd .link file, so it survives a reboot) and rename the live link once, while it is down.
  if ssh_pve "ip -o link show nic2 >/dev/null 2>&1"; then
    note "storage-link NIC already named nic2"
  else
    ssh_pve "set -e
      printf '[Match]\nMACAddress=$PVE_LINK_MAC\n\n[Link]\nName=nic2\n' > /etc/systemd/network/10-nic2.link
      dev=\$(ip -o link | awk -F': ' -v m=$PVE_LINK_MAC 'BEGIN{IGNORECASE=1} \$0 ~ m {print \$2; exit}')
      [ -n \"\$dev\" ]
      ip link set \"\$dev\" down
      ip link set \"\$dev\" name nic2" || die "could not name the storage-link NIC nic2"
    note "storage-link NIC is now nic2"
  fi
  # A dedicated automation user with a role, and a token that inherits its rights (privsep 0).
  # Privileges mirror what the bpg/proxmox provider documents for VM + file management.
  # PVE 9 removed VM.Monitor (it is rejected as an invalid privilege); It is simply dropped from the list.
  ssh_pve "set -e
    pveum role list --output-format json | grep -q '\"$PVE_ROLE\"' || pveum role add $PVE_ROLE -privs 'Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify SDN.Use VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.GuestAgent.Audit VM.Migrate VM.PowerMgmt'
    pveum user list --output-format json | grep -q '\"$PVE_USER\"' || pveum user add $PVE_USER
    pveum acl modify / --users $PVE_USER --roles $PVE_ROLE" || die "could not create the automation user"
  if grep -q '^LAB_PVE_API_TOKEN=' "$ENV_FILE"; then
    note "API token already recorded"
  else
    local secret
    secret="$(ssh_pve "pveum user token add $PVE_USER $PVE_TOKEN_ID --privsep 0 --output-format json" | jq -r .value)"
    [ -n "$secret" ] && [ "$secret" != null ] || die "no token secret returned"
    umask 077
    printf 'LAB_PVE_API_TOKEN=%s!%s=%s\n' "$PVE_USER" "$PVE_TOKEN_ID" "$secret" >> "$ENV_FILE"
    note "created API token $PVE_USER!$PVE_TOKEN_ID (secret in $ENV_FILE)"
  fi
}

cmd_up() {
  require_cmd virsh; require_cmd docker; require_cmd curl; require_cmd openssl
  require_cmd ssh; require_cmd ssh-keygen; require_cmd qemu-img; require_cmd jq
  check_libvirt hard || exit 1
  [ "$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | head -1)" != "" ] \
    || warn "cannot read the KVM nested parameter; PVE needs nested virtualisation"
  ensure_dirs
  if [ "$(state)" != running ]; then
    local avail
    avail="$(mem_available_mib)"
    [ "$avail" -ge $(( MEM_MIB + RAM_HEADROOM_MIB )) ] \
      || die "only $avail MiB available; need $MEM_MIB + $RAM_HEADROOM_MIB (stop the Talos lab guests, or lower LAB_PVE_MEM_MIB)"
  fi
  log "credentials ($OUT_DIR)"
  write_credentials
  log "installation media"
  ensure_stock_iso
  ensure_auto_iso
  log "network"
  ensure_lab_network
  ensure_link_network
  [ -f "$INSTALLED" ] || install_pve
  log "start"
  define_domain 0
  if [ "$(state)" = running ]; then note "already running"; else virsh_q start "$PVE_NAME" >/dev/null || die "could not start"; fi
  wait_ssh
  configure_pve
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  log "ready"
  note "API:   $PVE_URL (node $PVE_NODE, self-signed)"
  note "ssh:   ssh -i $SSH_KEY root@$PVE_IP"
  note "token: in $ENV_FILE (LAB_PVE_API_TOKEN)"
  note "next:  just lab-pve-plan"
}

cmd_status() {
  printf '%s: %s\n' "$PVE_NAME" "$(state)"
  [ -f "$INSTALLED" ] && echo "installed: yes" || echo "installed: no"
  if [ "$(state)" = running ]; then
    curl -sk --max-time 5 -o /dev/null -w 'api: HTTP %{http_code}\n' "${PVE_URL}api2/json/version" || echo "api: down"
  fi
}

cmd_stop() {
  [ "$(state)" = running ] || { note "$PVE_NAME is not running"; return 0; }
  virsh_q shutdown "$PVE_NAME" >/dev/null
  wait_state "shut off" 180 || { warn "no clean shutdown in 180s; forcing off"; virsh_q destroy "$PVE_NAME" >/dev/null; }
  note "$PVE_NAME is shut off; disk kept ($DISK). Bring it back with: just lab-pve"
}

cmd_down() {
  local purge=0
  [ "${1:-}" = "--purge" ] && purge=1
  if domain_exists "$PVE_NAME"; then
    [ "$(state)" = running ] && virsh_q destroy "$PVE_NAME" >/dev/null
    virsh_q undefine "$PVE_NAME" >/dev/null && note "removed domain $PVE_NAME"
  fi
  rm -f "$DISK" "$INSTALLED" "$LAB_VIRT_DIR/xml/$PVE_NAME.xml"
  rm -rf "$OUT_DIR"
  if [ "$purge" = 1 ]; then rm -f "$ISO_AUTO" "$ISO_STOCK"; fi
  note "removed the disk and $OUT_DIR${purge:+ (and, with --purge, the ISOs)}"
}

case "${1:-}" in
  up) cmd_up ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  down) shift; cmd_down "$@" ;;
  -h|--help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
