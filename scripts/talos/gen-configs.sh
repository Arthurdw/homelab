#!/usr/bin/env bash
# Generate Talos machine configs + talosconfig into a gitignored output directory.
#
# Offline scaffolding for Phase 5. This script only WRITES LOCAL FILES: it never contacts a node,
# a Kubernetes API, or the Proxmox host.
#
#   ./scripts/talos/gen-configs.sh            # generate into TALOS_OUT_DIR
#   ./scripts/talos/gen-configs.sh --dry-run  # print the command, write nothing
#   ./scripts/talos/gen-configs.sh --force    # regenerate even if output already exists
#
# Values come from talos/inputs.env (the single place for undecided values) and from versions.yaml
# (the authoritative version pin). See talos/README.md.
#
# Idempotent: if the output directory already holds generated configs, the script exits without
# touching them unless --force is given, because regenerating REPLACES the cluster PKI/secrets.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INPUTS="${TALOS_INPUTS:-$REPO_ROOT/talos/inputs.env}"

DRY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

# run <cmd...> — execute, or print in --dry-run.
run() {
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# --- tooling ---------------------------------------------------------------
if ! command -v talosctl >/dev/null 2>&1; then
  echo "talosctl not found in PATH (expected ~/.local/bin — see docs/lab.md)" >&2
  exit 1
fi

# --- inputs ----------------------------------------------------------------
if [ ! -f "$INPUTS" ]; then
  echo "inputs file not found: $INPUTS" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$INPUTS"

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
CLUSTER_ENDPOINT="${CLUSTER_ENDPOINT:-}"
INSTALL_DISK="${INSTALL_DISK:-/dev/sda}"
INSTALL_IMAGE="${INSTALL_IMAGE:-}"
ADDITIONAL_SANS="${ADDITIONAL_SANS:-}"

# --- authoritative versions (single source: versions.yaml) -----------------
yaml_get() {
  awk -F'"' -v key="$1" '$0 ~ "^  " key ":" { print $2; exit }' "$REPO_ROOT/versions.yaml"
}

TALOS_VERSION="$(yaml_get talos)"
KUBERNETES_VERSION="$(yaml_get kubernetes)"
if [ -z "$TALOS_VERSION" ] || [ -z "$KUBERNETES_VERSION" ]; then
  echo "could not read talos/kubernetes pins from versions.yaml" >&2
  exit 1
fi
KUBERNETES_VERSION="${KUBERNETES_VERSION#v}"
if [ -z "$INSTALL_IMAGE" ]; then
  INSTALL_IMAGE="ghcr.io/siderolabs/installer:${TALOS_VERSION}"
fi

if [ -z "$CLUSTER_ENDPOINT" ]; then
  echo "CLUSTER_ENDPOINT is empty — set it in $INPUTS (TODO(GATE 0))" >&2
  exit 1
fi

OUT_DIR="${TALOS_OUT_DIR:-$REPO_ROOT/talos/out}"
case "$OUT_DIR" in
  /*) : ;;                                    # already absolute
  *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;;
esac

# --- idempotency -----------------------------------------------------------
if [ -f "$OUT_DIR/talosconfig" ] && [ "$FORCE" = 0 ]; then
  log "configs already present in $OUT_DIR — leaving them untouched."
  log "re-run with --force to regenerate (this REPLACES the cluster PKI/secrets in those files)."
  exit 0
fi

# --- build the command -----------------------------------------------------
args=(
  gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT"
  --talos-version "$TALOS_VERSION"
  --kubernetes-version "$KUBERNETES_VERSION"
  --install-disk "$INSTALL_DISK"
  --install-image "$INSTALL_IMAGE"
  --with-docs=false
  --with-examples=false
  --output "$OUT_DIR"
)

# patch_args <flag> <file> — add <file> as a patch only if it has non-comment content.
# talosctl rejects an empty/comment-only patch (it is parsed as JSON6902), so such a file must be
# skipped rather than passed. This keeps patches/worker.yaml as a safe, inactive template.
patch_args() {
  local flag="$1" file="$2"
  if [ -f "$file" ] && grep -qvE '^[[:space:]]*(#|$)' "$file"; then
    args+=("$flag" "@$file")
  else
    log "note: $file is empty/comments-only — skipping $flag"
  fi
}

patch_args --config-patch               "$REPO_ROOT/talos/patches/common.yaml"
patch_args --config-patch-control-plane "$REPO_ROOT/talos/patches/controlplane.yaml"
patch_args --config-patch-worker        "$REPO_ROOT/talos/patches/worker.yaml"

if [ -n "$ADDITIONAL_SANS" ]; then
  IFS=',' read -ra sans <<<"$ADDITIONAL_SANS"
  for san in "${sans[@]}"; do
    args+=(--additional-sans "$san")
  done
fi

log "== Talos $TALOS_VERSION / Kubernetes $KUBERNETES_VERSION =="
log "== cluster: $CLUSTER_NAME  endpoint: $CLUSTER_ENDPOINT =="
log "== output (gitignored): $OUT_DIR =="
run mkdir -p "$OUT_DIR"
run talosctl "${args[@]}"

if [ "$DRY" = 0 ]; then
  log
  log "generated:"
  ls -1 "$OUT_DIR"
  log
  log "these files embed cluster secrets — gitignored, never commit them."
  log "next: ./scripts/talos/validate.sh"
fi
