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

log "rebuild + reload the Git server image (working tree)"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
# shellcheck source=SCRIPTDIR/lab-git-image.sh
. "$REPO_ROOT/scripts/lab/lab-git-image.sh"
bake_lab_git_image "$CTX" "$BRANCH" "$REPO_ROOT"
kind load docker-image homelab-git:lab --name "$CLUSTER"
kubectl -n lab-git rollout restart deploy/homelab-git
kubectl -n lab-git rollout status deploy/homelab-git --timeout=120s
printf '   serving working tree as %s\n' "$(git -C "$CTX/homelab.git" rev-parse --short "$BRANCH")"

log "re-apply the lab cluster Kustomizations (picks up path/postBuild changes)"
kubectl apply -f kubernetes/clusters/lab/cluster-settings.yaml >/dev/null
for k in infrastructure infrastructure-configs apps; do
  if kubectl -n flux-system get kustomization "$k" >/dev/null 2>&1; then
    kubectl apply -f "kubernetes/clusters/lab/$k.yaml" >/dev/null
  fi
done

log "reconcile Flux"
flux reconcile source git flux-system
for k in infrastructure infrastructure-configs apps; do
  if kubectl -n flux-system get kustomization "$k" >/dev/null 2>&1; then
    flux reconcile kustomization "$k" --with-source --timeout=5m || true
  fi
done

log "status"
flux get all -A
