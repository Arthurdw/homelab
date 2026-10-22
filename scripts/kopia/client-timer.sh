#!/usr/bin/env bash
# Install the daily Kopia snapshot as a systemd user timer on a Linux client (docs/runbooks/household-backups.md (b)).
#
# Copies scripts/kopia/systemd/kopia-snapshot.{service,timer} into ~/.config/systemd/user with the local kopia
# path filled in, then enables the timer. The service runs `kopia snapshot create --all` as you, so the client
# must already be connected (`kopia repository connect server ...`) with its password saved. Needs no root.
#
# Usage:
#   ./scripts/kopia/client-timer.sh [--run-now | --status | --uninstall]
# --run-now   install (if needed), then start one snapshot now and follow its log.
# --status    show the timer, the last run and the snapshots of this user@host.
# --uninstall disable the timer and remove both units. Snapshots stay in the repository.
set -euo pipefail

MODE=install

usage() { sed -n '2,12p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-now)   MODE=run-now; shift ;;
    --status)    MODE=status; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

SRC="$(cd "$(dirname "$0")/systemd" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNITS=(kopia-snapshot.service kopia-snapshot.timer)

for tool in kopia systemctl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found in PATH" >&2; exit 1; }
done

case "$MODE" in
  uninstall)
    systemctl --user disable --now kopia-snapshot.timer 2>/dev/null || true
    for u in "${UNITS[@]}"; do rm -f "$DEST/$u"; done
    systemctl --user daemon-reload
    echo "removed the kopia-snapshot timer and service"
    exit 0
    ;;
  status)
    systemctl --user list-timers kopia-snapshot.timer --all --no-pager
    systemctl --user status kopia-snapshot.service --no-pager --lines=10 || true
    kopia snapshot list --all
    exit 0
    ;;
esac

# Fail early instead of at 00:00: the unit can't answer a password prompt.
if ! kopia repository status >/dev/null 2>&1; then
  echo "kopia is not connected (or can't open the repository without a prompt):" >&2
  echo "  kopia repository connect server --url https://kopia.lab.ardw.be:443 --override-username <user> --override-hostname <machine>" >&2
  exit 1
fi

KOPIA="$(command -v kopia)"
mkdir -p "$DEST"
sed "s|@KOPIA@|$KOPIA|" "$SRC/kopia-snapshot.service" >"$DEST/kopia-snapshot.service"
cp "$SRC/kopia-snapshot.timer" "$DEST/kopia-snapshot.timer"
systemctl --user daemon-reload
systemctl --user enable --now kopia-snapshot.timer
systemctl --user list-timers kopia-snapshot.timer --no-pager

if [ "$MODE" = run-now ]; then
  echo "starting a snapshot now (the first one uploads everything and takes a while)"
  journalctl --user -u kopia-snapshot.service -f -n 0 &
  jpid=$!
  trap 'kill "$jpid" 2>/dev/null || true' EXIT
  # A oneshot's start blocks until the snapshot finishes and fails if it does.
  systemctl --user start kopia-snapshot.service || { echo "snapshot failed" >&2; exit 1; }
  echo "snapshot done"
fi
