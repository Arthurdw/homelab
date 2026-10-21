#!/usr/bin/env bash
# Install Cilium once, before Flux, on a freshly bootstrapped cluster (docs/runbooks/talos-bootstrap.md §7).
#
# !! LIVE OPERATION — writes to the cluster behind --kubeconfig. Guarded like bootstrap.sh: the
# !! kubeconfig must be named and --confirm (or TALOS_CNI_CONFIRM=1) must be given.
#
# Why: talos/patches/common.yaml removes Talos' bundled Flannel, and the Flux controllers are pods, so
# they cannot start until a CNI exists. Cilium itself is owned by Flux
# (kubernetes/infrastructure/cilium), so this installs the SAME chart, version and values, as the SAME
# Helm release (`cilium` in namespace `cilium`). Flux's helm-controller then finds the release and
# upgrades it in place; nothing is installed twice and later changes go through git only.
#
# Everything is read from the manifests: chart + version + values from cilium/release.yaml, the
# repository URL from infrastructure/sources.yaml, the namespace from cilium/namespace.yaml.
#
# Usage:
#   ./scripts/talos/install-cni.sh --kubeconfig talos/out/kubeconfig --confirm
#   ./scripts/talos/install-cni.sh --kubeconfig talos/out/lab/kubeconfig --dry-run
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CILIUM_DIR="$REPO_ROOT/kubernetes/infrastructure/cilium"
SOURCES="$REPO_ROOT/kubernetes/infrastructure/sources.yaml"

KUBECONFIG_PATH=""
DRY=0
CONFIRM="${TALOS_CNI_CONFIRM:-0}"
TIMEOUT="10m"

usage() { sed -n '2,18p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="${2:-}"; shift 2 ;;
    --timeout)    TIMEOUT="${2:-}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --confirm)    CONFIRM=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for t in helm kubectl yq; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found in PATH" >&2; exit 1; }
done

if [ -z "$KUBECONFIG_PATH" ]; then
  echo "refused: --kubeconfig <path> is required (e.g. talos/out/kubeconfig)" >&2
  exit 2
fi
[ -f "$KUBECONFIG_PATH" ] || { echo "kubeconfig not found: $KUBECONFIG_PATH" >&2; exit 1; }

release="$CILIUM_DIR/release.yaml"
name="$(yq 'select(.kind == "HelmRelease") | .metadata.name' "$release")"
namespace="$(yq 'select(.kind == "HelmRelease") | .metadata.namespace' "$release")"
chart="$(yq 'select(.kind == "HelmRelease") | .spec.chart.spec.chart' "$release")"
version="$(yq 'select(.kind == "HelmRelease") | .spec.chart.spec.version' "$release")"
repo_name="$(yq 'select(.kind == "HelmRelease") | .spec.chart.spec.sourceRef.name' "$release")"
repo_url="$(yq "select(.kind == \"HelmRepository\" and .metadata.name == \"$repo_name\") | .spec.url" "$SOURCES")"

for v in name namespace chart version repo_url; do
  if [ -z "${!v}" ] || [ "${!v}" = "null" ]; then
    echo "could not read $v from $release / $SOURCES" >&2
    exit 1
  fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
yq 'select(.kind == "HelmRelease") | .spec.values' "$release" >"$tmp/values.yaml"

echo "== $chart $version from $repo_url -> release $name in namespace $namespace =="
echo "== kubeconfig: $KUBECONFIG_PATH =="

helm_args=(
  upgrade --install "$name" "$chart"
  --repo "$repo_url" --version "$version"
  --namespace "$namespace"
  --values "$tmp/values.yaml"
  --kubeconfig "$KUBECONFIG_PATH"
  --wait --timeout "$TIMEOUT"
)

if [ "$DRY" = 1 ]; then
  echo "  [dry-run] kubectl --kubeconfig $KUBECONFIG_PATH apply -f $CILIUM_DIR/namespace.yaml"
  echo "  [dry-run] helm ${helm_args[*]}"
  echo "  values:"
  sed 's/^/    /' "$tmp/values.yaml"
  exit 0
fi

if [ "$CONFIRM" != 1 ]; then
  echo "refused: this installs Cilium into the cluster behind $KUBECONFIG_PATH." >&2
  echo "         re-run with --confirm (or TALOS_CNI_CONFIRM=1), or --dry-run to preview." >&2
  exit 2
fi

# The namespace carries the privileged Pod Security label; Helm's --create-namespace would not.
kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f "$CILIUM_DIR/namespace.yaml"
helm "${helm_args[@]}"

echo
echo "Cilium is installed. Nodes should turn Ready within a minute:"
echo "  kubectl --kubeconfig $KUBECONFIG_PATH get nodes -o wide"
echo "Flux adopts this release on its first reconcile of kubernetes/infrastructure/cilium."
