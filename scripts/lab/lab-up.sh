#!/usr/bin/env bash
# Bring up the local lab: a kind cluster + an in-cluster Git server serving THIS repo, with Flux
# reconciling the REAL kubernetes/ tree. Touch nothing outside this workstation.
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

log "1/8 tool check"
note "kind $(kind version | awk '{print $2}') | flux $(flux --version) | branch $BRANCH"

log "2/8 kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  note "already exists"
else
  kind create cluster --name "$CLUSTER" --wait 180s
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

log "3/8 build + load the lab Git server image"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
cp scripts/lab/gitserver/Dockerfile scripts/lab/gitserver/nginx.conf scripts/lab/gitserver/entrypoint.sh "$CTX/"
git clone --quiet --mirror "$REPO_ROOT" "$CTX/homelab.git"
docker build -q -t homelab-git:lab "$CTX" >/dev/null
kind load docker-image homelab-git:lab --name "$CLUSTER"
note "image baked from $(git -C "$CTX/homelab.git" rev-parse --short "$BRANCH")"

log "4/8 deploy the Git server"
kubectl apply -f scripts/lab/gitserver/k8s.yaml >/dev/null
kubectl -n "$GIT_NS" rollout status deploy/homelab-git --timeout=180s
note "serving $GIT_URL"

log "5/8 install Flux"
flux install
kubectl -n flux-system wait --for=condition=Available --timeout=180s \
  deploy/source-controller deploy/kustomize-controller deploy/helm-controller

log "6/8 SOPS age key (lab-only, outside the repo)"
mkdir -p "$(dirname "$AGE_KEY")"
if [ ! -f "$AGE_KEY" ]; then
  age-keygen -o "$AGE_KEY" 2>/dev/null
  note "generated $AGE_KEY"
fi
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey="$AGE_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
note "sops-age secret present (decryption key for the lab)"

log "7/8 wire Flux to the repo"
flux create source git flux-system --url="$GIT_URL" --branch="$BRANCH" --interval=1m --export \
  | kubectl apply -f - >/dev/null
flux reconcile source git flux-system
kubectl -n flux-system wait --for=condition=Ready gitrepository/flux-system --timeout=120s

log "8/8 apply the REAL cluster Kustomizations"
kubectl apply -f kubernetes/clusters/homelab/infrastructure.yaml >/dev/null
if [ "$SYNC" = "all" ]; then
  kubectl apply -f kubernetes/clusters/homelab/apps.yaml >/dev/null
else
  note "SYNC=$SYNC — apps Kustomization not applied"
fi
flux reconcile kustomization infrastructure --with-source || true

log "status (Flux may still be progressing)"
flux get all -A
echo
note "lab is up. Inspect with: just lab-status | tear down with: just lab-down"
