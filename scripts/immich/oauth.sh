#!/usr/bin/env bash
# Turn on Immich's OAuth login against Authentik through Immich's API (docs/runbooks/sso.md "## Immich").
#
# Reads the client secret from the cluster Secret authentik/authentik-immich-oidc (key client-secret),
# GETs /api/system-config, merges the oauth section and PUTs the whole object back. Other oauth fields
# and the rest of the config stay as they are; the settings page stays editable; nothing goes into git.
# The admin API key comes from IMMICH_API_KEY or a silent prompt. It needs an admin user and the
# systemConfig.read + systemConfig.update permissions (or "all").
#
# Usage:
#   ./scripts/immich/oauth.sh [--context homelab] [--url https://immich.lab.ardw.be] [--dry-run]
# --dry-run prints the oauth section before and after (clientSecret redacted) and does not PUT.
set -euo pipefail

CONTEXT="homelab"
URL="https://immich.lab.ardw.be"
DRY=0

SECRET_NS="authentik"
SECRET_NAME="authentik-immich-oidc"
SECRET_KEY="client-secret"
ISSUER="https://auth.lab.ardw.be/application/o/immich/"

usage() { sed -n '2,12p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --url)     URL="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
URL="${URL%/}"

for tool in kubectl curl jq base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found in PATH" >&2; exit 1; }
done

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
umask 077

# --- client secret from the cluster -----------------------------------------------------------------
if ! kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1; then
  echo "kubectl context '$CONTEXT' not found (run 'just kube-merge', or pass --context)" >&2
  exit 1
fi
if ! kubectl --context "$CONTEXT" -n "$SECRET_NS" get secret "$SECRET_NAME" \
    -o "jsonpath={.data.$SECRET_KEY}" >"$TMP/secret.b64" 2>"$TMP/kubectl.err"; then
  echo "cannot read secret $SECRET_NS/$SECRET_NAME in context '$CONTEXT':" >&2
  cat "$TMP/kubectl.err" >&2
  exit 1
fi
if [ ! -s "$TMP/secret.b64" ]; then
  echo "secret $SECRET_NS/$SECRET_NAME has no key '$SECRET_KEY'" >&2
  exit 1
fi
base64 -d <"$TMP/secret.b64" >"$TMP/secret"

# --- Immich admin API key (header file, never on argv) ----------------------------------------------
API_KEY="${IMMICH_API_KEY:-}"
if [ -z "$API_KEY" ]; then
  read -r -s -p "Immich admin API key: " API_KEY
  echo >&2
fi
# A paste into the prompt can carry the terminal's bracketed-paste markers (ESC[200~ ... ESC[201~);
# in a header they make Traefik reset the stream. Drop them, then any whitespace/control characters.
API_KEY="${API_KEY//$'\e[200~'/}"
API_KEY="${API_KEY//$'\e[201~'/}"
API_KEY="$(printf '%s' "$API_KEY" | tr -d '[:space:][:cntrl:]')"
[ -n "$API_KEY" ] || { echo "no API key given" >&2; exit 1; }
printf 'x-api-key: %s\n' "$API_KEY" >"$TMP/headers"
unset API_KEY

# api METHOD PATH OUTFILE [BODYFILE]
api() {
  local method="$1" path="$2" out="$3" body="${4:-}" code rc=0
  local args=(-sS --fail-with-body -o "$out" -w '%{http_code}' -X "$method"
    -H @"$TMP/headers" -H 'Accept: application/json')
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary @"$body")
  fi
  code="$(curl "${args[@]}" "$URL$path" 2>"$TMP/curl.err")" || rc=$?
  case "$code" in
    2??) return 0 ;;
    401|403)
      echo "Immich refused $method $path (HTTP $code): the API key must belong to an admin user and" \
        "carry systemConfig.read and systemConfig.update (or all)" >&2
      exit 1 ;;
    000|"")
      echo "Immich unreachable at $URL (curl exit $rc):" >&2
      cat "$TMP/curl.err" >&2
      exit 1 ;;
    *)
      echo "$method $path failed (HTTP $code):" >&2
      cat "$out" >&2; echo >&2
      exit 1 ;;
  esac
}

redact='.clientSecret |= (if (. // "") == "" then . else "<redacted>" end)'

# BEGIN MERGE (kept as one filter so it can be tested offline)
# shellcheck disable=SC2016 # jq variables, not shell ones
MERGE='.oauth += {
  enabled: true,
  issuerUrl: $issuer,
  clientId: "immich",
  clientSecret: $secret,
  scope: "openid email profile",
  signingAlgorithm: "RS256",
  buttonText: "Login with Authentik",
  autoRegister: true,
  autoLaunch: false,
  mobileOverrideEnabled: false
}'
# END MERGE

api GET /api/system-config "$TMP/current.json"
jq -e '.oauth | type == "object"' "$TMP/current.json" >/dev/null \
  || { echo "unexpected /api/system-config response: no oauth section" >&2; exit 1; }
jq --arg issuer "$ISSUER" --rawfile secret "$TMP/secret" "$MERGE" "$TMP/current.json" >"$TMP/new.json"

if [ "$DRY" = 1 ]; then
  echo "--- oauth before"
  jq ".oauth | $redact" "$TMP/current.json"
  echo "--- oauth after"
  jq ".oauth | $redact" "$TMP/new.json"
  echo "dry run: nothing sent"
  exit 0
fi

api PUT /api/system-config "$TMP/put.json" "$TMP/new.json"
api GET /api/system-config "$TMP/after.json"
if ! jq -e --arg issuer "$ISSUER" '.oauth.enabled == true and .oauth.issuerUrl == $issuer' \
    "$TMP/after.json" >/dev/null; then
  echo "PUT succeeded but the config read back does not show oauth enabled with issuer $ISSUER" >&2
  exit 1
fi
echo "Immich OAuth on: \"Login with Authentik\" at $URL (issuer $ISSUER)."
echo "Existing Immich users are matched by email: give each Authentik user the same email first."
