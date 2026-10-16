#!/usr/bin/env bash
# check.sh — CI gate for SOPS secrets.
#
# Fails when any file that could be committed and *looks* like a SOPS secret
# (`*.sops.yaml` / `*.sops.yml` / `*.sops.json`) is NOT actually encrypted, or
# when such a file would be gitignored (i.e. its ciphertext could not be tracked,
# or worse, a plaintext copy is hidden from review).
#
# It is static: it needs no private key, so it runs in CI (L0).
#
# Usage:
#   scripts/secrets/check.sh [--check] [--root DIR]
#
#   --check   CI mode: quiet, exit non-zero on any failure (this is what CI calls).
#   --root    scan a different tree (default: this repository).
set -euo pipefail

SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SECRETS_DIR/../.." && pwd)"
# shellcheck source=scripts/secrets/common.sh
. "$SECRETS_DIR/common.sh"

CHECK=0
ROOT="$REPO_ROOT"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --root)  ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -d "$ROOT" ] || die "not a directory: $ROOT"

fails=0
ok=0
declare -a problems=()

# In --check (CI) mode, suppress the per-file success chatter.
say_ok() { [ "$CHECK" -eq 1 ] || log "ok: $*"; }

fail() {
  fails=$((fails + 1))
  problems+=("$1")
  log "FAIL: $1"
}

# --- 1. the config itself must exist, in-repo -------------------------------
if [ -f "$ROOT/.sops.yaml" ]; then
  say_ok ".sops.yaml present"
else
  fail ".sops.yaml is missing (SOPS cannot encrypt without creation rules)"
fi

# --- 2. every would-be-committed secret file must be encrypted --------------
# use git so the set matches exactly what review/commit would see
mapfile -t candidates < <(
  git -C "$ROOT" ls-files --cached --others --exclude-standard -- \
    '*.sops.yaml' '*.sops.yml' '*.sops.json' 2>/dev/null | sort -u
)

for rel in "${candidates[@]}"; do
  f="$ROOT/$rel"
  if is_sops_config_file "$rel"; then
    continue
  fi
  if is_sops_encrypted "$f"; then
    say_ok "encrypted: $rel"
    ok=$((ok + 1))
  else
    fail "not encrypted (plaintext secret?): $rel"
  fi
done

# --- 3. ciphertext must be committable (not accidentally gitignored) ---------
# `git ls-files` above silently drops ignored files; find them and complain.
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  case "$rel" in docs/private/*) continue ;; esac
  if git -C "$ROOT" check-ignore -q -- "$rel" 2>/dev/null; then
    fail "gitignored secret file (ciphertext could not be committed): $rel"
  fi
done < <(find "$ROOT" -type f \( -name '*.sops.yaml' -o -name '*.sops.yml' -o -name '*.sops.json' \) \
  -not -path '*/.git/*' 2>/dev/null)

# --- 4. advisory: is the production recipient still a placeholder? ----------
if [ -f "$ROOT/.sops.yaml" ] && grep -q 'REPLACE_AT_GATE_4_WITH_PRODUCTION_AGE_RECIPIENT' "$ROOT/.sops.yaml"; then
  warn "production recipient is still the GATE 4 placeholder — production secrets cannot be encrypted yet (by design)"
fi

log ""
if [ "$fails" -eq 0 ]; then
  log "SOPS check passed: ${ok} encrypted file(s), 0 problems."
  exit 0
fi
log "SOPS check FAILED: ${fails} problem(s)."
for p in "${problems[@]}"; do log "  - $p"; done
exit 1
