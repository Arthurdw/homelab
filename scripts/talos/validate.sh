#!/usr/bin/env bash
# Validate generated Talos machine configs with `talosctl validate --mode metal`.
#
# Offline and static: reads the generated files only, contacts nothing. Safe to run anytime.
#
#   ./scripts/talos/validate.sh                 # validate TALOS_OUT_DIR (default talos/out)
#   TALOS_OUT_DIR=/tmp/opencode/talos ./scripts/talos/validate.sh
#   ./scripts/talos/validate.sh --strict        # treat validation warnings as errors
#
# Exits non-zero if no config is found or any config is invalid.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INPUTS="${TALOS_INPUTS:-$REPO_ROOT/talos/inputs.env}"

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Reuse TALOS_OUT_DIR from the inputs file when present; it is only a path, never a secret.
if [ -f "$INPUTS" ]; then
  # shellcheck source=/dev/null
  . "$INPUTS"
fi
OUT_DIR="${TALOS_OUT_DIR:-$REPO_ROOT/talos/out}"
case "$OUT_DIR" in
  /*) : ;;                                    # already absolute
  *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;;
esac

if ! command -v talosctl >/dev/null 2>&1; then
  echo "talosctl not found in PATH (expected ~/.local/bin — see docs/lab.md)" >&2
  exit 1
fi

if [ ! -d "$OUT_DIR" ]; then
  echo "no generated configs at $OUT_DIR — run ./scripts/talos/gen-configs.sh first" >&2
  exit 1
fi

configs=()
# worker-<node>.yaml: the per-node worker configs that production applies (gen-configs.sh).
shopt -s nullglob
for cfg in "$OUT_DIR"/controlplane.yaml "$OUT_DIR"/worker.yaml "$OUT_DIR"/worker-*.yaml; do
  configs+=("$cfg")
done
shopt -u nullglob

if [ "${#configs[@]}" -eq 0 ]; then
  echo "no controlplane.yaml/worker*.yaml under $OUT_DIR — run ./scripts/talos/gen-configs.sh first" >&2
  exit 1
fi

status=0
for cfg in "${configs[@]}"; do
  printf '== validate %s ==\n' "$cfg"
  if [ "$STRICT" = 1 ]; then
    talosctl validate --mode metal --strict --config "$cfg" || status=1
  else
    talosctl validate --mode metal --config "$cfg" || status=1
  fi
done

exit "$status"
