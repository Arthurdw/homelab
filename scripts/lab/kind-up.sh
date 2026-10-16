#!/usr/bin/env bash
# Create a local kind cluster for manifest / Flux testing.
#
# LAB ONLY — touches nothing outside this workstation. Safe to run anytime.
# See docs/lab.md.
set -euo pipefail

CLUSTER="${CLUSTER:-homelab-lab}"
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

if ! command -v kind >/dev/null 2>&1; then
  echo "Installing kind ${KIND_VERSION} into ${BIN_DIR}..."
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac
  curl -sSLo "$BIN_DIR/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}"
  chmod +x "$BIN_DIR/kind"
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "Cluster '$CLUSTER' already exists."
else
  echo "Creating kind cluster '$CLUSTER'..."
  kind create cluster --name "$CLUSTER" --wait 120s
fi

kubectl cluster-info --context "kind-${CLUSTER}"
echo
echo "Done. Delete with: just lab-kind-down"
