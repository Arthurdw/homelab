#!/usr/bin/env bash
# Offsite backup with restic.
#
# Nothing secret lives in this repo: the repository, password file and paths come from the
# environment (see scripts/backup/env.example). See docs/backup-policy.md.
#
# Required:
#   RESTIC_REPOSITORY      e.g. sftp:backup@host:/srv/restic/homelab
#   RESTIC_PASSWORD_FILE   path to the repo password file (outside the repo)
#   BACKUP_PATHS           space-separated absolute paths to back up
#
# Optional:
#   RESTIC_TAG             tag for this dataset (default: homelab)
#   RESTIC_EXCLUDE_FILE    restic exclude file
#   KEEP_DAILY/WEEKLY/MONTHLY  retention (defaults: 7/4/12)
set -euo pipefail

: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE}"
: "${BACKUP_PATHS:?set BACKUP_PATHS (space-separated paths)}"

TAG="${RESTIC_TAG:-homelab}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

if ! command -v restic >/dev/null 2>&1; then
  echo "restic not found in PATH" >&2
  exit 1
fi

if [ ! -r "$RESTIC_PASSWORD_FILE" ]; then
  echo "RESTIC_PASSWORD_FILE not readable: $RESTIC_PASSWORD_FILE" >&2
  exit 1
fi

read -r -a paths <<< "$BACKUP_PATHS"

exclude_args=()
if [ -n "${RESTIC_EXCLUDE_FILE:-}" ]; then
  exclude_args+=(--exclude-file "$RESTIC_EXCLUDE_FILE")
fi

log "repository: $RESTIC_REPOSITORY"
log "checking repository reachable"
restic snapshots >/dev/null

log "backing up: ${paths[*]}"
restic backup --tag "$TAG" "${exclude_args[@]+"${exclude_args[@]}"}" "${paths[@]}"

log "applying retention (daily=${KEEP_DAILY:-7} weekly=${KEEP_WEEKLY:-4} monthly=${KEEP_MONTHLY:-12})"
restic forget --tag "$TAG" \
  --keep-daily "${KEEP_DAILY:-7}" \
  --keep-weekly "${KEEP_WEEKLY:-4}" \
  --keep-monthly "${KEEP_MONTHLY:-12}" \
  --prune

log "verifying repository structure"
restic check

log "done"
