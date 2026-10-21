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
#   BACKUP_MIN_PERCENT     size-anomaly guard: fail when the new snapshot's source size is under this
#                          percentage of the previous snapshot's (default: 50; 0 disables)
#   BACKUP_STAMP_FILE      success stamp, written only after a fully successful run
#                          (default: /var/lib/homelab/backup-last-success; read by backup-freshness.sh)
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

# Size anomaly: a snapshot far smaller than the previous one means a mount went missing or data was
# deleted. Fail before retention and before the success stamp, so the unit's OnFailure= mails and the
# freshness check trips. The snapshot is kept; the next run compares against it, so this fires once
# per drop. Needs restic >= 0.17 (snapshot summaries); older snapshots are skipped with a note.
min_percent="${BACKUP_MIN_PERCENT:-50}"
if [ "$min_percent" -gt 0 ]; then
  sizes=()
  while IFS= read -r line; do sizes+=("$line"); done < <(
    restic snapshots --tag "$TAG" --json | grep -o '"total_bytes_processed":[0-9]*' | cut -d: -f2 | tail -n 2
  )
  if [ "${#sizes[@]}" -eq 2 ]; then
    prev_size="${sizes[0]}"
    new_size="${sizes[1]}"
    log "source size: $new_size bytes (previous snapshot: $prev_size)"
    if [ $((new_size * 100)) -lt $((prev_size * min_percent)) ]; then
      echo "SIZE ANOMALY: $new_size bytes is under ${min_percent}% of the previous snapshot ($prev_size bytes)" >&2
      exit 1
    fi
  else
    log "size check skipped: fewer than two snapshots with a size summary"
  fi
fi

log "applying retention (daily=${KEEP_DAILY:-7} weekly=${KEEP_WEEKLY:-4} monthly=${KEEP_MONTHLY:-12})"
restic forget --tag "$TAG" \
  --keep-daily "${KEEP_DAILY:-7}" \
  --keep-weekly "${KEEP_WEEKLY:-4}" \
  --keep-monthly "${KEEP_MONTHLY:-12}" \
  --prune

log "verifying repository structure"
restic check

# Only reached when backup, retention and check all succeeded (set -e). Written atomically.
stamp="${BACKUP_STAMP_FILE:-/var/lib/homelab/backup-last-success}"
mkdir -p "$(dirname "$stamp")"
date +%s > "$stamp.tmp"
mv -f "$stamp.tmp" "$stamp"
log "success stamp written: $stamp"

log "done"
