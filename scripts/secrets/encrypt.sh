#!/usr/bin/env bash
# encrypt.sh — encrypt plaintext secret files IN PLACE with sops (see .sops.yaml).
#
# Encrypting needs only the PUBLIC recipient from .sops.yaml, never a private key,
# so this is safe to run anywhere (including CI where no key exists).
# Idempotent: a file that is already encrypted is skipped.
#
# Usage:
#   scripts/secrets/encrypt.sh [--dry-run] FILE...
#
# The file name must match a creation rule in .sops.yaml (e.g. *.sops.yaml, or
# *.lab.sops.yaml for the lab key). sops fails closed if no rule matches.
set -euo pipefail

SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SECRETS_DIR/../.." && pwd)"
# shellcheck source=scripts/secrets/common.sh
. "$SECRETS_DIR/common.sh"

DRY=0
CONFIG="$REPO_ROOT/.sops.yaml"
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    -c|--config)  CONFIG="$2"; shift 2 ;;
    -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
    --) shift; FILES+=("$@"); break ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)  FILES+=("$1"); shift ;;
  esac
done

require sops
[ "${#FILES[@]}" -gt 0 ] || die "no files given (see --help)"
[ -f "$CONFIG" ] || die "sops config not found: $CONFIG"

rc=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { warn "not a file, skipping: $f"; rc=1; continue; }

  if is_sops_encrypted "$f"; then
    log "already encrypted, skipping: $f"
    continue
  fi

  if [ "$DRY" -eq 1 ]; then
    log "[dry-run] sops -e -i --config $CONFIG $f"
    continue
  fi

  if sops -e -i --config "$CONFIG" -- "$f"; then
    if is_sops_encrypted "$f"; then
      log "encrypted: $f"
    else
      warn "sops reported success but $f is not encrypted"
      rc=1
    fi
  else
    warn "failed to encrypt: $f (does its name match a creation rule in .sops.yaml?)"
    rc=1
  fi
done

exit "$rc"
