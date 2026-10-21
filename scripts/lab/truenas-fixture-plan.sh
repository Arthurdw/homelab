#!/usr/bin/env bash
# Plan, apply and re-plan infrastructure/environments/homelab/truenas against the L1 TrueNAS fixture
# (scripts/lab/truenas-fixture.sh), and against nothing else.
#
# The root is COPIED into a scratch directory under the fixture's gitignored out dir and run there:
# its own .terraform, terraform.tfvars and any backend are never read, and state is a local file in
# the scratch directory. The endpoint is refused unless it is exactly wss://10.99.100.<1-254>/api/current,
# an address on the isolated lab network (never the real NAS). TRUENAS_* / TF_VAR_truenas* /
# TF_VAR_k8s_* / TF_CLI_ARGS* from the calling shell are dropped, so a real key or URL exported for
# the live root can never leak in. The fixture's own API key is passed through TF_VAR_truenas_api_key.
#
# Lab-only overrides, written to fixture.auto.tfvars: truenas_insecure = true (self-signed
# certificate) and k8s_nfs_allowed_networks = the lab /24 (the production default is the /30
# storage link, which does not exist in the lab) and timemachine_jolien_quota_gib = 4 (the data disk is
# 10 GiB; the real value is the owner's, per Mac). The SMB user the Time Machine share needs is created
# on the fixture first (the owner does that by hand on the real NAS). Dataset name, maproot and the snapshot task keep
# their production values.
#
# Steps: init, fmt -check, validate, plan, apply, check the dataset, the NFS share and the snapshot
# task on the NAS, second plan (must be clean: exit 0, no drift). No `destroy`: the dataset and the
# share carry prevent_destroy on purpose (an application-data red line); the fixture's state is
# thrown away with `scripts/lab/truenas-fixture.sh down` instead.
#
# Usage:
#   scripts/lab/truenas-fixture-plan.sh            # needs: just lab-truenas
#   scripts/lab/truenas-fixture-plan.sh --plan     # init, validate and plan only
#   scripts/lab/truenas-fixture-plan.sh --keep     # same as no argument; the scratch dir is always kept
#   scripts/lab/truenas-fixture-plan.sh --endpoint wss://10.99.100.21/api/current   # override (still guarded)
#
# Env: LAB_TRUENAS_DIR (default talos/out/lab-truenas), TOFU (default tofu)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${LAB_TRUENAS_DIR:-$REPO_ROOT/talos/out/lab-truenas}"
ENV_FILE="$OUT_DIR/fixture.env"
ROOT_SRC="$REPO_ROOT/infrastructure/environments/homelab/truenas"
WORK="$OUT_DIR/tofu"
TOFU="${TOFU:-tofu}"
RPC="$REPO_ROOT/scripts/lab/virt/truenas-rpc.py"
LAB_CIDR="10.99.100.0/24"

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Exactly wss://10.99.100.<n>/api/current, n in 1..254, no leading zeros, nothing before or after.
# A lookalike (10.99.100.21.evil.test, 10.99.100.21@host, extra octets, a port, a path) must not pass.
guard_endpoint() {
  local url="$1" n
  [[ "$url" =~ ^wss://10\.99\.100\.([1-9][0-9]{0,2})/api/current$ ]] \
    || die "refusing: '$url' is not wss://10.99.100.<n>/api/current"
  n="${BASH_REMATCH[1]}"
  [ "$n" -le 254 ] || die "refusing: octet $n is out of range"
}

PLAN_ONLY=0
ENDPOINT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    --plan) PLAN_ONLY=1 ;;
    --keep) : ;;
    --endpoint) shift; [ $# -gt 0 ] || die "--endpoint needs a value"; ENDPOINT_ARG="$1" ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# The guard runs before anything is read or started.
if [ -n "$ENDPOINT_ARG" ]; then guard_endpoint "$ENDPOINT_ARG"; fi

for tool in "$TOFU" jq rsync python3; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

[ -f "$ENV_FILE" ] || die "no fixture credentials at $ENV_FILE (run: just lab-truenas)"
# shellcheck disable=SC1090
. "$ENV_FILE"
ENDPOINT="${ENDPOINT_ARG:-${LAB_TRUENAS_ENDPOINT:-}}"
log "fixture endpoint"
guard_endpoint "$ENDPOINT"
[ -n "${LAB_TRUENAS_API_KEY:-}" ] || die "no API key in $ENV_FILE (run: just lab-truenas)"
note "endpoint $ENDPOINT"
host="${ENDPOINT#wss://}"
host="${host%%/*}"
timeout 5 bash -c "exec 3<>/dev/tcp/$host/443" 2>/dev/null \
  || die "nothing answering on $host:443 (run: just lab-truenas)"

log "scratch copy of the root ($WORK)"
mkdir -p "$WORK"
chmod 700 "$OUT_DIR" "$WORK"
rsync -a --delete --include='*.tf' --include='.terraform.lock.hcl' --exclude='*' "$ROOT_SRC/" "$WORK/"
umask 077
# Pre-aligned so `tofu fmt -check` stays clean (the `=` signs line up on the longest name).
cat >"$WORK/fixture.auto.tfvars" <<TFVARS
truenas_endpoint             = "$ENDPOINT"
truenas_insecure             = true
k8s_nfs_allowed_networks     = ["$LAB_CIDR"]
timemachine_jolien_quota_gib = 4
TFVARS

run_tofu() {
  (
    cd "$WORK"
    # Drop every variable a real run could rely on, then set only what the fixture needs.
    unset_args=()
    while IFS='=' read -r name _; do
      case "$name" in TRUENAS_*|TF_VAR_truenas*|TF_VAR_k8s_*|TF_CLI_ARGS*|TF_WORKSPACE) unset_args+=(-u "$name") ;; esac
    done < <(env)
    env "${unset_args[@]}" TF_IN_AUTOMATION=1 TF_VAR_truenas_api_key="$LAB_TRUENAS_API_KEY" "$TOFU" "$@"
  )
}

nas_rpc() {  # calls on stdin; uses the fixture API key
  TRUENAS_RPC_API_KEY="$LAB_TRUENAS_API_KEY" python3 -I "$RPC" "$ENDPOINT"
}

log "SMB user for the Time Machine share (fixture only; the owner creates it by hand on the real NAS)"
if [ "$(echo '[["user.query",[[["username","=","jolien"]]]]]' | nas_rpc | jq '.[0] | length')" = 0 ]; then
  pw="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  jq -n --arg pw "$pw" '[["user.create",[{"username":"jolien","full_name":"Jolien (lab)","group_create":true,"smb":true,"password":$pw,"shell":"/usr/sbin/nologin"}]]]' | nas_rpc >/dev/null
  note "created user jolien"
else
  note "user jolien exists"
fi

# The Time Machine preset is refused unless the SMB service has the Apple extensions on. On the real NAS
# that is a manual step (runbooks/household-backups.md); on the fixture it is set here.
echo '[["smb.update",[{"aapl_extensions":true}]]]' | nas_rpc >/dev/null && note "SMB aapl_extensions on"

log "init (local state, no backend)"
run_tofu init -backend=false -input=false -no-color | tail -n 4
log "fmt -check (fixture.auto.tfvars included)"
run_tofu fmt -check -recursive -no-color && note "formatted"
log "validate"
run_tofu validate -no-color

log "plan"
run_tofu plan -input=false -no-color -out=fixture.tfplan | tail -n 40
[ "$PLAN_ONLY" = 0 ] || { note "plan only: stopping"; exit 0; }

log "apply (fixture only)"
run_tofu apply -input=false -no-color fixture.tfplan | tail -n 10

log "check the dataset, the share and the snapshot task on the fixture NAS"
res="$(echo '[["pool.dataset.query",[[["name","=","main/k8s"]]]],["sharing.nfs.query",[[["path","=","/mnt/main/k8s"]]]],["pool.snapshottask.query",[[["dataset","=","main/k8s"]]]]]' | nas_rpc)"
echo "$res" | jq -r '"   dataset main/k8s: \(.[0] | length) (share_type NFS acltype \(.[0][0].acltype.value // "?"))",
  "   nfs share /mnt/main/k8s: \(.[1] | length) (networks \(.[1][0].networks // []), maproot \(.[1][0].maproot_user // "?"):\(.[1][0].maproot_group // "?"), enabled \(.[1][0].enabled // "?"))",
  "   snapshot task: \(.[2] | length) (\(.[2][0].lifetime_value // "?") \(.[2][0].lifetime_unit // "?"), \(.[2][0].naming_schema // "?"))"'
echo "$res" | jq -e '(.[0] | length) == 1 and (.[1] | length) == 1 and (.[2] | length) == 1' >/dev/null \
  || die "the dataset, the share or the snapshot task is missing on the NAS after apply"

log "check the Time Machine share, its quota and the new NFS exports"
res="$(echo '[["sharing.smb.query",[[["name","=","timemachine-jolien"]]]],["pool.dataset.query",[[["name","=","main/backups/timemachine/jolien"]]]],["sharing.nfs.query",[[["path","in",["/mnt/main/backups/kopia","/mnt/main/apps/seafile"]]]]]]' | nas_rpc)"
echo "$res" | jq -r '"   smb share: \(.[0] | length) (purpose \(.[0][0].purpose // "?"), path \(.[0][0].path // "?"), timemachine_quota \(.[0][0].options.timemachine_quota // "?"))",
  "   tm dataset quota bytes: \(.[1][0].quota.rawvalue // "?")",
  "   nfs exports: \([.[2][].path] | join(" "))"'
echo "$res" | jq -e '(.[0] | length) == 1 and .[0][0].purpose == "TIMEMACHINE_SHARE" and (.[1] | length) == 1 and (.[2] | length) == 2' >/dev/null \
  || die "the Time Machine share or the Kopia/Seafile exports are missing on the NAS after apply"

log "second plan (must be clean)"
set +e
run_tofu plan -input=false -no-color -detailed-exitcode > "$WORK/second-plan.log" 2>&1
rc=$?
set -e
tail -n 6 "$WORK/second-plan.log"
if [ "$rc" = 0 ]; then
  note "clean: no drift, the config is idempotent"
else
  die "second plan is not clean (exit $rc; full output in $WORK/second-plan.log)"
fi
