#!/usr/bin/env bash
# render-helm-releases.sh — abstract ("no cluster required") render check for every
# Flux HelmRelease in the repository.
#
# WHY THIS EXISTS
#   A HelmRelease whose `spec.values` break a chart's template only failed *after* Flux
#   installed it into a live cluster (the technitium `service.type` bug). That class of
#   failure is static: `helm template` reproduces it exactly, with no cluster, no apply,
#   and no credentials.
#
# WHAT IT DOES
#   For every `kind: HelmRelease` document in the repo it:
#     1. resolves the chart name + version + source URL from the manifests themselves
#        (`spec.chart.spec.*` + the referenced HelmRepository, or `spec.chartRef` →
#        OCIRepository) — nothing is hard-coded;
#     2. pulls the repositories into a throwaway cache under a temp dir;
#     3. runs `helm template` with that release's `spec.values`.
#
#   FAILS on template/render errors (the bug this exists to catch). A failure caused only
#   by a chart's own "you must supply this value" guard (`required`/`fail`) is reported as
#   INCOMPLETE and tolerated by default, because the repo's GATE-0 scaffolds legitimately
#   leave values unwritten — pass --strict to fail on those too once values are filled in.
#   Nothing is ever skipped silently: every release is listed with its outcome.
#
# REQUIREMENTS
#   helm (>=3) and mikefarah yq (v4) on PATH. Install pinned copies with:
#     scripts/ci/install-ci-tools.sh helm yq
#
# USAGE
#   scripts/ci/render-helm-releases.sh [--strict]
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root" || exit 2

strict=0
for arg in "$@"; do
  case "$arg" in
    --strict) strict=1 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# --- required tools (fail loudly; never guess) ------------------------------
missing=()
for t in helm yq; do have "$t" || missing+=("$t"); done
if [ "${#missing[@]}" -gt 0 ]; then
  log "ERROR: missing required tool(s): ${missing[*]}" >&2
  log "       install pinned copies with: scripts/ci/install-ci-tools.sh helm yq" >&2
  exit 2
fi
if ! yq --version 2>&1 | grep -q 'mikefarah'; then
  log "ERROR: yq must be the mikefarah yq v4 (got: $(yq --version 2>&1))." >&2
  log "       (e.g. pip's 'yq'/'jq' wrapper is not compatible.)" >&2
  exit 2
fi

# --- throwaway helm cache (nothing leaks into ~/.config or the repo) --------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HELM_CACHE_HOME="$tmp/helm-cache"
export HELM_CONFIG_HOME="$tmp/helm-config"
export HELM_DATA_HOME="$tmp/helm-data"
export HELM_REPOSITORY_CACHE="$tmp/helm/repository"
export HELM_REPOSITORY_CONFIG="$tmp/helm/repositories.yaml"
mkdir -p "$HELM_CACHE_HOME" "$HELM_CONFIG_HOME" "$HELM_DATA_HOME" "$(dirname "$HELM_REPOSITORY_CONFIG")"

# --- kubernetes API version used for templating (from versions.yaml) --------
kube_version=""
if [ -f versions.yaml ]; then
  kube_version="$(yq -r '.kubernetes.kubernetes // ""' versions.yaml 2>/dev/null | sed 's/^v//')"
fi
[ -n "$kube_version" ] && log "templating with kube version $kube_version (versions.yaml)"

# --- discover manifests -----------------------------------------------------
# Narrow with grep for speed, then confirm the actual kind with yq.
mapfile -t all_files < <(
  grep -rlE '^[[:space:]]*kind:[[:space:]]*HelmRelease' \
    --include='*.yaml' --include='*.yml' . 2>/dev/null \
  | grep -v '^\./\.git/' | grep -v '/node_modules/' | sort
)

# --- index every Flux source by "<namespace>/<name>" ------------------------
declare -A repo_url_by_key=()   # HelmRepository  ns/name -> url
declare -A oci_url_by_key=()    # OCIRepository   ns/name -> url
declare -A oci_tag_by_key=()    # OCIRepository   ns/name -> ref.tag/semver

mapfile -t src_files < <(
  grep -rlE '^[[:space:]]*kind:[[:space:]]*(HelmRepository|OCIRepository)' \
    --include='*.yaml' --include='*.yml' . 2>/dev/null \
  | grep -v '^\./\.git/' | grep -v '/node_modules/' | sort
)
for f in "${src_files[@]}"; do
  while IFS='|' read -r k ns name url tag; do
    [ -n "$name" ] || continue
    case "$k" in
      HelmRepository) repo_url_by_key["$ns/$name"]="$url" ;;
      OCIRepository)  oci_url_by_key["$ns/$name"]="$url"; oci_tag_by_key["$ns/$name"]="$tag" ;;
    esac
  done < <(yq -r 'select(.kind == "HelmRepository" or .kind == "OCIRepository") |
      .kind + "|" + (.metadata.namespace // "flux-system") + "|" +
      .metadata.name + "|" + (.spec.url // "") + "|" +
      ((.spec.ref.tag // .spec.ref.semver // "//NULL//") | tostring)' "$f" 2>/dev/null)
done

if [ "${#all_files[@]}" -eq 0 ]; then
  log "no HelmRelease manifests found"
  exit 0
fi

# --- register each unique HelmRepository once, in a temp cache --------------
declare -A repo_alias_by_url=()
n=0
for url in $(printf '%s\n' "${repo_url_by_key[@]}" | sort -u); do
  [ -n "$url" ] || continue
  n=$((n + 1))
  alias="repo$n"
  ok=0
  for _ in 1 2 3; do
    if helm repo add "$alias" "$url" >"$tmp/repo-add-$n.log" 2>&1; then ok=1; break; fi
    sleep 2
  done
  if [ "$ok" = 1 ]; then
    repo_alias_by_url["$url"]="$alias"
  else
    warn "could not reach HelmRepository $url (after 3 tries): $(tr '\n' ' ' <"$tmp/repo-add-$n.log")"
    repo_alias_by_url["$url"]="//UNAVAILABLE//"
  fi
done

pass=0
incomplete=0
failed=0
declare -a failed_list=()
declare -a incomplete_list=()

# classify <errfile> -> "required" | "network" | "other"
classify() {
  if grep -qiE '(is|are) required|must be (set|specified|provided)|no value for required' "$1"; then
    echo required
  elif grep -qiE 'dial tcp|no such host|i/o timeout|connection refused|failed to download|unable to get|not found|timed out' "$1"; then
    echo network
  else
    echo other
  fi
}

for f in "${all_files[@]}"; do
  mapfile -t idxs < <(yq -r 'select(.kind == "HelmRelease") | documentIndex' "$f" 2>/dev/null)
  for idx in "${idxs[@]}"; do
    meta="$(yq -r "select(documentIndex == $idx) |
      [.metadata.name, (.metadata.namespace // \"default\"),
       (.spec.chart.spec.chart // \"\"),
       (.spec.chart.spec.version // \"\"),
       (.spec.chart.spec.sourceRef.name // \"\"),
       (.spec.chart.spec.sourceRef.namespace // \"flux-system\"),
       (.spec.chartRef.name // \"\"),
       (.spec.chartRef.namespace // \"flux-system\"),
       (.spec.chartRef.kind // \"\")] | join(\"|\")" "$f" 2>/dev/null)"
    IFS='|' read -r name ns chart version src_name src_ns ref_name ref_ns ref_kind <<<"$meta"

    label="$ns/$name"
    log ""
    log "== $label =="

    # values -> temp file (omit -f when there are none)
    values_file=""
    yq -o=yaml "select(documentIndex == $idx) | .spec.values" "$f" >"$tmp/values.yaml" 2>/dev/null
    if [ -s "$tmp/values.yaml" ] && ! grep -qx 'null' "$tmp/values.yaml"; then
      values_file="$tmp/values-$ns-$name.yaml"
      cp "$tmp/values.yaml" "$values_file"
    fi
    if yq -e "select(documentIndex == $idx) | .spec.valuesFrom" "$f" >/dev/null 2>&1; then
      warn "$label uses spec.valuesFrom (cluster-side ConfigMap/Secret references) — not resolved here"
    fi

    # resolve the chart reference purely from the manifests
    chart_ref=""
    repo_url=""
    if [ -n "$chart" ]; then
      repo_url="${repo_url_by_key[$src_ns/$src_name]:-}"
      if [ -z "$repo_url" ]; then
        failed=$((failed + 1)); failed_list+=("$label: HelmRepository $src_ns/$src_name not found in repo")
        log "FAIL: chart source $src_ns/$src_name not found"
        continue
      fi
      alias="${repo_alias_by_url[$repo_url]:-}"
      if [ "$alias" = "//UNAVAILABLE//" ]; then
        failed=$((failed + 1)); failed_list+=("$label: HelmRepository $repo_url unreachable")
        log "FAIL: source $repo_url unreachable"
        continue
      fi
      chart_ref="$alias/$chart"
    elif [ -n "$ref_name" ]; then
      if [ "$ref_kind" != "OCIRepository" ]; then
        failed=$((failed + 1)); failed_list+=("$label: unsupported chartRef kind '$ref_kind'")
        log "FAIL: unsupported chartRef kind '$ref_kind'"
        continue
      fi
      repo_url="${oci_url_by_key[$ref_ns/$ref_name]:-}"
      if [ -z "$repo_url" ]; then
        failed=$((failed + 1)); failed_list+=("$label: OCIRepository $ref_ns/$ref_name not found in repo")
        log "FAIL: chartRef $ref_ns/$ref_name not found"
        continue
      fi
      chart_ref="$repo_url"
      version="${oci_tag_by_key[$ref_ns/$ref_name]:-}"
    else
      failed=$((failed + 1)); failed_list+=("$label: neither spec.chart nor spec.chartRef present")
      log "FAIL: no chart reference"
      continue
    fi

    args=(template "$name" "$chart_ref" --namespace "$ns" --skip-tests --include-crds)
    if [ -n "$version" ] && [ "$version" != "//NULL//" ]; then args+=(--version "$version"); fi
    [ -n "$kube_version" ] && args+=(--kube-version "$kube_version")
    [ -n "$values_file" ] && args+=(-f "$values_file")

    log "helm ${args[*]}"
    rc=0
    helm "${args[@]}" >"$tmp/render.out" 2>"$tmp/render.err" || rc=$?

    if [ "$rc" -eq 0 ]; then
      pass=$((pass + 1))
      log "PASS ($(wc -l <"$tmp/render.out") lines)"
      continue
    fi

    kind="$(classify "$tmp/render.err")"
    head -3 "$tmp/render.err" | sed 's/^/    /' >&2
    case "$kind" in
      required)
        incomplete=$((incomplete + 1))
        incomplete_list+=("$label")
        log "INCOMPLETE: needs values the manifest has not supplied yet (chart guard, not a render bug)"
        ;;
      network)
        failed=$((failed + 1))
        failed_list+=("$label: chart could not be fetched: $(head -1 "$tmp/render.err")")
        log "FAIL: chart could not be fetched"
        ;;
      *)
        failed=$((failed + 1))
        failed_list+=("$label: render error: $(head -1 "$tmp/render.err")")
        log "FAIL: helm template failed (this is the class of bug the check exists to catch)"
        ;;
    esac
  done
done

log ""
log "----- render summary -----"
log "rendered ok   : $pass"
log "incomplete    : $incomplete"
log "failed        : $failed"
if [ "${#incomplete_list[@]}" -gt 0 ]; then
  log "incomplete (values pending at GATE 0 — rerun with --strict after filling them):"
  for i in "${incomplete_list[@]}"; do log "  - $i"; done
fi
if [ "${#failed_list[@]}" -gt 0 ]; then
  log "failures:"
  for x in "${failed_list[@]}"; do log "  - $x"; done
fi

if [ "$failed" -gt 0 ]; then
  exit 1
fi
if [ "$strict" = 1 ] && [ "$incomplete" -gt 0 ]; then
  log "STRICT: failing on $incomplete incomplete release(s)"
  exit 1
fi
exit 0
