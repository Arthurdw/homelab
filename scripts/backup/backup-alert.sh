#!/usr/bin/env bash
# Email an alert about a failed systemd unit over SMTP (docs/decisions.md §5.1).
#
# Usage: homelab-backup-alert <unit>
#   Normally started by homelab-backup-alert@<unit>.service, which the backup units name in
#   OnFailure=. The mail carries the unit name, host, timestamp and the unit's last journal lines.
#
# Nothing secret lives in this repo or on the command line: settings come from the environment
# (see scripts/backup/alert.env.example, installed as /etc/homelab/alert.env, mode 0600) and the
# SMTP login comes from a netrc file that curl reads itself (--netrc-file), never from argv.
#
# Required:
#   ALERT_SMTP_URL     smtps://host:465 (implicit TLS) or smtp://host:587 (STARTTLS; TLS is enforced)
#   ALERT_MAIL_FROM    envelope + header sender
#   ALERT_MAIL_TO      space-separated recipients
#
# Optional:
#   ALERT_NETRC_FILE   netrc with "machine <host> login <user> password <pass>"
#                      (default: /etc/homelab/alert.netrc; omit the file for an unauthenticated relay)
#   ALERT_JOURNAL_LINES  journal lines to include (default: 50)
#   ALERT_SUBJECT_PREFIX  default: [homelab]
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $(basename "$0") <unit>" >&2
  exit 2
fi
unit="$1"

: "${ALERT_SMTP_URL:?set ALERT_SMTP_URL}"
: "${ALERT_MAIL_FROM:?set ALERT_MAIL_FROM}"
: "${ALERT_MAIL_TO:?set ALERT_MAIL_TO (space-separated)}"

netrc="${ALERT_NETRC_FILE:-/etc/homelab/alert.netrc}"
lines="${ALERT_JOURNAL_LINES:-50}"
prefix="${ALERT_SUBJECT_PREFIX:-[homelab]}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found in PATH" >&2
  exit 1
fi

host="$(hostname -f 2>/dev/null || hostname)"
now="$(date -Is)"
read -r -a rcpts <<< "$ALERT_MAIL_TO"

msg="$(mktemp)"
trap 'rm -f -- "$msg"' EXIT

{
  printf 'From: %s\n' "$ALERT_MAIL_FROM"
  # RFC 5322 address lists are comma-separated; ALERT_MAIL_TO is space-separated.
  (IFS=,; printf 'To: %s\n' "${rcpts[*]}" | sed 's/,/, /g')
  printf 'Subject: %s %s failed on %s\n' "$prefix" "$unit" "$host"
  printf 'Date: %s\n' "$(date -R)"
  printf 'MIME-Version: 1.0\n'
  printf 'Content-Type: text/plain; charset=utf-8\n'
  printf '\n'
  printf 'Unit:      %s\n' "$unit"
  printf 'Host:      %s\n' "$host"
  printf 'Timestamp: %s\n' "$now"
  printf '\nLast %s journal lines (journalctl -u %s):\n\n' "$lines" "$unit"
  journalctl -u "$unit" -n "$lines" --no-pager -o short-iso 2>&1 || echo "(journalctl failed)"
} > "$msg"   # LF only; curl --crlf converts to the CRLF SMTP requires

rcpt_args=()
for r in "${rcpts[@]}"; do
  rcpt_args+=(--mail-rcpt "$r")
done

netrc_args=()
if [ -r "$netrc" ]; then
  netrc_args=(--netrc-file "$netrc")
fi

curl --silent --show-error --fail --ssl-reqd \
  --crlf \
  --url "$ALERT_SMTP_URL" \
  "${netrc_args[@]+"${netrc_args[@]}"}" \
  --mail-from "$ALERT_MAIL_FROM" \
  "${rcpt_args[@]}" \
  --upload-file "$msg"

echo "alert for $unit sent to ${rcpts[*]}"
