#!/usr/bin/env bash
# Show the state of the libvirt lab: networks, guests, DHCP leases, Talos and the NAS services.
# Read-only: it changes nothing. See docs/lab.md ('libvirt guests').
#
# Usage:
#   scripts/lab/virt/status.sh
#   scripts/lab/virt/status.sh --dry-run     # print the queries without running them
#
# Env: LIBVIRT_URI, TALOS_LAB_OUT
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,11p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_cmd virsh
load_guests
select_all

log "libvirt"
note "URI: $LIBVIRT_URI"
if [ "$DRY" = 1 ]; then
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" list --all
  run timeout "$VIRSH_TIMEOUT" "$VIRSH_BIN" -c "$LIBVIRT_URI" net-list --all
  exit 0
fi
if ! check_libvirt hard; then exit 1; fi

log "networks"
"$VIRSH_BIN" -c "$LIBVIRT_URI" net-list --all
for net in "$NET_LAB" "$NET_STORAGE"; do
  if network_exists "$net"; then
    note "$net: active=$(virsh_q net-info "$net" | awk '/^Active:/{print $2}')"
    if network_active "$net"; then
      virsh_q net-dhcp-leases "$net" || true
    fi
  else
    note "$net: not defined"
  fi
done

log "guests (the harness table in guests.tsv)"
printf '   %-14s %-8s %-6s %-11s %s\n' NAME STATE VCPUS MEMORY ADDRESSES
while read -r i; do
  name="${GUEST_NAMES[$i]}"
  state="-"; vcpus="-"; mem="-"; addrs="-"
  if domain_exists "$name"; then
    state="$(virsh_q domstate "$name" || true)"
    vcpus="$(virsh_q dominfo "$name" | awk '/^CPU\(s\):/{print $2}' || true)"
    mem="$(virsh_q dominfo "$name" | awk '/^Max memory:/{printf "%s MiB", $3/1024}' || true)"
    addrs="$(virsh_q domifaddr "$name" | awk '/ipv4|ipv6/{printf "%s ", $4}' || true)"
  fi
  printf '   %-14s %-8s %-6s %-11s %s\n' "$name" "${state:--}" "${vcpus:--}" "${mem:--}" "${addrs:--}"
done < <(selected_indexes)

log "other domains (not created by this harness, never touched by down.sh)"
found_other=0
while read -r d; do
  [ -n "$d" ] || continue
  keep=1
  for n in "${GUEST_NAMES[@]}"; do
    if [ "$n" = "$d" ]; then keep=0; fi
  done
  if [ "$keep" = 1 ]; then
    note "$d"
    found_other=1
  fi
done < <(virsh_q list --all --name || true)
if [ "$found_other" = 0 ]; then
  note "(none)"
fi

log "talos"
if [ -f "$TALOS_LAB_OUT/talosconfig" ]; then
  note "talosconfig: $TALOS_LAB_OUT/talosconfig"
  note "endpoint:    $(talos_endpoint)"
  while read -r i; do
    [ "${GUEST_KIND[$i]}" = "talos" ] || continue
    ip="${GUEST_IP_LAB[$i]}"
    if ! command -v talosctl >/dev/null 2>&1; then
      note "${GUEST_NAMES[$i]} ($ip): talosctl not installed"
    elif tver="$(timeout 15 talosctl --talosconfig "$TALOS_LAB_OUT/talosconfig" \
             --endpoints "$ip" --nodes "$ip" version 2>&1)"; then
      note "${GUEST_NAMES[$i]} ($ip): $(printf '%s' "$tver" | awk '/Tag:/{printf "%s ", $2}')"
    else
      note "${GUEST_NAMES[$i]} ($ip): not answering on the configured API"
    fi
  done < <(selected_indexes)
else
  note "no lab talosconfig at $TALOS_LAB_OUT (run scripts/lab/virt/up.sh)"
fi

log "storage services (NAS stand-in)"
while read -r i; do
  [ "${GUEST_KIND[$i]}" = "debian" ] || continue
  ip="${GUEST_IP_LAB[$i]}"
  for port in 2049 445; do
    if (exec 3<>"/dev/tcp/$ip/$port") 2>/dev/null; then
      note "${GUEST_NAMES[$i]} ($ip): tcp/$port open"
    else
      note "${GUEST_NAMES[$i]} ($ip): tcp/$port closed"
    fi
  done
  if [ -n "${GUEST_IP_STORAGE[$i]}" ]; then
    note "${GUEST_NAMES[$i]}: storage NIC ${GUEST_IP_STORAGE[$i]}/30 on $NET_STORAGE"
  fi
done < <(selected_indexes)
