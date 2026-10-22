#!/usr/bin/env bash
# Turn on Audiobookshelf's OpenID login against Authentik through its API (docs/runbooks/sso.md "## Audiobookshelf").
#
# Reads the client secret from the cluster Secret authentik/authentik-audiobookshelf-oidc (key client-secret),
# then PATCHes /api/auth-settings with the Authentik endpoints. Only the openid fields and the active methods
# are sent; other settings stay as they are. Local login stays enabled (break-glass); nothing goes into git.
# The admin token comes from ABS_TOKEN or a silent prompt (an admin user's API key or token).
#
# Usage:
#   ./scripts/audiobookshelf/oauth.sh [--context homelab] [--url https://audiobookshelf.lab.ardw.be] [--dry-run]
# --dry-run prints the openid settings before and the PATCH body (client secret redacted) and sends nothing.
set -euo pipefail

CONTEXT="homelab"
URL="https://audiobookshelf.lab.ardw.be"
DRY=0

SECRET_NS="authentik"
SECRET_NAME="authentik-audiobookshelf-oidc"
SECRET_KEY="client-secret"
ISSUER="https://auth.lab.ardw.be/application/o/audiobookshelf/"
AUTHENTIK="https://auth.lab.ardw.be"

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

# --- Audiobookshelf admin token (header file, never on argv) ----------------------------------------
TOKEN="${ABS_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  read -r -s -p "Audiobookshelf admin API token: " TOKEN
  echo >&2
fi
# Drop terminal bracketed-paste markers, then any whitespace/control characters.
TOKEN="${TOKEN//$'\e[200~'/}"
TOKEN="${TOKEN//$'\e[201~'/}"
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:][:cntrl:]')"
[ -n "$TOKEN" ] || { echo "no token given" >&2; exit 1; }
printf 'Authorization: Bearer %s\n' "$TOKEN" >"$TMP/headers"
unset TOKEN

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
      echo "Audiobookshelf refused $method $path (HTTP $code): the token must belong to an admin user" >&2
      exit 1 ;;
    000|"")
      echo "Audiobookshelf unreachable at $URL (curl exit $rc):" >&2
      cat "$TMP/curl.err" >&2
      exit 1 ;;
    *)
      echo "$method $path failed (HTTP $code):" >&2
      cat "$out" >&2; echo >&2
      exit 1 ;;
  esac
}

# GET may nest the settings under .serverSettings or return them flat; the PATCH body is flat.
redact='del(.authOpenIDClientSecret)'
view='(.serverSettings // .) | with_entries(select((.key | startswith("authOpenID")) or .key == "authActiveAuthMethods")) | del(.authOpenIDClientSecret)'

# authOpenIDSubfolderForRedirectURLs prefixes the redirect_uri ABS sends; left unset, ABS sends the literal
# "/undefined/auth/openid/callback". "" is the settings page's "None": ABS is served at the host root.
# BEGIN PATCH (kept as one filter so it can be tested offline)
# shellcheck disable=SC2016 # jq variables, not shell ones
PATCH='{
  authActiveAuthMethods: ["local", "openid"],
  authOpenIDIssuerURL: $issuer,
  authOpenIDAuthorizationURL: ($base + "/application/o/authorize/"),
  authOpenIDTokenURL: ($base + "/application/o/token/"),
  authOpenIDUserInfoURL: ($base + "/application/o/userinfo/"),
  authOpenIDJwksURL: ($issuer + "jwks/"),
  authOpenIDLogoutURL: ($issuer + "end-session/"),
  authOpenIDClientID: "audiobookshelf",
  authOpenIDClientSecret: $secret,
  authOpenIDTokenSigningAlgorithm: "RS256",
  authOpenIDButtonText: "Login with Authentik",
  authOpenIDAutoLaunch: false,
  authOpenIDAutoRegister: true,
  authOpenIDMatchExistingBy: "email",
  authOpenIDSubfolderForRedirectURLs: ""
}'
# END PATCH

api GET /api/auth-settings "$TMP/current.json"
jq -e 'type == "object"' "$TMP/current.json" >/dev/null \
  || { echo "unexpected /api/auth-settings response" >&2; exit 1; }
jq -n --arg issuer "$ISSUER" --arg base "$AUTHENTIK" --rawfile secret "$TMP/secret" "$PATCH" >"$TMP/patch.json"

if [ "$DRY" = 1 ]; then
  echo "--- openid before"
  jq "$view" "$TMP/current.json"
  echo "--- PATCH body (client secret redacted)"
  jq "$redact" "$TMP/patch.json"
  echo "dry run: nothing sent"
  exit 0
fi

api PATCH /api/auth-settings "$TMP/patch.out" "$TMP/patch.json"
api GET /api/auth-settings "$TMP/after.json"
# ABS silently drops "openid" from the active methods when a required field is missing.
if ! jq -e --arg issuer "$ISSUER" '(.serverSettings // .) as $s
    | $s.authOpenIDIssuerURL == $issuer and $s.authOpenIDSubfolderForRedirectURLs == ""
      and (($s.authActiveAuthMethods // []) | index("openid") != null)' \
    "$TMP/after.json" >/dev/null; then
  echo "PATCH sent but openid is not active with issuer $ISSUER; compare with --dry-run" >&2
  exit 1
fi
echo "Audiobookshelf OpenID on: \"Login with Authentik\" at $URL (issuer $ISSUER); local login still enabled."
echo "Existing ABS users are matched by email (set the same email on the ABS user); new users are auto-created."
