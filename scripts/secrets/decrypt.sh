#!/usr/bin/env bash
# decrypt.sh — decrypt a sops file and print it to stdout.
#
# SAFETY: plaintext is written to stdout only. There is deliberately no
# "decrypt in place" mode — decrypted secrets must never land in a tracked file.
# Redirect to a path OUTSIDE the repo (or pipe into a consumer) yourself.
#
# Usage:
#   scripts/secrets/decrypt.sh FILE                 # whole document
#   scripts/secrets/decrypt.sh --extract '["k"]' FILE   # one value (sops --extract)
#
# Uses the age identity from $SOPS_AGE_KEY_FILE, else the lab key at
# ~/.config/homelab/lab-age.key when present.
set -euo pipefail

SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SECRETS_DIR/../.." && pwd)"
# shellcheck source=scripts/secrets/common.sh
. "$SECRETS_DIR/common.sh"

CONFIG="$REPO_ROOT/.sops.yaml"
EXTRACT=""
FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config)  CONFIG="$2"; shift 2 ;;
    -e|--extract) EXTRACT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
    --) shift; FILE="$1"; shift ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  FILE="$1"; shift ;;
  esac
done

require sops
[ -n "$FILE" ] || die "no file given (see --help)"
[ -f "$FILE" ] || die "no such file: $FILE"
use_age_key

args=(-d --config "$CONFIG")
[ -n "$EXTRACT" ] && args+=(--extract "$EXTRACT")

sops "${args[@]}" -- "$FILE"
