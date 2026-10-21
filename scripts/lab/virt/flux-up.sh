#!/usr/bin/env bash
# Put Flux on the libvirt Talos lab cluster and have it reconcile THIS working tree through
# kubernetes/clusters/lab — the same layers as production (infrastructure -> configs -> apps).
#
# Run after `just lab-virt-up` (which bootstraps Talos, fetches the kubeconfig and installs Cilium).
# Re-running it is the sync: it re-bakes the working tree, streams it into the Git server and
# reconciles. Touches only the cluster behind the lab kubeconfig, and refuses any other API server.
#
# The kind lab loads a baked image (lab-up.sh); a Talos node cannot, so the Git server here is
# scripts/lab/gitserver/k8s-runtime.yaml on the stock alpine image, and the bare repo is streamed in
# with `kubectl exec ... tar`. Only git-visible files are baked (lab-git-image.sh), never gitignored
# ones (talos/out, *.agekey, docs/private).
#
# Usage:
#   scripts/lab/virt/flux-up.sh                    # Git server + Flux + all three layers
#   SYNC=infrastructure scripts/lab/virt/flux-up.sh
#
# Env: KUBECONFIG_PATH (default talos/out/lab/kubeconfig), BRANCH (default: current branch),
#      SYNC (infrastructure|all, default all), AGE_KEY (default ~/.config/homelab/lab-age.key)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-$REPO_ROOT/talos/out/lab/kubeconfig}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
SYNC="${SYNC:-all}"
AGE_KEY="${AGE_KEY:-$HOME/.config/homelab/lab-age.key}"
GIT_NS="lab-git"
GIT_URL="http://homelab-git.${GIT_NS}.svc.cluster.local/homelab.git"
# Only a cluster on the lab network (docs/decisions.md §2.4) is accepted.
LAB_API_PREFIX="https://10.99.100."

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  "") : ;;
  *) die "unknown argument: $1" ;;
esac

for tool in kubectl flux age-keygen git rsync; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool (run scripts/lab/install-tools.sh)"
done

log "lab cluster"
[ -f "$KUBECONFIG_PATH" ] || die "no kubeconfig at $KUBECONFIG_PATH (run: just lab-virt-up)"
export KUBECONFIG="$KUBECONFIG_PATH"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "$server" in
  "$LAB_API_PREFIX"*) note "API server $server | branch $BRANCH | sync $SYNC" ;;
  *) die "refusing: $KUBECONFIG_PATH points at $server, not the lab network ($LAB_API_PREFIX*)" ;;
esac
kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null \
  || die "nodes are not Ready — is Cilium installed? (scripts/talos/install-cni.sh)"
kubectl get nodes -o wide

log "bake the working tree"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
# shellcheck source=SCRIPTDIR/../lab-git-image.sh
. "$REPO_ROOT/scripts/lab/lab-git-image.sh"
bake_lab_git_repo "$CTX" "$BRANCH" "$REPO_ROOT"
note "snapshot ${BRANCH}@$(git -C "$CTX/homelab.git" rev-parse --short "$BRANCH")"

log "Git server (namespace $GIT_NS)"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $GIT_NS
EOF
kubectl -n "$GIT_NS" create configmap homelab-git \
  --from-file=nginx.conf=scripts/lab/gitserver/nginx.conf \
  --from-file=entrypoint.sh=scripts/lab/gitserver/entrypoint.sh \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f scripts/lab/gitserver/k8s-runtime.yaml >/dev/null
kubectl -n "$GIT_NS" wait --for=condition=PodScheduled pod -l app=homelab-git --timeout=120s >/dev/null
pod=""
deadline=$(( $(date +%s) + 300 ))
while [ -z "$pod" ]; do
  pod="$(kubectl -n "$GIT_NS" get pod -l app=homelab-git \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] && break
  [ "$(date +%s)" -lt "$deadline" ] || die "Git server pod did not start (kubectl -n $GIT_NS describe pod)"
  sleep 3
done
# Extract beside the live repo, then swap, so the server never sees a half-written repo.
tar -C "$CTX" -cf - homelab.git | kubectl -n "$GIT_NS" exec -i "$pod" -- /bin/sh -c \
  'rm -rf /git/.in && mkdir /git/.in && tar -C /git/.in -xf - && rm -rf /git/homelab.git && mv /git/.in/homelab.git /git/homelab.git && rmdir /git/.in'
kubectl -n "$GIT_NS" rollout status deploy/homelab-git --timeout=300s
note "serving $GIT_URL"

# shellcheck source=SCRIPTDIR/../lab-flux.sh
. "$REPO_ROOT/scripts/lab/lab-flux.sh"
lab_flux_wire "$BRANCH" "$GIT_URL" "$AGE_KEY" "$SYNC"

log "status (Flux may still be progressing)"
flux get all -A
echo
note "watch:     KUBECONFIG=$KUBECONFIG_PATH flux get kustomizations --watch"
note "re-sync:   just lab-virt-flux"
note "tear down: just lab-virt-down"
