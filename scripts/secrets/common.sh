#!/usr/bin/env bash
# Shared helpers for the scripts/secrets/* tools. This file is *sourced*, not executed.
# shellcheck shell=bash
#
# See docs/runbooks/secrets.md and docs/secrets-and-state.md.

# Repo-relative paths (this file lives at scripts/secrets/common.sh).
SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT is provided for the scripts that source this file.
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$SECRETS_DIR/../.." && pwd)"

# The lab age key lives OUTSIDE the repo (never committed). Override with LAB_AGE_KEY.
LAB_AGE_KEY="${LAB_AGE_KEY:-$HOME/.config/homelab/lab-age.key}"

log()  { printf '%s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
# Diagnostics that must not contaminate stdout (e.g. decrypt.sh output).
info() { printf '   %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# require <tool>... — fail fast when a required command is missing.
require() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t (install: just lab-tools)"
  done
}

# Point sops at an age identity without hard-coding it into every command.
# An explicit SOPS_AGE_KEY_FILE always wins (this is how production is wired).
# Otherwise the lab key is used when present, for convenience on the lab host.
# No key is ever read from inside the repository.
use_age_key() {
  if [ -n "${SOPS_AGE_KEY_FILE:-}" ]; then
    [ -r "$SOPS_AGE_KEY_FILE" ] || die "SOPS_AGE_KEY_FILE is not readable: $SOPS_AGE_KEY_FILE"
    info "age identity: $SOPS_AGE_KEY_FILE (from SOPS_AGE_KEY_FILE)"
    return 0
  fi
  if [ -r "$LAB_AGE_KEY" ]; then
    export SOPS_AGE_KEY_FILE="$LAB_AGE_KEY"
    info "age identity: $LAB_AGE_KEY (lab key)"
  fi
}

# True when sops reports the file as encrypted (a SOPS `mac`/`sops` envelope).
is_sops_encrypted() {
  local f="$1" status
  status="$(sops filestatus -- "$f" 2>/dev/null)" || return 2
  case "$status" in
    *'"encrypted":true'*|*'"encrypted": true'*) return 0 ;;
    *) return 1 ;;
  esac
}

# The canonical SOPS *config* files, not encrypted payloads. Excluded from scans.
is_sops_config_file() {
  case "$(basename -- "$1")" in
    .sops.yaml|.sops.yml|.sops.json) return 0 ;;
    *) return 1 ;;
  esac
}
