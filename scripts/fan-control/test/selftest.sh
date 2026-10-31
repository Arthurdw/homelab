#!/usr/bin/env bash
# Self-test for the GPU fan controller, with no network and no host changes.
#
#   1. gpu-fan-control.sh against a fake /sys/class/hwmon and a file:// metrics page: the curve, `check`,
#      the run loop (curve duty, 100% on stale readings, 100% on SIGTERM) and `release`.
#   2. systemd-analyze verify on a copy of the unit, with its paths pointed at a stub.
#
# Usage: scripts/fan-control/test/selftest.sh      (needs bash, curl, systemd-analyze)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fan="$(dirname "$here")"

for c in curl systemd-analyze; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

w="$(mktemp -d)"
pid=""
cleanup() { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf -- "$w"; }
trap cleanup EXIT

fails=0
ok()   { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check() {  # check <name> <command...>: ok when the command succeeds
  local name="$1"; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
# wait_for <file> <value>: up to 10s for the file to hold the value.
wait_for() {
  for _ in $(seq 100); do [ "$(cat "$1" 2>/dev/null)" = "$2" ] && return 0; sleep 0.1; done
  return 1
}

# --- 1. controller ---------------------------------------------------------------------------------
# hwmon0 is a decoy; hwmon3 is the Super I/O chip, its header in the BIOS's automatic mode (5).
mkdir -p "$w/sys/hwmon0" "$w/sys/hwmon3" "$w/state"
echo coretemp > "$w/sys/hwmon0/name"
echo nct6798 > "$w/sys/hwmon3/name"
echo 128 > "$w/sys/hwmon3/pwm2"
echo 5 > "$w/sys/hwmon3/pwm2_enable"
pwm="$w/sys/hwmon3/pwm2"
cat > "$w/metrics" <<'EOF'
# HELP nvidia_smi_temperature_gpu temperature.gpu
# TYPE nvidia_smi_temperature_gpu gauge
nvidia_smi_temperature_gpu{uuid="GPU-1"} 40
nvidia_smi_temperature_memory{uuid="GPU-1"} 99
EOF

cat > "$w/conf" <<EOF
HWMON_NAME="nct6798"
PWM_CHANNEL="2"
EXPORTER_URL="file://$w/metrics"
CURVE="35:30 50:45 60:65 70:90 75:100"
INTERVAL="1"
STALE_AFTER="2"
STEP_DOWN="50"
EOF
export GPU_FAN_CONTROL_CONF="$w/conf" SYSFS_ROOT="$w/sys" STATE_DIR="$w/state"
ctl() { bash "$fan/gpu-fan-control.sh" "$@"; }

for tp in 20:30 35:30 42.5:38 60:65 75:100 90:100; do
  check "curve ${tp%%:*}°C -> ${tp##*:}%" test "$(ctl curve "${tp%%:*}")" = "${tp##*:}"
done
reads_exporter() { ctl check | grep -q '40°C -> 35%'; }
wrong_chip() { ! GPU_FAN_CONTROL_CONF=/dev/null HWMON_NAME=nct6799 PWM_CHANNEL=2 EXPORTER_URL="file://$w/metrics" ctl check 2>/dev/null; }
unknown_command() { ! ctl frobnicate 2>/dev/null; }
check "check finds the chip and reads the exporter" reads_exporter
check "check fails on a wrong chip name" wrong_chip
check "usage error on an unknown command" unknown_command

# Not through ctl: `ctl run &` would fork a subshell, and the SIGTERM below would hit it, not the script.
bash "$fan/gpu-fan-control.sh" run > "$w/run.log" 2>&1 &
pid=$!
# 40°C is 35% on the curve: (35 * 255 + 50) / 100 = 89.
check "run: header in manual mode" wait_for "$pwm"_enable 1
check "run: firmware mode saved" test "$(cat "$w/state/enable-nct6798-2")" = 5
check "run: duty follows the curve (35%)" wait_for "$pwm" 89
rm "$w/metrics"
check "run: 100% once readings are stale" wait_for "$pwm" 255
echo 30 > "$pwm"
kill -TERM "$pid"
wait "$pid" 2>/dev/null || true
pid=""
check "run: 100% on SIGTERM" test "$(cat "$pwm")" = 255
check "run: logged the stale switch" grep -q '^stale: ' "$w/run.log"

ctl release > /dev/null
check "release: firmware mode restored" test "$(cat "$pwm"_enable)" = 5
check "release: saved mode removed" test ! -e "$w/state/enable-nct6798-2"
ctl release > /dev/null
check "release without a saved mode: 100% in manual" test "$(cat "$pwm")-$(cat "$pwm"_enable)" = 255-1

# --- 2. systemd unit --------------------------------------------------------------------------------
mkdir -p "$w/units" "$w/bin"
sed "s#/usr/local/sbin/#$w/bin/#g" "$fan/gpu-fan-control.service" > "$w/units/gpu-fan-control.service"
printf '#!/bin/sh\n' > "$w/bin/gpu-fan-control"
chmod +x "$w/bin/gpu-fan-control"
if (cd "$w/units" && SYSTEMD_UNIT_PATH="$w/units:" systemd-analyze verify --man=no \
      ./gpu-fan-control.service) >"$w/out" 2>&1; then
  ok "systemd-analyze verify"
else
  fail "systemd-analyze verify: $(cat "$w/out")"
fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
