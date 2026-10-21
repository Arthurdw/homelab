#!/usr/bin/env bash
# Self-test for the backup alerting path, with no network and no host changes.
#
#   1. backup-alert.sh against local SMTP sinks (test/smtp-sink.py) with a throwaway self-signed cert:
#      it must deliver over smtps and STARTTLS with a netrc login, and must refuse a bad login, an
#      untrusted cert, a server without TLS, and missing settings.
#   2. systemd-analyze verify on copies of systemd/*, with ExecStart pointed at stubs, so unit syntax,
#      OnFailure= targets and timer calendars are checked without installing anything.
#
# Usage: scripts/backup/test/alert-selftest.sh      (needs bash, curl, openssl, python3, systemd-analyze)
#   ALERT_TEST_PORT_BASE  first of three localhost ports to listen on (default 22460)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
backup="$(dirname "$here")"
base="${ALERT_TEST_PORT_BASE:-22460}"
p_smtps=$base p_starttls=$((base + 1)) p_plain=$((base + 2))

for c in curl openssl python3 systemd-analyze; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

w="$(mktemp -d)"
pids=()
cleanup() { [ ${#pids[@]} -eq 0 ] || kill "${pids[@]}" 2>/dev/null || true; rm -rf -- "$w"; }
trap cleanup EXIT

fails=0
ok()   { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# --- 1. SMTP --------------------------------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -keyout "$w/key.pem" -out "$w/cert.pem" 2>/dev/null
# A second, unrelated cert: trusting only it must make the sink's cert fail verification.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=other \
  -keyout "$w/other-key.pem" -out "$w/other.pem" 2>/dev/null

for m in smtps starttls plain; do
  port_var="p_$m"
  mkdir -p "$w/$m"
  python3 -I "$here/smtp-sink.py" "${!port_var}" "$m" "$w/cert.pem" "$w/key.pem" "$w/$m" \
    alertuser selftest-pass &
  pids+=($!)
done
for port in "$p_smtps" "$p_starttls" "$p_plain"; do
  for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done
done

printf 'machine localhost login alertuser password selftest-pass\n' > "$w/good.netrc"
printf 'machine localhost login alertuser password wrong\n' > "$w/bad.netrc"
chmod 600 "$w"/*.netrc

unit=homelab-selftest.service
# Runs backup-alert.sh with the given extra env; echoes curl's exit code.
send() {
  env CURL_CA_BUNDLE="$w/cert.pem" ALERT_MAIL_FROM=backup@lab.test \
    ALERT_MAIL_TO="a@lab.test b@lab.test" ALERT_NETRC_FILE="$w/good.netrc" "$@" \
    bash "$backup/backup-alert.sh" "$unit" >"$w/out" 2>&1 && echo 0 || echo $?
}
expect() {  # expect <name> <rc> <env...>
  local name="$1" want="$2" got; shift 2
  got="$(send "$@")"
  if [ "$got" = "$want" ]; then ok "$name (rc=$got)"; else fail "$name: rc=$got, want $want: $(cat "$w/out")"; fi
}

expect "smtps delivers"           0  ALERT_SMTP_URL="smtps://localhost:$p_smtps"
expect "STARTTLS delivers"        0  ALERT_SMTP_URL="smtp://localhost:$p_starttls"
expect "bad login refused"        67 ALERT_SMTP_URL="smtps://localhost:$p_smtps" ALERT_NETRC_FILE="$w/bad.netrc"
expect "untrusted cert refused"   60 ALERT_SMTP_URL="smtps://localhost:$p_smtps" CURL_CA_BUNDLE="$w/other.pem"
expect "server without TLS refused" 64 ALERT_SMTP_URL="smtp://localhost:$p_plain"
expect "missing URL refused"      1  ALERT_SMTP_URL=

check() {  # check <name> <command...>: ok when the command succeeds
  local name="$1"; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
for m in smtps starttls; do
  msg="$w/$m/msg-1.eml"
  if [ ! -f "$msg" ]; then fail "$m: no message received"; continue; fi
  check "$m: envelope has sender and both recipients" grep -q \
    '^X-Sink-Envelope: MAIL FROM:<backup@lab.test>.*RCPT TO:<a@lab.test>.*RCPT TO:<b@lab.test>' "$msg"
  check "$m: To header comma-separated" grep -qx 'To: a@lab.test, b@lab.test' "$msg"
  check "$m: subject" grep -q "^Subject: \[homelab\] $unit failed on " "$msg"
  check "$m: body names the unit" grep -q "^Unit: *$unit" "$msg"
done
check "STARTTLS upgraded before AUTH" grep -q '^tls=True authed=True' "$w/starttls/sessions.log"
check "nothing sent in clear" test ! -e "$w/plain/msg-1.eml"

# --- 2. systemd units -----------------------------------------------------------------------------
mkdir -p "$w/units" "$w/bin"
for f in "$backup"/systemd/*; do
  sed "s#/usr/local/bin/#$w/bin/#g" "$f" > "$w/units/$(basename "$f")"
done
grep -ho "$w/bin/[a-z-]*" "$w"/units/* | sort -u | while read -r b; do
  printf '#!/bin/sh\n' > "$b"; chmod +x "$b"
done
if (cd "$w/units" && SYSTEMD_UNIT_PATH="$w/units:" systemd-analyze verify --man=no \
      ./*.service ./*.timer homelab-backup-alert@"$unit") >"$w/out" 2>&1; then
  ok "systemd-analyze verify ($(find "$w/units" -type f | wc -l) units)"
else
  fail "systemd-analyze verify: $(cat "$w/out")"
fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
