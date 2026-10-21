#!/usr/bin/env bash
# Plan, apply and re-plan infrastructure/environments/homelab/unifi against the L1 UniFi fixture
# (scripts/lab/unifi-fixture.sh), and against nothing else.
#
# The root is COPIED into a scratch directory under the fixture's gitignored out dir and run there:
# its own .terraform, terraform.tfvars and any backend are never read, and state is a local file in
# the scratch directory. The endpoint is refused unless it is https://127.0.0.1:<port> or
# https://localhost:<port>. UNIFI_* / TF_VAR_unifi_* / TF_CLI_ARGS* from the calling shell are dropped,
# so a real key or URL exported for the live root can never leak in.
#
# The fixture is a self-hosted controller, which has no API-key support (that is a UniFi OS feature),
# so the provider logs in with the fixture's random local admin (UNIFI_USERNAME / UNIFI_PASSWORD) and
# the root's required `unifi_api_key` variable is passed empty. The live root uses an API key.
#
# Steps: init, validate, plan, apply, check the network on the controller, second plan (must be clean:
# exit 0, no drift). No `destroy`: the network carries prevent_destroy on purpose; the fixture's state
# is thrown away with `scripts/lab/unifi-fixture.sh down` instead.
#
# Usage:
#   scripts/lab/unifi-fixture-plan.sh            # needs: just lab-unifi-up
#   scripts/lab/unifi-fixture-plan.sh --plan     # init, validate and plan only
#
# Env: LAB_UNIFI_DIR (default talos/out/lab-unifi), TOFU (default tofu)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${LAB_UNIFI_DIR:-$REPO_ROOT/talos/out/lab-unifi}"
ENV_FILE="$OUT_DIR/fixture.env"
ROOT_SRC="$REPO_ROOT/infrastructure/environments/homelab/unifi"
WORK="$OUT_DIR/tofu"
TOFU="${TOFU:-tofu}"

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

PLAN_ONLY=0
case "${1:-}" in
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  --plan) PLAN_ONLY=1 ;;
  "") : ;;
  *) die "unknown argument: $1" ;;
esac

for tool in "$TOFU" curl jq rsync; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

[ -f "$ENV_FILE" ] || die "no fixture credentials at $ENV_FILE (run: just lab-unifi-up)"
# shellcheck disable=SC1090
. "$ENV_FILE"

log "fixture endpoint"
case "${UNIFI_FIXTURE_URL:-}" in
  https://127.0.0.1:[0-9]*|https://localhost:[0-9]*) note "endpoint $UNIFI_FIXTURE_URL" ;;
  *) die "refusing: '${UNIFI_FIXTURE_URL:-}' is not https://127.0.0.1:<port> or https://localhost:<port>" ;;
esac
# A host that merely starts with 127.0.0.1 or localhost (127.0.0.1.evil.test) must not pass.
host="${UNIFI_FIXTURE_URL#https://}"
host="${host%%:*}"
case "$host" in 127.0.0.1|localhost) : ;; *) die "refusing: host '$host' is not loopback" ;; esac
case "${UNIFI_FIXTURE_URL#https://*:}" in *[!0-9]*) die "refusing: '$UNIFI_FIXTURE_URL' has a path or extra parts" ;; esac
curl -sk --max-time 5 "$UNIFI_FIXTURE_URL/status" | grep -q '"up":true' \
  || die "no controller answering at $UNIFI_FIXTURE_URL (run: just lab-unifi-up)"

log "scratch copy of the root ($WORK)"
mkdir -p "$WORK"
rsync -a --delete --include='*.tf' --include='.terraform.lock.hcl' --exclude='*' "$ROOT_SRC/" "$WORK/"
umask 077
cat >"$WORK/fixture.auto.tfvars" <<TFVARS
unifi_api_url        = "$UNIFI_FIXTURE_URL"
unifi_allow_insecure = true
unifi_site           = "default"
TFVARS

run_tofu() {
  (
    cd "$WORK"
    env -u TF_CLI_ARGS -u TF_CLI_ARGS_init -u TF_CLI_ARGS_plan -u TF_CLI_ARGS_apply -u TF_WORKSPACE \
      -u UNIFI_API -u UNIFI_API_KEY -u UNIFI_INSECURE -u UNIFI_SITE \
      -u TF_VAR_unifi_api_url -u TF_VAR_unifi_site -u TF_VAR_unifi_allow_insecure \
      TF_IN_AUTOMATION=1 TF_VAR_unifi_api_key="" \
      UNIFI_USERNAME="$UNIFI_FIXTURE_USERNAME" UNIFI_PASSWORD="$UNIFI_FIXTURE_PASSWORD" \
      "$TOFU" "$@"
  )
}

log "init (local state, no backend)"
run_tofu init -backend=false -input=false -no-color | tail -n 4
log "validate"
run_tofu validate -no-color

log "plan"
run_tofu plan -input=false -no-color -out=fixture.tfplan | tail -n 40
[ "$PLAN_ONLY" = 0 ] || { note "plan only: stopping"; exit 0; }

log "apply (fixture only)"
run_tofu apply -input=false -no-color fixture.tfplan | tail -n 10

log "check the network on the fixture controller"
jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT
curl -sk --max-time 10 -c "$jar" -X POST "$UNIFI_FIXTURE_URL/api/login" -H 'content-type: application/json' \
  -d "$(jq -nc --arg u "$UNIFI_FIXTURE_USERNAME" --arg p "$UNIFI_FIXTURE_PASSWORD" '{username:$u,password:$p}')" >/dev/null
curl -sk --max-time 10 -b "$jar" "$UNIFI_FIXTURE_URL/api/s/default/rest/networkconf" \
  | jq -r '.data[] | select(.name=="hl-k8s") | "   hl-k8s: vlan \(.vlan) subnet \(.ip_subnet) purpose \(.purpose) dhcpd \(.dhcpd_start)-\(.dhcpd_stop)"' \
  | tee /dev/stderr | grep -q 'hl-k8s' || die "hl-k8s is not on the controller after apply"

log "second plan (must be clean)"
if run_tofu plan -input=false -no-color -detailed-exitcode | tail -n 6; then
  note "clean: no drift, the config is idempotent"
else
  die "second plan is not clean (exit ${PIPESTATUS[0]})"
fi
