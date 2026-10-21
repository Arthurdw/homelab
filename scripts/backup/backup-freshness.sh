#!/usr/bin/env bash
# Fail when the last fully successful backup is older than a threshold.
#
# Usage: homelab-backup-freshness
#   Run by homelab-backup-freshness.timer. It sends nothing itself: it exits non-zero when the
#   stamp is stale or missing, and the service's OnFailure= sends the alert (backup-alert.sh),
#   with this script's message in the mailed journal lines. This catches the cases a per-run
#   OnFailure= cannot: a timer that never fires, a host that was off, a disabled unit.
#
# The stamp is written by restic-backup.sh after backup, retention and check all succeeded.
#
# Optional:
#   BACKUP_STAMP_FILE      default: /var/lib/homelab/backup-last-success (epoch seconds)
#   BACKUP_MAX_AGE_HOURS   default: 36
set -euo pipefail

stamp="${BACKUP_STAMP_FILE:-/var/lib/homelab/backup-last-success}"
max_hours="${BACKUP_MAX_AGE_HOURS:-36}"

if [ ! -r "$stamp" ]; then
  echo "STALE: no successful backup recorded ($stamp missing or unreadable)" >&2
  exit 1
fi

last="$(head -n 1 "$stamp")"
case "$last" in
  ''|*[!0-9]*)
    echo "STALE: $stamp does not hold an epoch timestamp" >&2
    exit 1
    ;;
esac

now="$(date +%s)"
age_hours=$(( (now - last) / 3600 ))
last_human="$(date -d "@$last" -Is)"

if [ "$age_hours" -ge "$max_hours" ]; then
  echo "STALE: last successful backup $last_human (${age_hours}h ago, threshold ${max_hours}h)" >&2
  exit 1
fi

echo "ok: last successful backup $last_human (${age_hours}h ago, threshold ${max_hours}h)"
