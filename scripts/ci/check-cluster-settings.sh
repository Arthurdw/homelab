#!/usr/bin/env bash
# Checks Flux postBuild variables: each kubernetes/clusters/<env>/cluster-settings.yaml must define
# the same keys, every ${VAR} used in the shared tree must be defined in all of them, and every
# cluster Kustomization must reference the ConfigMap.
#
# Flux semantics (fluxcd/pkg/envsubst): only `${` triggers substitution (brace-less $VAR is left
# alone); an undefined variable becomes an empty string; `$${x}` yields a literal `${x}`; an
# unescaped `${...}` whose name is not [A-Za-z_][A-Za-z0-9_]* fails the whole Kustomization.
# Only YAML string values are scanned: kustomize strips comments before Flux substitutes, while
# block scalars (shell scripts) are substituted.
#
# Requires mikefarah yq v4 and GNU grep (scripts/ci/install-ci-tools.sh yq).
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2

fail=0
err() { printf 'ERROR: %s\n' "$*" >&2; fail=1; }

yq --version 2>&1 | grep -q mikefarah || { echo "ERROR: mikefarah yq v4 is required" >&2; exit 2; }

mapfile -t settings < <(find kubernetes/clusters -mindepth 2 -maxdepth 2 -name cluster-settings.yaml | sort)
[ "${#settings[@]}" -gt 0 ] || { echo "ERROR: no kubernetes/clusters/*/cluster-settings.yaml" >&2; exit 2; }

# Keys per cluster, and the union across clusters.
declare -A keys_of=()
union=""
for f in "${settings[@]}"; do
  cluster="$(basename "$(dirname "$f")")"
  if [ "$(yq '.kind + "/" + .metadata.name + "/" + .metadata.namespace' "$f")" != "ConfigMap/cluster-settings/flux-system" ]; then
    err "$f: must be ConfigMap cluster-settings in namespace flux-system"
    continue
  fi
  keys_of[$cluster]="$(yq '.data // {} | keys | .[]' "$f" | sort)"
  union+="${keys_of[$cluster]}"$'\n'
done
union="$(printf '%s' "$union" | sort -u | sed '/^$/d')"

for cluster in "${!keys_of[@]}"; do
  while IFS= read -r k; do
    grep -qxF "$k" <<<"${keys_of[$cluster]}" || err "cluster '$cluster' does not define '$k'"
  done <<<"$union"
done

# Variables used by the shared tree (everything outside kubernetes/clusters).
used=""
while IFS= read -r f; do
  vals="$(yq '.. | select(tag == "!!str")' "$f" 2>/dev/null)"
  # Unescaped `${` that is not a valid `${NAME}`.
  bad="$(grep -oP '(?<!\$)\$\{(?![_A-Za-z][_A-Za-z0-9_]*\})[^}]*\}?' <<<"$vals")"
  while IFS= read -r tok; do
    [ -n "$tok" ] && err "$f: '$tok' is not a valid Flux variable; escape a literal as '\$$tok'"
  done <<<"$bad"
  used+="$(grep -oP '(?<!\$)\$\{\K[_A-Za-z][_A-Za-z0-9_]*(?=\})' <<<"$vals")"$'\n'
done < <(find kubernetes -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path 'kubernetes/clusters/*' | sort)
used="$(printf '%s' "$used" | sort -u | sed '/^$/d')"

while IFS= read -r v; do
  [ -n "$v" ] || continue
  for cluster in "${!keys_of[@]}"; do
    grep -qxF "$v" <<<"${keys_of[$cluster]}" || err "\${$v} is used but cluster '$cluster' does not define it"
  done
done <<<"$used"

# Every Flux Kustomization in a cluster directory must read the ConfigMap.
while IFS= read -r f; do
  [ "$(yq '.kind' "$f")" = "Kustomization" ] || continue
  yq -e '.spec.postBuild.substituteFrom[] | select(.kind == "ConfigMap" and .name == "cluster-settings")' "$f" >/dev/null 2>&1 ||
    err "$f: no postBuild.substituteFrom to ConfigMap/cluster-settings"
done < <(find kubernetes/clusters -mindepth 2 -maxdepth 2 -name '*.yaml' -not -name cluster-settings.yaml | sort)

if [ "$fail" -eq 0 ]; then
  echo "OK: cluster-settings consistent; shared tree uses: $(echo "$used" | tr "\n" " ")"
fi
exit "$fail"
