#!/usr/bin/env bash
# Point the share links Immich generates at the public proxy (docs/runbooks/public-shares.md).
#
# Sets server.externalDomain to https://photos.ardw.be through Immich's API: GETs /api/system-config,
# changes that one field and PUTs the whole object back, so the rest of the config stays as it is and the
# settings page stays editable. Running it again when the value is already set changes nothing.
# The admin API key comes from IMMICH_API_KEY or a silent prompt and is only ever written to a header
# file in a private temp dir (never argv). It needs an admin user and the systemConfig.read +
# systemConfig.update permissions (or "all").
#
# Usage:
#   ./scripts/immich/external-domain.sh [--url https://immich.lab.ardw.be] [--domain https://photos.ardw.be] [--dry-run]
# --dry-run prints the current and desired value and does not PUT.
set -euo pipefail

URL="https://immich.lab.ardw.be"
DOMAIN="https://photos.ardw.be"
DRY=0

usage() { sed -n '2,13p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url)     URL="${2:-}"; shift 2 ;;
    --domain)  DOMAIN="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
URL="${URL%/}"
DOMAIN="${DOMAIN%/}"
case "$DOMAIN" in
  https://*) ;;
  *) echo "--domain must be an https:// URL, got: $DOMAIN" >&2; exit 2 ;;
esac

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found in PATH" >&2; exit 1; }
done

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
umask 077

# --- Immich admin API key (header file, never on argv) ----------------------------------------------
API_KEY="${IMMICH_API_KEY:-}"
if [ -z "$API_KEY" ]; then
  read -r -s -p "Immich admin API key: " API_KEY
  echo >&2
fi
# Same clean-up as oauth.sh: drop bracketed-paste markers, then whitespace/control characters.
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

api GET /api/system-config "$TMP/current.json"
jq -e '.server | type == "object"' "$TMP/current.json" >/dev/null \
  || { echo "unexpected /api/system-config response: no server section" >&2; exit 1; }
current="$(jq -r '.server.externalDomain // ""' "$TMP/current.json")"

if [ "$current" = "$DOMAIN" ]; then
  echo "server.externalDomain is already $DOMAIN: nothing to do."
  exit 0
fi
echo "server.externalDomain: '${current}' -> '$DOMAIN'"
if [ "$DRY" = 1 ]; then
  echo "dry run: nothing sent"
  exit 0
fi

jq --arg d "$DOMAIN" '.server.externalDomain = $d' "$TMP/current.json" >"$TMP/new.json"
api PUT /api/system-config "$TMP/put.json" "$TMP/new.json"
api GET /api/system-config "$TMP/after.json"
if ! jq -e --arg d "$DOMAIN" '.server.externalDomain == $d' "$TMP/after.json" >/dev/null; then
  echo "PUT succeeded but the config read back does not show server.externalDomain = $DOMAIN" >&2
  exit 1
fi
echo "Immich share links now use $DOMAIN. Existing links keep working: only the host Immich shows changed."
