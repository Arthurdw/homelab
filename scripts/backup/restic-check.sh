#!/usr/bin/env bash
# Verify a restic repository and perform a sample restore.
#
# "A backup is not verified because the job reported success." This reads a subset of pack
# data and optionally restores part of the newest snapshot into a scratch directory (removed on exit).
#
# Required:
#   RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE
# Optional:
#   RESTIC_READ_DATA_SUBSET   default: 5%   (raise periodically; 100% is a full verify)
#   RESTIC_RESTORE_DIR        if set, restore here as a smoke test (deleted afterwards)
#   RESTIC_RESTORE_INCLUDE    path/pattern to restore; set it, else the whole snapshot is restored
#   RESTIC_TAG                tag to select the latest snapshot for restore
set -euo pipefail

: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE}"

log() { printf '%s\n' "$*"; }

if ! command -v restic >/dev/null 2>&1; then
  echo "restic not found in PATH" >&2
  exit 1
fi

SUBSET="${RESTIC_READ_DATA_SUBSET:-5%}"

log "== repository: $RESTIC_REPOSITORY =="
log "== structural check + reading $SUBSET of pack data =="
restic check --read-data-subset="$SUBSET"

if [ -n "${RESTIC_RESTORE_DIR:-}" ]; then
  log "== restore smoke test -> $RESTIC_RESTORE_DIR =="
  mkdir -p "$RESTIC_RESTORE_DIR"
  trap 'rm -rf -- "$RESTIC_RESTORE_DIR"' EXIT
  tag_args=()
  if [ -n "${RESTIC_TAG:-}" ]; then
    tag_args=(--tag "$RESTIC_TAG")
  fi
  inc_args=()
  if [ -n "${RESTIC_RESTORE_INCLUDE:-}" ]; then
    inc_args=(--include "$RESTIC_RESTORE_INCLUDE")
  fi
  restic restore latest "${tag_args[@]+"${tag_args[@]}"}" "${inc_args[@]+"${inc_args[@]}"}" --target "$RESTIC_RESTORE_DIR"
  log "restored files:"
  find "$RESTIC_RESTORE_DIR" -maxdepth 3 -type f | head -20 || true
fi

log "done"
