#!/usr/bin/env bash
# Bring up the libvirt lab guests on THIS laptop (never the real hosts).
#
# Creates two private libvirt networks (10.99.100.0/24 NAT + 10.99.101.0/30 isolated, never bridged
# to the house LAN), then the guests listed in guests.tsv, then drives the Talos nodes exactly like
# docs/runbooks/talos-bootstrap.md: wait for the maintenance-mode DHCP lease, apply-config
# --insecure, wait for the node to come back, and bootstrap the control plane once. After the
# bootstrap it fetches the kubeconfig into talos/out/lab and installs Cilium (scripts/talos/install-cni.sh),
# so the nodes turn Ready and Flux can be installed next (docs/lab.md).
#
# Usage:
#   scripts/lab/virt/up.sh --dry-run                 # print everything, create nothing
#   scripts/lab/virt/up.sh --only lab-talos-cp       # one guest (recommended: RAM is tight)
#   scripts/lab/virt/up.sh                           # every guest in guests.tsv
#
# Flags: --dry-run | --only <a,b> | --all | --force | --no-config | --no-bootstrap | --no-cni
#        --no-nwfilter | --dhcp | --timeout <seconds>
#
# Env:   LAB_VIRT_DIR, LIBVIRT_URI, WAIT_TIMEOUT, RAM_HEADROOM_MIB, STATIC_NET
#
# The host also runs Docker and the kind lab; RAM is the binding constraint, so the RAM gate
# refuses an over-committed start unless --force. See docs/lab.md ('libvirt guests').
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,23p' "$0"; }

ONLY=""
FORCE=0
DO_CONFIG=1
DO_BOOTSTRAP=1
DO_CNI=1

# shellcheck disable=SC2034 # WITH_NWFILTER, STATIC_NET and WAIT_TIMEOUT are consumed by lib.sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY=1; shift ;;
    --only)         ONLY="${ONLY:+$ONLY,}${2:-}"; shift 2 ;;
    --all)          ONLY=""; shift ;;
    --force)        FORCE=1; shift ;;
    --no-config)    DO_CONFIG=0; shift ;;
    --no-bootstrap) DO_BOOTSTRAP=0; DO_CNI=0; shift ;;
    --no-cni)       DO_CNI=0; shift ;;
    --no-nwfilter)  WITH_NWFILTER=0; shift ;;
    --dhcp)         STATIC_NET=0; shift ;;
    --timeout)      WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_cmd virsh
require_cmd qemu-img
require_cmd curl
require_cmd awk
require_cmd stat
require_cmd sed
require_cmd sha256sum
require_cmd sha512sum
require_cmd xorriso "cloud-init seed ISO (NoCloud)"

load_guests
if [ -n "$ONLY" ]; then select_only "$ONLY"; else select_all; fi

needs_talos=0
needs_debian=0
while read -r i; do
  case "${GUEST_KIND[$i]}" in
    talos)  needs_talos=1 ;;
    debian) needs_debian=1 ;;
  esac
done < <(selected_indexes)
if [ "$needs_talos" = 1 ]; then require_cmd talosctl "Talos guests selected"; fi

log "1/6 prerequisites"
if [ "$DRY" = 1 ]; then check_libvirt soft; else check_libvirt hard || exit 1; fi

plan_resources
ram_mode=hard
if [ "$DRY" = 1 ]; then ram_mode=soft; fi
if [ "$FORCE" = 1 ]; then
  note "--force: RAM gate skipped"
elif ! check_ram "$ram_mode"; then
  exit 1
fi
warn_about_kind
show_addressing

log "2/6 working directories"
ensure_dirs

log "3/6 images"
if [ "$DO_CONFIG" = 1 ] && [ "$needs_talos" = 1 ]; then
  ensure_talos_configs
fi
ensure_images
# needs_debian is used by ensure_images through the table; keep the variable meaningful here.
[ "$needs_debian" = 1 ] && note "NAS stand-in: Debian cloud image + cloud-init (NFS + SMB, not TrueNAS)"

log "4/6 isolation filter"
ensure_nwfilter

log "5/6 networks"
ensure_networks

log "6/6 guests"
while read -r i; do
  name="${GUEST_NAMES[$i]}"
  note "$name: ${GUEST_KIND[$i]}, ${GUEST_VCPU[$i]} vCPU, ${GUEST_MEM[$i]} MiB, ${GUEST_DISK[$i]} GiB"
  if [ "${GUEST_KIND[$i]}" = "debian" ]; then ensure_nas_seed_iso "$name"; fi
  ensure_disk "$i"
  ensure_domain "$i"
  start_domain "$name"
done < <(selected_indexes)

if [ "$DRY" = 1 ]; then
  log "dry-run complete — nothing was created"
  note "re-run without --dry-run to actually build the lab."
  exit 0
fi

# ---------------------------------------------------------------------------
# Bring-up: Talos driven per docs/runbooks/talos-bootstrap.md, NAS to NFS/SMB ready.
# ---------------------------------------------------------------------------
while read -r i; do
  name="${GUEST_NAMES[$i]}"
  name_ip="${GUEST_IP_LAB[$i]}"
  if [ "${GUEST_KIND[$i]}" = "talos" ]; then
    log "$name: maintenance-mode boot"
    wait_lease "$NET_LAB" "${GUEST_MAC_LAB[$i]}" "$name_ip" >/dev/null
    wait_tcp "$name_ip" 50000
    talos_apply "$i"
    talos_wait_configured "$name_ip"
    talos_wait_installed "$name_ip"
  else
    log "$name: cloud-init boot"
    wait_lease "$NET_LAB" "${GUEST_MAC_LAB[$i]}" "$name_ip" >/dev/null
    wait_tcp "$name_ip" 2049
    wait_tcp "$name_ip" 445
    note "$name: NFS (2049) and SMB (445) are serving"
  fi
done < <(selected_indexes)

if [ "$DO_BOOTSTRAP" = 1 ] && [ "$needs_talos" = 1 ]; then
  cp_ip=""
  while read -r i; do
    case "${GUEST_NAMES[$i]}" in
      *-cp) cp_ip="${GUEST_IP_LAB[$i]}" ;;
    esac
  done < <(selected_indexes)
  if [ -n "$cp_ip" ]; then
    log "bootstrap the control plane ($cp_ip) — creates etcd, cannot be undone in place"
    # Let the talosconfig carry the endpoint: scripts/talos/bootstrap.sh only passes --nodes.
    talos_config_point_at "$cp_ip"
    # Retry only the "not available yet" refusal (etcd still preparing); anything else is fatal.
    deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
    until out="$("$REPO_ROOT/scripts/talos/bootstrap.sh" \
        --node "$cp_ip" --talosconfig "$TALOS_LAB_OUT/talosconfig" --confirm 2>&1)"; do
      case "$out" in
        *"not available yet"*) : ;;
        *) printf '%s\n' "$out" >&2; die "bootstrap failed" ;;
      esac
      [ "$(date +%s)" -lt "$deadline" ] || die "bootstrap still not available after ${WAIT_TIMEOUT}s"
      note "bootstrap not available yet; retrying"
      sleep 10
    done
    printf '%s\n' "$out"
    if [ "$DO_CNI" = 1 ]; then
      log "kubeconfig + Cilium (docs/runbooks/talos-bootstrap.md §6-7)"
      wait_tcp "$cp_ip" 6443
      run env TALOS_INPUTS="$TALOS_LAB_INPUTS" TALOS_OUT_DIR="$TALOS_LAB_OUT" \
        "$REPO_ROOT/scripts/talos/kubeconfig.sh" --node "$cp_ip" --confirm
      run "$REPO_ROOT/scripts/talos/install-cni.sh" \
        --kubeconfig "$TALOS_LAB_OUT/kubeconfig" --confirm
    fi
  else
    note "no control-plane guest selected — skipping bootstrap"
  fi
fi

log "lab is up"
"$VIRSH_BIN" -c "$LIBVIRT_URI" list --all
echo
note "kubeconfig:   $TALOS_LAB_OUT/kubeconfig (gitignored; admin credentials)"
note "nodes:        kubectl --kubeconfig $TALOS_LAB_OUT/kubeconfig get nodes -o wide"
note "status:       just lab-virt-status"
note "tear down:    just lab-virt-down"
