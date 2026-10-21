#!/usr/bin/env bash
# Bring up the local lab: a kind cluster + an in-cluster Git server serving THIS repo, with Flux
# reconciling the REAL kubernetes/ tree. Touch nothing outside this workstation.
#
# The Git server is baked from the CURRENT WORKING TREE (see scripts/lab/lab-git-image.sh), and
# Flux reconciles the LAB cluster directory kubernetes/clusters/lab — so the lab exercises the
# lab cluster-settings (10.99.100.0/24), not the production ones.
#
# See docs/lab.md. Expected outcome: `flux get all -A` shows the GitRepository and the
# infrastructure/apps Kustomizations reconciling the committed manifests.
#
# Env: CLUSTER (default homelab-lab), BRANCH (default: current branch), SYNC (infrastructure|all)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CLUSTER="${CLUSTER:-homelab-lab}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
SYNC="${SYNC:-all}"
GIT_NS="lab-git"
GIT_URL="http://homelab-git.${GIT_NS}.svc.cluster.local/homelab.git"
AGE_KEY="${AGE_KEY:-$HOME/.config/homelab/lab-age.key}"

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

for tool in kind kubectl flux age-keygen; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool (run scripts/lab/install-tools.sh)" >&2; exit 1; }
done

log "1/4 tool check"
note "kind $(kind version | awk '{print $2}') | flux $(flux --version) | branch $BRANCH"

log "2/4 kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  note "already exists"
else
  kind create cluster --name "$CLUSTER" --wait 180s
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

log "3/4 build + load the lab Git server image"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
# shellcheck source=SCRIPTDIR/lab-git-image.sh
. "$REPO_ROOT/scripts/lab/lab-git-image.sh"
bake_lab_git_image "$CTX" "$BRANCH" "$REPO_ROOT"
kind load docker-image homelab-git:lab --name "$CLUSTER"
note "image baked from the WORKING TREE (${BRANCH}@$(git -C "$CTX/homelab.git" rev-parse --short "$BRANCH"))"

log "4/4 deploy the Git server"
kubectl apply -f scripts/lab/gitserver/k8s.yaml >/dev/null
kubectl -n "$GIT_NS" rollout status deploy/homelab-git --timeout=180s
note "serving $GIT_URL"

# shellcheck source=SCRIPTDIR/lab-flux.sh
. "$REPO_ROOT/scripts/lab/lab-flux.sh"
lab_flux_wire "$BRANCH" "$GIT_URL" "$AGE_KEY" "$SYNC"

log "status (Flux may still be progressing)"
flux get all -A
echo
note "lab is up. Inspect with: just lab-status | tear down with: just lab-down"
