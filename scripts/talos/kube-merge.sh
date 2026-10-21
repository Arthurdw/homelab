#!/usr/bin/env bash
# Merge a cluster's admin kubeconfig into ~/.kube/config under a short context name, so `kubectx <name>`
# switches to it. kubeconfig.sh deliberately writes only the gitignored file; this is the opt-in step after it.
#
# An existing context, cluster or user of the same name is replaced (a regenerated cluster has new certs).
# ~/.kube/config is backed up next to itself first, and the result is mode 600.
#
# Usage:
#   ./scripts/talos/kube-merge.sh [--name homelab] [--kubeconfig talos/out/kubeconfig]
#   ./scripts/talos/kube-merge.sh --name homelab-lab --kubeconfig talos/out/lab/kubeconfig
set -euo pipefail

name=homelab
src=talos/out/kubeconfig
target="${KUBE_MERGE_TARGET:-$HOME/.kube/config}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="${2:?}"; shift 2 ;;
    --kubeconfig) src="${2:?}"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -f "$src" ] || die "$src not found (run kubeconfig.sh first)"
[ "$(kubectl --kubeconfig "$src" config get-contexts -o name | wc -l)" = 1 ] || die "$src must hold exactly one context"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

# Rename context, cluster and user to $name, so nothing collides with another cluster's admin@... entries.
cp "$src" "$tmp/new"
ctx="$(kubectl --kubeconfig "$tmp/new" config current-context)"
cluster="$(kubectl --kubeconfig "$tmp/new" config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}")"
user="$(kubectl --kubeconfig "$tmp/new" config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.user}")"
kubectl --kubeconfig "$tmp/new" config view --flatten -o json |
  jq --arg n "$name" --arg c "$cluster" --arg u "$user" --arg x "$ctx" '
    .clusters |= map(if .name == $c then .name = $n else . end)
    | .users |= map(if .name == $u then .name = $n else . end)
    | .contexts |= map(if .name == $x then .name = $n | .context.cluster = $n | .context.user = $n else . end)
    | ."current-context" = $n' > "$tmp/new.json"

mkdir -p "$(dirname "$target")"
if [ -s "$target" ]; then
  cp -p "$target" "$target.bak-$(date +%Y%m%d-%H%M%S)"
  # Drop the old entries of this name, then merge; the new file wins on any remaining overlap.
  kubectl --kubeconfig "$target" config view --flatten -o json |
    jq --arg n "$name" '
      .clusters |= map(select(.name != $n)) | .users |= map(select(.name != $n))
      | .contexts |= map(select(.name != $n))' > "$tmp/old.json"
  KUBECONFIG="$tmp/new.json:$tmp/old.json" kubectl config view --flatten > "$tmp/merged"
else
  kubectl --kubeconfig "$tmp/new.json" config view --flatten > "$tmp/merged"
fi
install -m 600 "$tmp/merged" "$target"
echo "merged $src into $target as context '$name' (now current). Switch with: kubectx $name"
