#!/usr/bin/env bash
# Non-destructive restore test: restore the newest snapshot into a scratch directory and diff it
# against the live source paths.
#
# restic-check.sh proves the repository is readable; this proves the restored bytes equal the source.
# Nothing outside the scratch directory is written, and the scratch directory is removed on exit.
# On a live dataset, files changed since the snapshot are reported as differences: run it right after
# a backup, or against a quiet dataset.
#
# Required:
#   RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, BACKUP_PATHS   (as for restic-backup.sh)
# Optional:
#   RESTIC_TAG        tag selecting the snapshot (default: homelab)
#   RESTORE_SCRATCH   parent directory for the scratch restore (default: system temp dir)
set -euo pipefail

: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE}"
: "${BACKUP_PATHS:?set BACKUP_PATHS (space-separated paths)}"

log() { printf '%s\n' "$*"; }

if ! command -v restic >/dev/null 2>&1; then
  echo "restic not found in PATH" >&2
  exit 1
fi

target="$(mktemp -d "${RESTORE_SCRATCH:-${TMPDIR:-/tmp}}/restic-restore-diff.XXXXXX")"
trap 'rm -rf -- "$target"' EXIT

log "== restoring latest snapshot (tag ${RESTIC_TAG:-homelab}) -> $target =="
restic restore latest --tag "${RESTIC_TAG:-homelab}" --target "$target"

read -r -a paths <<< "$BACKUP_PATHS"
status=0
for p in "${paths[@]}"; do
  log "== diff $p =="
  if diff -r "$p" "$target$p"; then
    log "identical"
  else
    status=1
  fi
done

[ "$status" -eq 0 ] && log "OK: restored snapshot matches the source" || echo "FAIL: restored snapshot differs from the source" >&2
exit "$status"
