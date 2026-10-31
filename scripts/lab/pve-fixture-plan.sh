#!/usr/bin/env bash
# Plan, apply, re-plan and destroy infrastructure/environments/homelab/proxmox (and the talos-vm module)
# against the L1 Proxmox fixture (scripts/lab/pve-fixture.sh), and against nothing else.
#
# The root and the module are COPIED into a scratch tree under the fixture's gitignored out dir, shaped
# like the repo (infrastructure/environments/homelab/proxmox, infrastructure/modules/talos-vm,
# versions.yaml) so the root's relative paths resolve. Its own .terraform, terraform.tfvars and any
# backend are never read, and state is a local file in the scratch directory. The endpoint is refused
# unless it is https://10.99.100.<n>:8006 (the lab network). PROXMOX_VE_* / PM_* / TF_VAR_proxmox* /
# TF_CLI_ARGS* from the calling shell are dropped, so a real token or URL exported for the live root
# can never leak in. The provider's SSH step (file download and import) uses a private ssh-agent that
# holds only the fixture's key, started and killed inside this script.
#
# What this proves is the provider and module configuration against a real Proxmox VE API. The Talos
# VMs are created STOPPED (talos_vm_started = false) and small: a 4 GiB nested Proxmox cannot run them,
# and a second Talos cluster is not the point.
#
# The root also owns the 10 GbE storage-link bridge (vmbr1, storage-link.tf). The fixture has a second
# NIC named nic2 on the isolated homelab-lab-link network (pve-fixture.sh). Before the apply this script
# does what the owner does by hand on poseidon: the NIC's own `mtu 9000` (the one thing the root cannot
# express), after first putting the NIC back to a real card's default of 1500.
#
# Steps: init, validate, owner pre-step for the NIC, plan, apply, check the VMs, the image, the
# bridge (address, MTU on bridge and port) and node-exporter (host-metrics.tf) on the fixture, second
# plan (must be clean: exit 0, no drift), destroy (--keep skips it), check the VMs, the bridge and the
# node-exporter package are gone. The jumbo-frame ping to the
# NAS end is scripts/lab/storage-link-ping.sh (run it between --keep and the final destroy).
#
# Usage:
#   scripts/lab/pve-fixture-plan.sh            # needs: just lab-pve
#   scripts/lab/pve-fixture-plan.sh --plan     # init, validate and plan only
#   scripts/lab/pve-fixture-plan.sh --keep     # everything but the destroy
#
# Env: LAB_PVE_DIR (default talos/out/lab-pve), TOFU (default tofu)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${LAB_PVE_DIR:-$REPO_ROOT/talos/out/lab-pve}"
ENV_FILE="$OUT_DIR/fixture.env"
WORK="$OUT_DIR/tofu"
ROOT_REL="infrastructure/environments/homelab/proxmox"
MODULE_REL="infrastructure/modules/talos-vm"
TOFU="${TOFU:-tofu}"

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

PLAN_ONLY=0
KEEP=0
case "${1:-}" in
  -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
  --plan) PLAN_ONLY=1 ;;
  --keep) KEEP=1 ;;
  "") : ;;
  *) die "unknown argument: $1" ;;
esac

for tool in "$TOFU" curl jq rsync ssh ssh-agent ssh-add; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

[ -f "$ENV_FILE" ] || die "no fixture credentials at $ENV_FILE (run: just lab-pve)"
# shellcheck disable=SC1090
. "$ENV_FILE"

log "fixture endpoint"
url="${LAB_PVE_URL:-}"
case "$url" in
  https://10.99.100.[0-9]*:8006|https://10.99.100.[0-9]*:8006/) note "endpoint $url" ;;
  *) die "refusing: '$url' is not https://10.99.100.<n>:8006" ;;
esac
# A host that merely starts with 10.99.100. (10.99.100.20.evil.test, 10.99.100.1.2.3) must not pass.
host="${url#https://}"
host="${host%%:*}"
case "$host" in *[!0-9.]*) die "refusing: host '$host' is not a plain IPv4 address" ;; esac
IFS=. read -r o1 o2 o3 o4 extra <<<"$host"
{ [ -z "${extra:-}" ] && [ "$o1.$o2.$o3" = "10.99.100" ] && [ "${o4:-999}" -le 254 ]; } \
  || die "refusing: host '$host' is not an address in 10.99.100.0/24"
rest="${url#https://*:}"
case "${rest%/}" in 8006) : ;; *) die "refusing: '$url' has a path or extra parts" ;; esac
[ -n "${LAB_PVE_API_TOKEN:-}" ] && [ -f "${LAB_PVE_SSH_KEY:-}" ] || die "fixture env lacks a token or ssh key (run: just lab-pve)"
curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "${url%/}/api2/json/version" | grep -q '^200$\|^401$' \
  || die "no Proxmox answering at $url (run: just lab-pve)"

log "scratch copy of the root and module ($WORK)"
mkdir -p "$WORK/$ROOT_REL" "$WORK/$MODULE_REL"
rsync -a --delete --include='*.tf' --include='.terraform.lock.hcl' --exclude='*' "$ROOT_REL/" "$WORK/$ROOT_REL/"
rsync -a --delete --include='*.tf' --exclude='*' "$MODULE_REL/" "$WORK/$MODULE_REL/"
cp versions.yaml "$WORK/versions.yaml"
umask 077
# Sized for a 4 GiB nested Proxmox: stopped VMs, 4 GiB between the three (so the root's capacity check
# stays quiet), small thin disks, no data disk. The
# production values are the variable defaults. Addresses are lab addresses outside the MetalLB pool.
cat >"$WORK/$ROOT_REL/fixture.auto.tfvars" <<TFVARS
proxmox_endpoint               = "${url%/}/"
proxmox_insecure               = true
proxmox_ssh_username           = "root"
proxmox_node_name              = "${LAB_PVE_NODE}"
proxmox_host_memory_mb         = 4096
proxmox_host_memory_reserve_mb = 0
vm_bridge                      = "vmbr0"
k8s_vlan_id                    = null
k8s_gateway                    = "10.99.100.1"
k8s_prefix_length              = 24
talos_cp_ipv4                  = "10.99.100.31"
talos_wk_ipv4                  = "10.99.100.32"
talos_wk2_ipv4                 = "10.99.100.33"
talos_cp_memory_mb             = 2048
talos_cp_disk_gb               = 10
talos_wk_memory_mb             = 1024
talos_wk_cpu_cores             = 2
talos_wk_disk_gb               = 10
talos_wk_data_disk_gb          = null
talos_wk2_memory_mb            = 1024
talos_wk2_cpu_cores            = 2
talos_wk2_disk_gb              = 10
talos_wk2_data_disk_gb         = null
talos_vm_started               = false
talos_vm_on_boot               = false
gpu_passthrough                = null
host_metrics                   = {}
TFVARS

AGENT_PID=""
eval "$(ssh-agent -s)" >/dev/null
AGENT_PID="$SSH_AGENT_PID"
trap '[ -z "$AGENT_PID" ] || kill "$AGENT_PID" 2>/dev/null || true' EXIT
ssh-add -q "$LAB_PVE_SSH_KEY"

run_tofu() {
  (
    cd "$WORK/$ROOT_REL"
    env -u TF_CLI_ARGS -u TF_CLI_ARGS_init -u TF_CLI_ARGS_plan -u TF_CLI_ARGS_apply -u TF_CLI_ARGS_destroy \
      -u TF_WORKSPACE -u TF_DATA_DIR \
      -u PROXMOX_VE_ENDPOINT -u PROXMOX_VE_USERNAME -u PROXMOX_VE_PASSWORD -u PROXMOX_VE_API_TOKEN \
      -u PROXMOX_VE_INSECURE -u PROXMOX_VE_SSH_USERNAME -u PROXMOX_VE_SSH_PASSWORD \
      -u PROXMOX_VE_SSH_AGENT -u PROXMOX_VE_SSH_PRIVATE_KEY -u PROXMOX_VE_AUTH_TICKET \
      -u PM_API_URL -u PM_API_TOKEN_ID -u PM_API_TOKEN_SECRET -u PM_USER -u PM_PASS \
      -u TF_VAR_proxmox_endpoint -u TF_VAR_proxmox_insecure -u TF_VAR_proxmox_node_name \
      -u TF_VAR_proxmox_ssh_username -u TF_VAR_vm_bridge \
      TF_IN_AUTOMATION=1 PROXMOX_VE_API_TOKEN="$LAB_PVE_API_TOKEN" \
      "$TOFU" "$@"
  )
}

pve_ssh() {
  ssh -i "$LAB_PVE_SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "root@$host" "$@"
}

log "init (local state, no backend)"
run_tofu init -backend=false -input=false -no-color | tail -n 4
log "validate"
run_tofu validate -no-color

log "owner pre-step: the storage-link NIC's own MTU (what the root cannot express)"
pve_ssh "set -e
  # Start from a hand-free host: no leftover vmbr1, and nic2 at a real NIC's default of 1500.
  if pvesh get /nodes/$LAB_PVE_NODE/network/vmbr1 >/dev/null 2>&1; then pvesh delete /nodes/$LAB_PVE_NODE/network/vmbr1; fi
  pvesh set /nodes/$LAB_PVE_NODE/network >/dev/null
  ip link set nic2 mtu 1500
  pvesh set /nodes/$LAB_PVE_NODE/network/nic2 --type eth --mtu 9000
  pvesh set /nodes/$LAB_PVE_NODE/network >/dev/null" || die "could not stage the NIC MTU on the fixture"
# Without `auto`, ifupdown2 does not touch nic2 on this reload; it applies the stanza's mtu when it
# enslaves nic2 to the bridge the root creates, which is what the checks after the apply prove.
pve_ssh "grep -A1 '^iface nic2' /etc/network/interfaces" | sed 's/^/   /'

log "plan"
run_tofu plan -input=false -no-color -out=fixture.tfplan | tail -n 12
[ "$PLAN_ONLY" = 0 ] || { note "plan only: stopping"; exit 0; }

log "apply (fixture only)"
run_tofu apply -input=false -no-color fixture.tfplan | tail -n 12

log "check the VMs and the image on the fixture"
vms="$(pve_ssh "pvesh get /cluster/resources --type vm --output-format json")"
echo "$vms" | jq -r '.[] | "   vmid \(.vmid) \(.name) status \(.status) maxmem \(.maxmem/1048576|floor)MiB"'
[ "$(echo "$vms" | jq '[.[] | select(.name=="talos-cp-1" or .name=="talos-wk-1" or .name=="talos-wk-2")] | length')" = 3 ] \
  || die "the three Talos VMs are not on the fixture after apply"
pve_ssh "ls -l /var/lib/vz/template/iso/ | grep -E 'talos-.*nocloud-amd64.img'" | sed 's/^/   /' \
  || die "the Talos image is not in local:iso after apply"

log "check the storage-link bridge on the fixture"
pve_ssh "ip -d link show vmbr1 | head -1; ip -d link show nic2 | head -1; ip -4 -br addr show vmbr1; bridge link show dev nic2 | head -1" | sed 's/^/   /'
[ "$(pve_ssh "cat /sys/class/net/vmbr1/mtu /sys/class/net/nic2/mtu" | tr '\n' ' ')" = "9000 9000 " ] \
  || die "vmbr1 and nic2 are not both at MTU 9000"
pve_ssh "ip -4 -o addr show vmbr1" | grep -q '10\.99\.0\.1/29' || die "vmbr1 does not have 10.99.0.1/29"
pve_ssh "test -e /sys/class/net/vmbr1/brif/nic2" || die "nic2 is not a port of vmbr1"
note "vmbr1: 10.99.0.1/29, MTU 9000, port nic2 at MTU 9000"

log "check each Talos VM's storage-link NIC (net1 on vmbr1, MTU 9000, no VLAN)"
for vmid in $(echo "$vms" | jq -r '.[] | select(.name=="talos-cp-1" or .name=="talos-wk-1" or .name=="talos-wk-2") | .vmid'); do
  # Match the fields only; the line also carries a generated MAC, which is never printed.
  net1="$(pve_ssh "qm config $vmid" | grep '^net1:' || true)"
  [ -n "$net1" ] || die "vmid $vmid has no net1"
  case "$net1" in *bridge=vmbr1*) ;; *) die "vmid $vmid net1 is not on vmbr1" ;; esac
  case "$net1" in *mtu=9000*) ;; *) die "vmid $vmid net1 is not at MTU 9000" ;; esac
  case "$net1" in *tag=*) die "vmid $vmid net1 is VLAN-tagged" ;; esac
  note "vmid $vmid: net1 virtio on vmbr1, MTU 9000, untagged"
done

log "check node-exporter on the fixture (host-metrics.tf)"
pve_ssh "systemctl is-active prometheus-node-exporter.service" | sed 's/^/   /' \
  || die "prometheus-node-exporter is not active after apply"
curl -fsS --max-time 10 "http://$host:9100/metrics" | grep -E '^node_(exporter_build_info|hwmon_chip_names)' | head -3 | sed 's/^/   /' \
  || die "node-exporter does not answer on $host:9100"
note "node-exporter: active, serving on $host:9100"

log "second plan (must be clean)"
if run_tofu plan -input=false -no-color -detailed-exitcode | tail -n 6; then
  note "clean: no drift, the config is idempotent"
else
  die "second plan is not clean (exit ${PIPESTATUS[0]})"
fi

if [ "$KEEP" = 1 ]; then note "kept (--keep): not destroying"; exit 0; fi

log "destroy (fixture only)"
run_tofu destroy -auto-approve -input=false -no-color | tail -n 6
left="$(pve_ssh "pvesh get /cluster/resources --type vm --output-format json" | jq 'length')"
[ "$left" = 0 ] || die "$left VMs are still on the fixture after destroy"
note "destroyed: no VMs left on the fixture"
if pve_ssh "test -e /sys/class/net/vmbr1"; then die "vmbr1 is still on the fixture after destroy"; fi
note "destroyed: vmbr1 is gone (nic2 keeps its own mtu 9000 stanza, as the owner step leaves it)"
if pve_ssh "dpkg -s prometheus-node-exporter >/dev/null 2>&1"; then
  die "prometheus-node-exporter is still installed on the fixture after destroy"
fi
note "destroyed: node-exporter purged"
