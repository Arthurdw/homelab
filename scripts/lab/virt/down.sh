#!/usr/bin/env bash
# Tear down the libvirt lab harness.
#
# Removes ONLY what this harness created:
#   * the domains named in guests.tsv (every one of which must start with 'lab-'),
#   * the two lab networks (homelab-lab, homelab-lab-storage),
#   * the isolation nwfilter (homelab-lab-isolate),
#   * the disks/seed ISOs this harness wrote into LAB_VIRT_DIR.
#
# This machine has other libvirt guests: any domain whose name is not in guests.tsv is listed and
# left alone. There is no "delete everything" path.
#
# Usage:
#   scripts/lab/virt/down.sh --dry-run
#   scripts/lab/virt/down.sh --only lab-talos-cp
#   scripts/lab/virt/down.sh --purge          # also delete the downloaded images
#
# Env: LAB_VIRT_DIR, LIBVIRT_URI
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,18p' "$0"; }

ONLY=""
PURGE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --only)    ONLY="${ONLY:+$ONLY,}${2:-}"; shift 2 ;;
    --purge)   PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_cmd virsh
load_guests
if [ -n "$ONLY" ]; then select_only "$ONLY"; else select_all; fi

if [ "$DRY" = 1 ]; then check_libvirt soft; else check_libvirt hard || exit 1; fi

log "name filter"
note "eligible: the exact names in $GUESTS_TABLE"
note "guard:    each must match '${LAB_DOMAIN_PREFIX}*' — anything else is refused, never deleted"
note "NOT touched: every other libvirt domain, every other network, the 'default' network"

if [ "$DRY" != 1 ] && libvirt_ready; then
  others=""
  while read -r d; do
    [ -n "$d" ] || continue
    keep=1
    while read -r i; do
      if [ "${GUEST_NAMES[$i]}" = "$d" ]; then keep=0; fi
    done < <(selected_indexes)
    if [ "$keep" = 1 ]; then others+=" $d"; fi
  done < <(virsh_q list --all --name)
  if [ -n "$others" ]; then
    note "left alone:$others"
  else
    note "left alone: (no other domains are defined)"
  fi
fi

log "domains"
while read -r i; do
  name="${GUEST_NAMES[$i]}"
  if ! is_lab_domain "$name"; then
    warn "refusing '$name' (does not match '${LAB_DOMAIN_PREFIX}*')"
    continue
  fi
  if [ "$DRY" != 1 ] && ! domain_exists "$name"; then
    note "$name: not defined"
  else
    if domain_running "$name"; then
      run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" destroy "$name"
    fi
    run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" undefine "$name"
  fi
  run rm -f "$(guest_disk_path "$name")" "$(guest_seed_iso_path "$name")"
done < <(selected_indexes)

# Shared resources go only when every guest is being removed; --only keeps the others running.
if [ -n "$ONLY" ]; then
  log "networks / isolation filter"
  note "--only given: networks and filter kept (shared with the other guests)"
else
log "networks"
for net in "$NET_LAB" "$NET_STORAGE"; do
  if [ "$DRY" != 1 ] && ! network_exists "$net"; then
    note "$net: not defined"
    continue
  fi
  if network_active "$net"; then
    run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-destroy "$net"
  fi
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-undefine "$net"
done

log "isolation filter"
if [ "$DRY" != 1 ] && ! nwfilter_exists "$NWFILTER_NAME"; then
  note "$NWFILTER_NAME: not defined"
else
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" nwfilter-undefine "$NWFILTER_NAME"
fi
fi

log "files"
case "$LAB_VIRT_DIR" in
  ""|/|/var|/var/tmp|"$HOME") echo "refusing unsafe LAB_VIRT_DIR='$LAB_VIRT_DIR'" >&2; exit 1 ;;
esac
if [ "$PURGE" = 1 ] && [ -n "$ONLY" ]; then
  warn "--purge ignored with --only"; PURGE=0
fi
if [ "$PURGE" = 1 ]; then
  run rm -rf "$LAB_VIRT_DIR/images" "$LAB_VIRT_DIR/xml" "$LAB_VIRT_DIR/seed"
else
  note "images kept in $LAB_VIRT_DIR/images (use --purge to delete them)"
fi

if [ "$DRY" = 1 ]; then
  log "dry-run complete — nothing was removed"
  exit 0
fi

log "lab virt down"
"$VIRSH_BIN" -c "$LIBVIRT_URI" list --all
"$VIRSH_BIN" -c "$LIBVIRT_URI" net-list --all
