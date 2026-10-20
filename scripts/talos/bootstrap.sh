#!/usr/bin/env bash
# Bootstrap the Talos control plane (`talosctl bootstrap`).
#
# !! LIVE OPERATION. Read docs/runbooks/talos-bootstrap.md first. This talks to a
# !! real node, creates etcd and CANNOT be undone in place. It is deliberately hard to run by accident:
# !!   * the control-plane node must be named explicitly (no default, no "the only node");
# !!   * `--confirm` must be passed or TALOS_BOOTSTRAP_CONFIRM=1 set.
#
# Usage:
#   ./scripts/talos/bootstrap.sh --node <control-plane-ip> [--talosconfig <path>] --confirm
#   ./scripts/talos/bootstrap.sh --node <control-plane-ip> --dry-run   # print only, no contact
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INPUTS="${TALOS_INPUTS:-$REPO_ROOT/talos/inputs.env}"

NODE=""
TALOSCONFIG=""
DRY=0
CONFIRM="${TALOS_BOOTSTRAP_CONFIRM:-0}"

usage() { sed -n '2,15p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --node)       NODE="${2:-}"; shift 2 ;;
    --talosconfig) TALOSCONFIG="${2:-}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --confirm)    CONFIRM=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -f "$INPUTS" ]; then
  # shellcheck source=/dev/null
  . "$INPUTS"
fi
OUT_DIR="${TALOS_OUT_DIR:-$REPO_ROOT/talos/out}"
case "$OUT_DIR" in
  /*) : ;;
  *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;;
esac
TALOSCONFIG="${TALOSCONFIG:-$OUT_DIR/talosconfig}"

if [ -z "$NODE" ]; then
  echo "refused: --node <control-plane-ip> is required (TODO(GATE 4): the CP address is set at cutover)" >&2
  exit 2
fi
if [ ! -f "$TALOSCONFIG" ]; then
  echo "talosconfig not found: $TALOSCONFIG (run ./scripts/talos/gen-configs.sh first)" >&2
  exit 1
fi
if ! command -v talosctl >/dev/null 2>&1; then
  echo "talosctl not found in PATH (expected ~/.local/bin — see docs/lab.md)" >&2
  exit 1
fi

cmd=(talosctl --talosconfig "$TALOSCONFIG" bootstrap --nodes "$NODE")

if [ "$DRY" = 1 ]; then
  printf '  [dry-run] %s\n' "${cmd[*]}"
  exit 0
fi

if [ "$CONFIRM" != 1 ]; then
  echo "refused: this creates etcd on $NODE and cannot be undone in place." >&2
  echo "re-read docs/runbooks/talos-bootstrap.md, then pass --confirm." >&2
  echo "command that would run:" >&2
  printf '  %s\n' "${cmd[*]}" >&2
  exit 3
fi

printf '== bootstrapping %s (confirmed) ==\n' "$NODE"
"${cmd[@]}"
