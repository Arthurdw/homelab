#!/usr/bin/env bash
# Tear down the local lab. Removes the kind cluster and the test Git server container.
# Does not touch anything outside this workstation.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
CLUSTER="${CLUSTER:-homelab-lab}"

printf '\n== removing kind cluster %s ==\n' "$CLUSTER"
if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind delete cluster --name "$CLUSTER"
else
  echo "cluster not present"
fi

printf '\n== removing stray lab containers ==\n'
docker rm -f homelab-git-test >/dev/null 2>&1 || true

printf '\n== lab down ==\n'
