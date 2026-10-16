#!/usr/bin/env bash
# verify.sh — prove the SOPS + age pipeline end to end, in a throwaway temp dir.
#
# Encrypts fake secrets with the REAL .sops.yaml rules, then checks that:
#   1. sops reports the file as encrypted, and the plaintext is gone from it;
#   2. `sops -d` reproduces a flat document byte-for-byte;
#   3. `sops -d --extract` reads fields out of a nested document, proving the
#      structure survived the round-trip;
#   4. a production-named file FAILS CLOSED while the GATE 4 placeholder is unset.
#
# (SOPS re-indents nested YAML, so the byte-for-byte check uses a flat document;
#  nesting is proven separately via --extract.)
#
# Nothing is written inside the repository; the temp dir is removed on exit.
# Requires a private age identity ($SOPS_AGE_KEY_FILE, else the lab key).
#
# Usage: scripts/secrets/verify.sh
set -euo pipefail

SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SECRETS_DIR/../.." && pwd)"
# shellcheck source=scripts/secrets/common.sh
. "$SECRETS_DIR/common.sh"

require sops
use_age_key
[ -n "${SOPS_AGE_KEY_FILE:-}" ] || die "no age identity (set SOPS_AGE_KEY_FILE; see docs/runbooks/secrets.md)"

CONFIG="$REPO_ROOT/.sops.yaml"
[ -f "$CONFIG" ] || die "missing $CONFIG"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { log "PASS: $*"; pass=$((pass + 1)); }
bad() { log "FAIL: $*"; fail=$((fail + 1)); }

FLAT_PLAIN="$TMP/flat.plain.yaml"
FLAT_ENC="$TMP/roundtrip.lab.sops.yaml"   # matches the LAB creation rule
NEST_ENC="$TMP/structure.lab.sops.yaml"   # matches the LAB creation rule
PROD_ENC="$TMP/verify.sops.yaml"          # matches the PRODUCTION rule

cat > "$FLAT_PLAIN" <<'YAML'
username: lab-admin
password: correct-horse-battery-staple
YAML

cat > "$NEST_ENC" <<'YAML'
nested:
  token: abc123
  port: 8443
list:
  - one
  - two
YAML

log "== verify: encrypt (flat round-trip doc) =="
cp "$FLAT_PLAIN" "$FLAT_ENC"
if sops -e -i --config "$CONFIG" "$FLAT_ENC" && grep -q 'ENC\[' "$FLAT_ENC"; then
  ok "sops -e produced a SOPS envelope"
else
  bad "sops -e did not produce ciphertext"
fi

log "== verify: ciphertext is opaque =="
if grep -q 'correct-horse-battery-staple' "$FLAT_ENC"; then
  bad "plaintext secret is visible in the ciphertext"
else
  ok "plaintext secret absent from ciphertext"
fi
if [ "$(sops filestatus "$FLAT_ENC")" = '{"encrypted":true}' ]; then
  ok "sops filestatus reports encrypted"
else
  bad "sops filestatus did not report encrypted"
fi

log "== verify: decrypt round-trip =="
if sops -d --config "$CONFIG" "$FLAT_ENC" > "$TMP/flat.dec.yaml" 2>/dev/null \
  && diff -u "$FLAT_PLAIN" "$TMP/flat.dec.yaml" >/dev/null; then
  ok "sops -d reproduced the original byte-for-byte"
else
  bad "sops -d output differs from the original"
fi

log "== verify: structural extract (nested doc) =="
if sops -e -i --config "$CONFIG" "$NEST_ENC" 2>/dev/null; then
  tok="$(sops -d --config "$CONFIG" --extract '["nested"]["token"]' "$NEST_ENC" 2>/dev/null || true)"
  item="$(sops -d --config "$CONFIG" --extract '["list"][1]' "$NEST_ENC" 2>/dev/null || true)"
  if [ "$tok" = "abc123" ] && [ "$item" = "two" ]; then
    ok "sops -d --extract read nested.token and list[1] correctly"
  else
    bad "sops -d --extract returned token='${tok}' list[1]='${item}' (want 'abc123' / 'two')"
  fi
else
  bad "could not encrypt the nested test document"
fi

log "== verify: production fails closed (placeholder) =="
printf 'prod: secret\n' > "$PROD_ENC"
if sops -e -i --config "$CONFIG" "$PROD_ENC" >/dev/null 2>&1; then
  if grep -q 'REPLACE_AT_GATE_4_WITH_PRODUCTION_AGE_RECIPIENT' "$CONFIG"; then
    bad "production secret encrypted to a placeholder recipient"
  else
    ok "production rule has a real recipient (GATE 4 filled)"
  fi
elif grep -q 'REPLACE_AT_GATE_4_WITH_PRODUCTION_AGE_RECIPIENT' "$CONFIG"; then
  ok "production encryption correctly fails while the GATE 4 placeholder is set"
else
  bad "production encryption failed although the placeholder is gone"
fi

log ""
log "verify: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
