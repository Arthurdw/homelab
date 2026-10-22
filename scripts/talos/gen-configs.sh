#!/usr/bin/env bash
# Generate Talos machine configs + talosconfig into a gitignored output directory.
#
# Offline scaffolding for Phase 5. This script only WRITES LOCAL FILES: it never contacts a node,
# a Kubernetes API, or the Proxmox host.
#
#   ./scripts/talos/gen-configs.sh            # generate into TALOS_OUT_DIR
#   ./scripts/talos/gen-configs.sh --dry-run  # print the command, write nothing
#   ./scripts/talos/gen-configs.sh --regen    # rebuild controlplane.yaml/worker.yaml, SAME PKI
#   ./scripts/talos/gen-configs.sh --force    # NEW PKI: only for a cluster that does not exist yet
#
# Values come from talos/inputs.env (the single place for undecided values) and from versions.yaml
# (the authoritative version pin). See talos/README.md.
#
# Idempotent: if the output directory already holds generated configs, the script exits without
# touching them unless --force is given, because --force REPLACES the cluster PKI/secrets.
#
# --regen is the safe path for a running cluster after a patch or input change. It needs the secrets
# bundle (TALOS_SECRETS, default <out>/secrets.yaml) and refuses without it; it reads the bundle but
# never writes it. It copies the old controlplane.yaml/worker.yaml to <out>/backup-<UTC time>/, then
# runs `talosctl gen config --with-secrets` for those two files only (talosconfig is left alone).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INPUTS="${TALOS_INPUTS:-$REPO_ROOT/talos/inputs.env}"

DRY=0
FORCE=0
REGEN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --regen)   REGEN=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [ "$FORCE" = 1 ] && [ "$REGEN" = 1 ]; then
  echo "--force and --regen are exclusive: --regen keeps the PKI, --force replaces it" >&2
  exit 2
fi

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
# Image Factory coordinates for the derived installer. ghcr.io/siderolabs/installer is no longer
# published (no tags); the installer must also match the platform the node booted (nocloud on Proxmox).
TALOS_PLATFORM="${TALOS_PLATFORM:-nocloud}"
TALOS_SCHEMATIC="${TALOS_SCHEMATIC:-a31c606a63e512b77145a19a7441828049b1567936ab8335f24bf8d28e831736}"
ADDITIONAL_SANS="${ADDITIONAL_SANS:-}"
# Worker patch (the local-path user volume). An inputs file may point this at another file, or at
# an empty string to skip it, for environments whose worker has no dedicated data disk (the lab).
WORKER_PATCH="${WORKER_PATCH-$REPO_ROOT/talos/patches/worker.yaml}"
# Storage-link NIC + node IP pinning (docs/decisions.md §2.2). Production only: the lab inputs set
# both to an empty string, the same way as WORKER_PATCH.
CONTROLPLANE_NETWORK_PATCH="${CONTROLPLANE_NETWORK_PATCH-$REPO_ROOT/talos/patches/network-controlplane.yaml}"
WORKER_NETWORK_PATCH="${WORKER_NETWORK_PATCH-$REPO_ROOT/talos/patches/network-worker.yaml}"
# NVIDIA driver modules + sysctl for the passed-through Tesla P4 (talos/patches/gpu-worker.yaml).
# Production only: the lab has no GPU, so its inputs set this to an empty string as well.
GPU_WORKER_PATCH="${GPU_WORKER_PATCH-$REPO_ROOT/talos/patches/gpu-worker.yaml}"

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
  INSTALL_IMAGE="factory.talos.dev/${TALOS_PLATFORM}-installer/${TALOS_SCHEMATIC}:${TALOS_VERSION}"
fi

if [ -z "$CLUSTER_ENDPOINT" ]; then
  echo "CLUSTER_ENDPOINT is empty — set it in $INPUTS (TODO(GATE 4))" >&2
  exit 1
fi

OUT_DIR="${TALOS_OUT_DIR:-$REPO_ROOT/talos/out}"
case "$OUT_DIR" in
  /*) : ;;                                    # already absolute
  *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;;
esac

SECRETS="${TALOS_SECRETS:-$OUT_DIR/secrets.yaml}"

# --- idempotency -----------------------------------------------------------
if [ "$REGEN" = 1 ]; then
  if [ ! -f "$SECRETS" ]; then
    echo "--regen: no secrets bundle at $SECRETS; refusing (without it the PKI would change)." >&2
    echo "derive it once from the existing control-plane config, which carries the same PKI:" >&2
    echo "  talosctl gen secrets --from-controlplane-config $OUT_DIR/controlplane.yaml -o $SECRETS" >&2
    echo "or point TALOS_SECRETS at the bundle. Never use --force on a running cluster." >&2
    exit 1
  fi
elif [ -f "$OUT_DIR/talosconfig" ] && [ "$FORCE" = 0 ]; then
  log "configs already present in $OUT_DIR — leaving them untouched."
  log "after a patch or input change on a running cluster: --regen (keeps the PKI)."
  log "--force REPLACES the cluster PKI/secrets; only for a cluster that does not exist yet."
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
)
if [ "$REGEN" = 1 ]; then
  # Into a fresh temp dir first, so a failed run leaves the current files as they were.
  REGEN_TMP="$OUT_DIR/.regen-tmp"
  args+=(--with-secrets "$SECRETS" --output-types "controlplane,worker" --output "$REGEN_TMP")
else
  args+=(--output "$OUT_DIR")
fi
[ "$FORCE" = 1 ] && args+=(--force)

# patch_args <flag> <file> — add <file> as a patch only if it has non-comment content.
# talosctl rejects an empty/comment-only patch (it is parsed as JSON6902), so such a file is skipped.
patch_args() {
  local flag="$1" file="$2"
  if [ -n "$file" ] && [ -f "$file" ] && grep -qvE '^[[:space:]]*(#|$)' "$file"; then
    args+=("$flag" "@$file")
  else
    log "note: no patch for $flag (${file:-unset} is empty, comments-only or missing)"
  fi
}

patch_args --config-patch               "$REPO_ROOT/talos/patches/common.yaml"
patch_args --config-patch-control-plane "$REPO_ROOT/talos/patches/controlplane.yaml"
patch_args --config-patch-worker        "$WORKER_PATCH"
patch_args --config-patch-control-plane "$CONTROLPLANE_NETWORK_PATCH"
patch_args --config-patch-worker        "$WORKER_NETWORK_PATCH"
patch_args --config-patch-worker        "$GPU_WORKER_PATCH"

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

if [ "$REGEN" = 1 ]; then
  log "== regen from the existing secrets bundle: $SECRETS (read only) =="
  run rm -rf "$REGEN_TMP"
  run talosctl "${args[@]}"
  backup="$OUT_DIR/backup-$(date -u +%Y%m%dT%H%M%SZ)"
  run mkdir -m 700 "$backup"
  for f in controlplane.yaml worker.yaml; do
    if [ -f "$OUT_DIR/$f" ]; then run cp -p "$OUT_DIR/$f" "$backup/$f"; fi
    run mv -f "$REGEN_TMP/$f" "$OUT_DIR/$f"
  done
  run rmdir "$REGEN_TMP"
  if [ "$DRY" = 0 ]; then
    log
    log "rebuilt controlplane.yaml and worker.yaml with the same PKI; old copies in $backup"
    log "these files embed cluster secrets — gitignored, never commit them."
    log "next: ./scripts/talos/validate.sh, then just talos-upgrade-config <node> (dry run first)"
  fi
  exit 0
fi

run talosctl "${args[@]}"

if [ "$DRY" = 0 ]; then
  log
  log "generated:"
  ls -1 "$OUT_DIR"
  log
  log "these files embed cluster secrets — gitignored, never commit them."
  log "next: ./scripts/talos/validate.sh"
fi
