#!/usr/bin/env bash
# Turn on Technitium's SSO (OIDC) against Authentik through its HTTP API (docs/runbooks/sso.md "## Technitium").
#
# Logs in as the local admin with the password from the cluster Secret technitium/technitium-admin (key
# password), reads the client secret from authentik/authentik-technitium-oidc (key client-secret), and calls
# /api/admin/sso/set. Members of the Authentik group "authentik Admins" land in Technitium's Administrators
# group (synced at each SSO login); other users cannot sign up. The local admin stays as break-glass.
# Technitium restarts its web service after the change (a few seconds). The session token is dropped at the
# end (logout); no secret is printed or written outside a 0700 temp dir.
#
# Usage:
#   ./scripts/technitium/sso.sh [--context homelab] [--url https://dns.lab.ardw.be] [--dry-run]
# --dry-run shows the current SSO settings (client secret is masked by Technitium) and the new ones; sends no change.
set -euo pipefail

CONTEXT="homelab"
URL="https://dns.lab.ardw.be"
DRY=0

ADMIN_USER="admin"
ADMIN_NS="technitium"
ADMIN_SECRET="technitium-admin"
ADMIN_KEY="password"
OIDC_NS="authentik"
OIDC_SECRET="authentik-technitium-oidc"
OIDC_KEY="client-secret"

AUTHORITY="https://auth.lab.ardw.be/application/o/technitium/"
CLIENT_ID="technitium"
SCOPES="openid|email|profile"
GROUP_MAP="authentik Admins|Administrators"

usage() { sed -n '2,13p' "$0"; }

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
umask 077
LOGGED_IN=0
cleanup() {
  if [ "$LOGGED_IN" = 1 ]; then
    curl -sS -o /dev/null -H @"$TMP/headers" "$URL/api/user/logout" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

if ! kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1; then
  echo "kubectl context '$CONTEXT' not found (run 'just kube-merge', or pass --context)" >&2
  exit 1
fi

# read_secret NAMESPACE NAME KEY OUTFILE
read_secret() {
  if ! kubectl --context "$CONTEXT" -n "$1" get secret "$2" -o "jsonpath={.data.$3}" \
      >"$TMP/b64" 2>"$TMP/kubectl.err"; then
    echo "cannot read secret $1/$2 in context '$CONTEXT':" >&2
    cat "$TMP/kubectl.err" >&2
    exit 1
  fi
  if [ ! -s "$TMP/b64" ]; then
    echo "secret $1/$2 has no key '$3'" >&2
    exit 1
  fi
  base64 -d <"$TMP/b64" >"$4"
  rm -f "$TMP/b64"
}
read_secret "$ADMIN_NS" "$ADMIN_SECRET" "$ADMIN_KEY" "$TMP/admin-pass"
read_secret "$OIDC_NS" "$OIDC_SECRET" "$OIDC_KEY" "$TMP/secret"

# call_api OUTFILE CURL_ARGS... (Technitium answers HTTP 200 with {"status":"ok"|"error"|"invalid-token"})
call_api() {
  local out="$1" code rc=0
  shift
  code="$(curl -sS -o "$out" -w '%{http_code}' "$@" 2>"$TMP/curl.err")" || rc=$?
  case "$code" in
    2??) ;;
    000|"")
      echo "Technitium unreachable at $URL (curl exit $rc):" >&2
      cat "$TMP/curl.err" >&2
      exit 1 ;;
    *)
      echo "request failed (HTTP $code)" >&2
      exit 1 ;;
  esac
  if ! jq -e '.status == "ok"' "$out" >/dev/null 2>&1; then
    echo "Technitium refused the request: $(jq -r '.status + ": " + (.errorMessage // "")' "$out" 2>/dev/null || echo 'unparseable response')" >&2
    exit 1
  fi
}

# --- login: the token goes into a header file, never on argv ----------------------------------------
call_api "$TMP/login.json" -X POST "$URL/api/user/login" \
  --data-urlencode "user=$ADMIN_USER" --data-urlencode "pass@$TMP/admin-pass"
rm -f "$TMP/admin-pass"
jq -r '"Authorization: Bearer " + .token' "$TMP/login.json" >"$TMP/headers"
rm -f "$TMP/login.json"
LOGGED_IN=1

call_api "$TMP/current.json" -H @"$TMP/headers" "$URL/api/admin/sso/get?includeGroups=true"
echo "--- SSO settings before (client secret masked by Technitium)"
jq '.response' "$TMP/current.json"

echo "--- SSO settings to apply"
jq -n --arg authority "$AUTHORITY" --arg id "$CLIENT_ID" --arg scopes "$SCOPES" --arg map "$GROUP_MAP" \
  '{ssoEnabled: true, ssoAuthority: $authority, ssoClientId: $id, ssoClientSecret: "<redacted>",
    ssoScopes: $scopes, ssoAllowSignup: true, ssoAllowSignupOnlyForMappedUsers: true, ssoGroupMap: $map}'

if [ "$DRY" = 1 ]; then
  echo "dry run: nothing sent"
  exit 0
fi

call_api "$TMP/set.json" -X POST -H @"$TMP/headers" "$URL/api/admin/sso/set" \
  --data-urlencode "ssoEnabled=true" \
  --data-urlencode "ssoAuthority=$AUTHORITY" \
  --data-urlencode "ssoClientId=$CLIENT_ID" \
  --data-urlencode "ssoClientSecret@$TMP/secret" \
  --data-urlencode "ssoScopes=$SCOPES" \
  --data-urlencode "ssoAllowSignup=true" \
  --data-urlencode "ssoAllowSignupOnlyForMappedUsers=true" \
  --data-urlencode "ssoGroupMap=$GROUP_MAP"

# The web service restarts after the response; the old session may be gone, so verification is best effort.
sleep 5
if curl -sS -o "$TMP/after.json" -H @"$TMP/headers" "$URL/api/admin/sso/get" 2>/dev/null \
    && jq -e --arg a "$AUTHORITY" '.status == "ok" and .response.ssoEnabled == true and .response.ssoAuthority == $a' \
      "$TMP/after.json" >/dev/null 2>&1; then
  echo "Technitium SSO on: \"Sign in with SSO\" at $URL (authority $AUTHORITY)."
else
  LOGGED_IN=0
  echo "Technitium SSO set; could not read it back (the web service restarts, sessions may reset)." >&2
  echo "Open $URL and look for the SSO button on the login page." >&2
fi
echo "Group \"authentik Admins\" maps to Administrators; the local admin login still works."
