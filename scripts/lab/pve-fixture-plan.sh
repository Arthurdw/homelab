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
# Steps: init, validate, plan, apply, check the VMs and image on the fixture, second plan (must be
# clean: exit 0, no drift), destroy (--keep skips it), check they are gone.
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
  -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
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
# Sized for a 4 GiB nested Proxmox: stopped VMs, 2 GiB each, small thin disks, no data disk. The
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
talos_cp_memory_mb             = 2048
talos_cp_disk_gb               = 10
talos_wk_memory_mb             = 2048
talos_wk_cpu_cores             = 2
talos_wk_disk_gb               = 10
talos_wk_data_disk_gb          = null
talos_vm_started               = false
talos_vm_on_boot               = false
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

log "plan"
run_tofu plan -input=false -no-color -out=fixture.tfplan | tail -n 12
[ "$PLAN_ONLY" = 0 ] || { note "plan only: stopping"; exit 0; }

log "apply (fixture only)"
run_tofu apply -input=false -no-color fixture.tfplan | tail -n 12

log "check the VMs and the image on the fixture"
vms="$(pve_ssh "pvesh get /cluster/resources --type vm --output-format json")"
echo "$vms" | jq -r '.[] | "   vmid \(.vmid) \(.name) status \(.status) maxmem \(.maxmem/1048576|floor)MiB"'
[ "$(echo "$vms" | jq '[.[] | select(.name=="talos-cp-1" or .name=="talos-wk-1")] | length')" = 2 ] \
  || die "the two Talos VMs are not on the fixture after apply"
pve_ssh "ls -l /var/lib/vz/template/iso/ | grep -E 'talos-.*nocloud-amd64.img'" | sed 's/^/   /' \
  || die "the Talos image is not in local:iso after apply"

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
