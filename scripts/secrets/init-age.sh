#!/usr/bin/env bash
# init-age.sh — key ceremony helper: create an age identity used by SOPS.
#
# Idempotent: if the key already exists it is left untouched and its PUBLIC
# recipient is printed (safe to share/commit). It never overwrites unless
# --force is given, and it REFUSES to write inside the repository.
#
# Lab (default):
#   scripts/secrets/init-age.sh                 # -> ~/.config/homelab/lab-age.key
#
# Production ceremony (run this OFFLINE, then set the public recipient in
# .sops.yaml — see docs/runbooks/secrets.md):
#   scripts/secrets/init-age.sh --output /media/offline/prod-age.key --purpose production
#
# Options:
#   -o, --output FILE    key file to create (default: ~/.config/homelab/lab-age.key)
#       --purpose NAME   label for messages: lab (default) or production
#   -f, --force          overwrite an existing key (DANGEROUS: old ciphertext becomes unreadable)
#   -n, --dry-run        print what would happen; change nothing
#   -h, --help           show this help
set -euo pipefail

SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SECRETS_DIR/../.." && pwd)"
# shellcheck source=scripts/secrets/common.sh
. "$SECRETS_DIR/common.sh"

OUTPUT="$LAB_AGE_KEY"
PURPOSE="lab"
FORCE=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUTPUT="$2"; shift 2 ;;
    --purpose)   PURPOSE="$2"; shift 2 ;;
    -f|--force)  FORCE=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

require age-keygen age

# Absolute path without requiring the file to exist yet.
OUTPUT_ABS="$(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd || printf '%s' "$(dirname "$OUTPUT")")/$(basename "$OUTPUT")"

# Never write a private key inside the repository — even by accident.
case "$OUTPUT_ABS" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) die "refusing to write a private key inside the repo: $OUTPUT_ABS" ;;
esac

if [ "$PURPOSE" = "production" ]; then
  warn "production key ceremony: this host should be OFFLINE/air-gapped."
  warn "escrow the private key in a password manager AND on separate offline media."
fi

if [ -e "$OUTPUT" ] && [ "$FORCE" -ne 1 ]; then
  log "key already exists: $OUTPUT (leaving it untouched)"
  note "public recipient: $(age-keygen -y "$OUTPUT")"
  exit 0
fi

if [ "$DRY" -eq 1 ]; then
  log "[dry-run] would create age key: $OUTPUT (purpose: $PURPOSE)"
  log "[dry-run] would extract + print the public recipient"
  exit 0
fi

if [ -e "$OUTPUT" ]; then
  warn "--force: replacing $OUTPUT — ciphertext encrypted to the old key becomes UNREADABLE."
fi

mkdir -p "$(dirname "$OUTPUT")"
chmod 700 "$(dirname "$OUTPUT")" 2>/dev/null || true
umask 077
age-keygen -o "$OUTPUT"
chmod 600 "$OUTPUT"

log "created age key: $OUTPUT (mode 600, purpose: $PURPOSE)"
note "public recipient: $(age-keygen -y "$OUTPUT")"
if [ "$PURPOSE" = "lab" ]; then
  note "the lab recipient belongs in .sops.yaml (lab creation rule); see docs/runbooks/secrets.md"
else
  note "put ONLY the public recipient in .sops.yaml; keep the private key where it is."
fi
