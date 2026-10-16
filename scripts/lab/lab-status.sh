#!/usr/bin/env bash
# Show what the lab cluster is doing: Flux sources/kustomizations/helm releases and workloads.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
CLUSTER="${CLUSTER:-homelab-lab}"

if ! kubectl config get-contexts "kind-${CLUSTER}" >/dev/null 2>&1; then
  echo "no lab cluster '$CLUSTER' (run scripts/lab/lab-up.sh)" >&2
  exit 1
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

echo '== flux =='
flux get all -A

echo
echo '== git server =='
kubectl -n lab-git get deploy,svc,pods

echo
echo '== helm releases =='
kubectl get helmrelease -A

echo
echo '== workloads (non-kube-system) =='
kubectl get deploy,sts,ds,pods -A --field-selector metadata.namespace!=kube-system
