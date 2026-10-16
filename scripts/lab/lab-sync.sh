#!/usr/bin/env bash
# Fast lab iteration: rebuild the lab Git image from the CURRENT working tree, reload it into
# kind, restart the git server, and make Flux re-sync. Does not recreate the cluster.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CLUSTER="${CLUSTER:-homelab-lab}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

kubectl config use-context "kind-${CLUSTER}" >/dev/null

log "rebuild + reload the Git server image"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
cp scripts/lab/gitserver/Dockerfile scripts/lab/gitserver/nginx.conf scripts/lab/gitserver/entrypoint.sh "$CTX/"
git clone --quiet --mirror "$REPO_ROOT" "$CTX/homelab.git"
docker build -q -t homelab-git:lab "$CTX" >/dev/null
kind load docker-image homelab-git:lab --name "$CLUSTER"
kubectl -n lab-git rollout restart deploy/homelab-git
kubectl -n lab-git rollout status deploy/homelab-git --timeout=120s
printf '   serving revision %s\n' "$(git -C "$CTX/homelab.git" rev-parse --short "$BRANCH")"

log "reconcile Flux"
flux reconcile source git flux-system
for k in infrastructure infrastructure-configs apps; do
  if kubectl -n flux-system get kustomization "$k" >/dev/null 2>&1; then
    flux reconcile kustomization "$k" --with-source --timeout=5m || true
  fi
done

log "status"
flux get all -A
