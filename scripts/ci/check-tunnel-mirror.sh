#!/usr/bin/env bash
# Checks that the cloudflared rules for files-ext.ardw.be (the outside view of Seafile, reachable from the
# LAN) are the same as the ones for files.ardw.be: same paths, same services, same order. If they drift,
# files-ext.ardw.be stops showing what the internet sees (kubernetes/apps/cloudflared/tunnel-config.yaml).
#
# Requires mikefarah yq v4 (scripts/ci/install-ci-tools.sh yq).
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2

yq --version 2>&1 | grep -q mikefarah || { echo "ERROR: mikefarah yq v4 is required" >&2; exit 2; }

cfg=kubernetes/apps/cloudflared/tunnel-config.yaml
rules() { yq ".ingress[] | select(.hostname == \"$1\") | (.path // \"\") + \" -> \" + .service" "$cfg"; }

canonical="$(rules files.ardw.be)"
mirror="$(rules files-ext.ardw.be)"

[ -n "$canonical" ] || { echo "ERROR: $cfg: no rules for files.ardw.be" >&2; exit 1; }
if [ "$canonical" != "$mirror" ]; then
  echo "ERROR: $cfg: the files-ext.ardw.be rules differ from the files.ardw.be rules:" >&2
  diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$mirror") >&2
  exit 1
fi
echo "tunnel mirror ok: $(wc -l <<<"$canonical") rules"
