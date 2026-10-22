#!/usr/bin/env bash
# Plan or apply one of the LIVE OpenTofu roots (the real UniFi controller, NAS and Proxmox host), with the
# credentials from ~/.config/homelab/<root>.env. The lab fixtures have their own scripts (scripts/lab/*-plan.sh);
# this one talks to the real systems.
#
#   plan   read-only: refreshes state and prints the diff, changes nothing
#   apply  interactive: tofu shows the plan and waits for "yes". Never -auto-approve; any extra args are
#          passed through, so `-auto-approve` is refused here on purpose.
#
# Per root:
#   unifi    unifi.env holds UNIFI_API_KEY (a local key from the controller), passed as TF_VAR_unifi_api_key.
#   truenas  truenas.env holds TF_VAR_truenas_api_key. The jolien/dunia passwords are write-only and only read
#            on the apply that creates the accounts (users.tf). `plan` always uses a throwaway value; `apply`
#            prompts for them while the accounts are not in state yet, and uses the throwaway once they are.
#            Exported TF_VAR_user_*_password values win over both.
#   proxmox  proxmox.env holds PROXMOX_VE_API_TOKEN. Creating the Talos VMs imports their disk over SSH as
#            root, through the ssh-agent only (providers.tf; ~/.ssh/config is ignored), so `apply` refuses to
#            start unless the agent holds a key.
#   cloudflare  cloudflare.env holds TF_VAR_cloudflare_api_token (Zone DNS:Edit on ardw.be + Account Cloudflare
#            Tunnel:Edit; never cert-manager's token). Its state holds the tunnel secret (its README.md, State).
#
# State is local (terraform.tfstate in the root, gitignored). Init runs once, when .terraform is missing.
#
# Usage:
#   scripts/live/tofu.sh plan unifi|truenas|proxmox|cloudflare [tofu args...]
#   scripts/live/tofu.sh apply unifi|truenas|proxmox|cloudflare [tofu args...]
#   scripts/live/tofu.sh plan all          # plan every root, in apply order
#
# Env: HOMELAB_CREDS (default ~/.config/homelab), TOFU (default tofu)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CREDS="${HOMELAB_CREDS:-$HOME/.config/homelab}"
TOFU="${TOFU:-tofu}"
# Apply order: VLAN 20 before the Talos VMs, NAS before Proxmox's storage link. cloudflare is independent.
ROOTS=(unifi truenas proxmox cloudflare)

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^# Env:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 2 ] || usage
action="$1" root="$2"
shift 2
case "$action" in plan|apply) ;; *) usage ;; esac

if [ "$root" = all ]; then
  [ "$action" = plan ] || die "apply one root at a time: $0 apply <root>"
  rc=0
  for r in "${ROOTS[@]}"; do "$0" plan "$r" "$@" || rc=1; done
  exit "$rc"
fi
[[ " ${ROOTS[*]} " == *" $root "* ]] || die "unknown root '$root' (one of: ${ROOTS[*]}, or 'all' for plan)"
for a in "$@"; do
  [ "$a" != -auto-approve ] && [ "$a" != --auto-approve ] || die "no -auto-approve on a live root"
done

dir="$REPO_ROOT/infrastructure/environments/homelab/$root"
env_file="$CREDS/$root.env"
[ -f "$dir/terraform.tfvars" ] || die "$dir/terraform.tfvars is missing (copy terraform.tfvars.example and fill it in)"
[ -f "$env_file" ] || die "$env_file is missing (see docs/runbooks/launch.md)"
[ "$(stat -c %a "$env_file")" = 600 ] || die "$env_file must be mode 600: chmod 600 $env_file"

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a

case "$root" in
  unifi)
    [ -n "${UNIFI_API_KEY:-}" ] || die "UNIFI_API_KEY is not set in $env_file"
    export TF_VAR_unifi_api_key="$UNIFI_API_KEY"
    ;;
  truenas)
    [ -n "${TF_VAR_truenas_api_key:-}" ] || die "TF_VAR_truenas_api_key is not set in $env_file"
    ;;
  cloudflare)
    [ -n "${TF_VAR_cloudflare_api_token:-}" ] || die "TF_VAR_cloudflare_api_token is not set in $env_file"
    ;;
  proxmox)
    [ -n "${PROXMOX_VE_API_TOKEN:-}" ] || die "PROXMOX_VE_API_TOKEN is not set in $env_file"
    if [ "$action" = apply ] && ! ssh-add -L >/dev/null 2>&1; then
      die "no key in the ssh-agent; the provider imports the VM disks over SSH as root. Run:
  eval \"\$(ssh-agent -s)\"; ssh-add <key root on the node accepts>
then check: ssh -F /dev/null root@<node> true"
    fi
    ;;
esac

cd "$dir"
if [ ! -d .terraform ]; then
  log "init $root"
  "$TOFU" init -input=false
fi

if [ "$root" = truenas ]; then
  throwaway="unused-on-this-run-$RANDOM$RANDOM"
  for u in jolien dunia; do
    var="TF_VAR_user_${u}_password"
    [ -z "${!var:-}" ] || continue
    if [ "$action" = apply ] && ! "$TOFU" state list 2>/dev/null | grep -qx "truenas_user.$u"; then
      read -rsp "Initial password for $u (min 12 chars, SMB login): " p1; echo
      read -rsp "Again: " p2; echo
      [ "$p1" = "$p2" ] || die "the two passwords for $u differ"
      export "$var=$p1"
      unset p1 p2
    else
      export "$var=$throwaway"
    fi
  done
fi

log "$action $root"
if [ "$action" = plan ]; then
  "$TOFU" plan -input=false "$@"
else
  "$TOFU" apply "$@" # not -input=false: that would also disable the "yes" prompt
fi
