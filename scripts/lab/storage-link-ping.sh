#!/usr/bin/env bash
# Prove the storage link end to end on the L1 fixtures: from lab-pve, ping lab-truenas over vmbr1 with
# a full 9000-byte frame (8972 bytes of payload + 28 of headers, do-not-fragment), and show both ends.
# It needs both fixtures up and the Proxmox and TrueNAS roots applied (pve-fixture-plan.sh --keep and
# truenas-fixture-plan.sh). It only talks to lab-pve (10.99.100.x, its own key) and, from there, to the
# isolated link address; never to a real host. Nothing is changed on either fixture.
#
# Usage: scripts/lab/storage-link-ping.sh        Env: LAB_PVE_DIR (default talos/out/lab-pve)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${LAB_PVE_DIR:-$REPO_ROOT/talos/out/lab-pve}"
ENV_FILE="$OUT_DIR/fixture.env"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no fixture credentials at $ENV_FILE (run: just lab-pve)"
# shellcheck disable=SC1090
. "$ENV_FILE"
[ -f "${LAB_PVE_SSH_KEY:-}" ] || die "no fixture ssh key"
host="${LAB_PVE_URL#https://}"; host="${host%%:*}"
[[ "$host" =~ ^10\.99\.100\.([1-9][0-9]{0,2})$ ]] && [ "${BASH_REMATCH[1]}" -le 254 ] \
  || die "refusing: '$host' is not an address in 10.99.100.0/24"

pve() {
  ssh -i "$LAB_PVE_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$host" "$@"
}

echo "== lab-pve end (vmbr1) =="
pve "ip -d link show vmbr1 | head -1; ip -d link show nic2 | head -1; ip -4 -br addr show vmbr1" | sed 's/^/   /'
echo "== jumbo ping, 8972 bytes, do not fragment =="
pve "ping -M do -s 8972 -c 3 -W 2 10.99.0.2" | sed 's/^/   /' || die "the 9000-byte frame did not get through"
echo "== a frame one byte too large must be refused locally (proves the path MTU is exactly 9000) =="
if pve "ping -M do -s 8973 -c 1 -W 2 10.99.0.2" >/dev/null 2>&1; then die "an oversize frame passed"; fi
echo "   refused, as expected"
echo "ok: 10.99.0.1 <-> 10.99.0.2 carries 9000-byte frames"
