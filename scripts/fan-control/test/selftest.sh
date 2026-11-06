#!/usr/bin/env bash
# Self-test for the GPU fan controller and the BIOS fan curves, with no network and no host changes.
#
#   1. gpu-fan-control.sh against a fake /sys/class/hwmon and a file:// metrics page: the curve, `check`,
#      the run loop (curve duty, the node-exporter textfile, the stall guard, the fan stop and restart, 100% on
#      stale readings, 100% on SIGTERM) and `release`.
#   2. systemd-analyze verify on copies of both units, with their paths pointed at stubs.
#   3. fan-curves.sh against a fake nct6793 with the BIOS's "Full Speed" curve: the plan checks, `apply` (the
#      points, the floor, the mode, the critical point left alone, the saved boot values), a second apply, `show`
#      and `release`.
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
# wait_grep <file> <regex>: up to 10s for a line of the file to match.
wait_grep() {
  for _ in $(seq 100); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}

# next_write <file>: up to 10s for the file to be rewritten (the run loop rewrites the textfile once an interval).
next_write() {
  local m
  m="$(stat -c %.9Y "$1")"
  for _ in $(seq 100); do [ "$(stat -c %.9Y "$1" 2>/dev/null)" != "$m" ] && return 0; sleep 0.1; done
  return 1
}
temp() { sed -i "s/^\(nvidia_smi_temperature_gpu{uuid=\"GPU-1\"}\) .*/\1 $1/" "$w/metrics"; }

# --- 1. controller ---------------------------------------------------------------------------------
# hwmon0 is a decoy; hwmon3 is the Super I/O chip, its header in the BIOS's automatic mode (5).
mkdir -p "$w/sys/hwmon0" "$w/sys/hwmon3" "$w/state"
echo coretemp > "$w/sys/hwmon0/name"
echo nct6798 > "$w/sys/hwmon3/name"
echo 128 > "$w/sys/hwmon3/pwm2"
echo 5 > "$w/sys/hwmon3/pwm2_enable"
echo 1200 > "$w/sys/hwmon3/fan2_input"
pwm="$w/sys/hwmon3/pwm2"
fan_input="$w/sys/hwmon3/fan2_input"
prom="$w/gpu-fan-control.prom"
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
STALL_RPM="300"
TEXTFILE="$prom"
EOF
export GPU_FAN_CONTROL_CONF="$w/conf" SYSFS_ROOT="$w/sys" STATE_DIR="$w/state"
ctl() { bash "$fan/gpu-fan-control.sh" "$@"; }

for tp in 20:30 35:30 42.5:38 60:65 75:100 90:100; do
  check "curve ${tp%%:*}°C -> ${tp##*:}%" test "$(ctl curve "${tp%%:*}")" = "${tp##*:}"
done
# The shipped default: a 35% floor (poseidon's fan needs 30% to start), 100% from 70°C (the PETG duct, docs/decisions.md §3.8).
for tp in 30:35 45:35 50:40 55:45 70:100 80:100; do
  check "default curve ${tp%%:*}°C -> ${tp##*:}%" \
    test "$(GPU_FAN_CONTROL_CONF=/dev/null ctl curve "${tp%%:*}")" = "${tp##*:}"
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
check "textfile: duty" wait_grep "$prom" '^gpu_fan_control_duty_percent 35$'
check "textfile: temperature" wait_grep "$prom" '^gpu_fan_control_gpu_temperature_celsius 40$'
check "textfile: fan rpm" wait_grep "$prom" '^gpu_fan_control_fan_rpm 1200$'
check "textfile: state ok" wait_grep "$prom" '^gpu_fan_control_state{state="ok"} 1$'
# The fan stops at 35%: 100% at once, then never under 45% = (45 * 255 + 50) / 100 = 115.
echo 0 > "$fan_input"
check "stall: 100% when the fan stops" wait_for "$pwm" 255
echo 1200 > "$fan_input"
check "stall: floor raised to 45%" wait_for "$pwm" 115
check "stall: logged" grep -q '^stalled: fan 0 rpm at 35%' "$w/run.log"
check "textfile: stalls counted" wait_grep "$prom" '^gpu_fan_control_stalls_total 1$'
# Stop at 38°C (the default STOP_AT), past the 45% stall floor and STEP_DOWN; a still tach is no stall then.
temp 38
check "off: duty 0 at STOP_AT" wait_for "$pwm" 0
echo 0 > "$fan_input"
next_write "$prom" && next_write "$prom"
check "off: no stall while stopped" grep -q '^gpu_fan_control_stalls_total 1$' "$prom"
check "off: state stays ok" grep -q '^gpu_fan_control_state{state="ok"} 1$' "$prom"
temp 49
next_write "$prom" && next_write "$prom"
check "off: still 0 below START_AT" test "$(cat "$pwm")" = 0
# Back on at 50°C (curve 45%). The tach stays at 0 for the interval after the start: the spin-up grace.
temp 50
check "off: back on the curve at START_AT" wait_for "$pwm" 115
wait_grep "$prom" '^gpu_fan_control_duty_percent 45$' && next_write "$prom"
echo 1200 > "$fan_input"
next_write "$prom" && next_write "$prom"
check "off: no stall while spinning up" grep -q '^gpu_fan_control_stalls_total 1$' "$prom"
check "off: logged" grep -q '^ok: gpu 38°C, fan 0%' "$w/run.log"
rm "$w/metrics"
check "run: 100% once readings are stale" wait_for "$pwm" 255
check "textfile: state stale" wait_grep "$prom" '^gpu_fan_control_state{state="stale"} 1$'
echo 30 > "$pwm"
kill -TERM "$pid"
wait "$pid" 2>/dev/null || true
pid=""
check "run: 100% on SIGTERM" test "$(cat "$pwm")" = 255
check "run: logged the stale switch" grep -q '^stale: ' "$w/run.log"
check "textfile: state failsafe after a stop" grep -q '^gpu_fan_control_state{state="failsafe"} 1$' "$prom"

ctl release > /dev/null
check "release: firmware mode restored" test "$(cat "$pwm"_enable)" = 5
check "release: saved mode removed" test ! -e "$w/state/enable-nct6798-2"
check "release: textfile removed" test ! -e "$prom"
ctl release > /dev/null
check "release without a saved mode: 100% in manual" test "$(cat "$pwm")-$(cat "$pwm"_enable)" = 255-1

# --- 2. systemd unit --------------------------------------------------------------------------------
mkdir -p "$w/units" "$w/bin"
for u in gpu-fan-control fan-curves; do
  sed "s#/usr/local/sbin/#$w/bin/#g" "$fan/$u.service" > "$w/units/$u.service"
  printf '#!/bin/sh\n' > "$w/bin/$u"
  chmod +x "$w/bin/$u"
  if (cd "$w/units" && SYSTEMD_UNIT_PATH="$w/units:" systemd-analyze verify --man=no \
        "./$u.service") >"$w/out" 2>&1; then
    ok "systemd-analyze verify $u"
  else
    fail "systemd-analyze verify $u: $(cat "$w/out")"
  fi
done

# --- 3. BIOS fan curves -----------------------------------------------------------------------------
# hwmon5 is an nct6793 with 5 auto points per header, the BIOS's "Full Speed" on pwm2 and a sane curve on pwm1.
cw="$w/curves"
c="$cw/sys/hwmon5"
mkdir -p "$c" "$cw/state"
echo nct6793 > "$c/name"
bios() {  # bios <channel> <temp:pwm x5>: what the BIOS writes at power-on
  local ch="$1" i=1 p; shift
  for p in "$@"; do
    echo "$((${p%%:*} * 1000))" > "$c/pwm${ch}_auto_point${i}_temp"; echo "${p##*:}" > "$c/pwm${ch}_auto_point${i}_pwm"
    i=$((i + 1))
  done
  echo 5 > "$c/pwm${ch}_enable"; echo 1 > "$c/pwm${ch}_floor"; echo 255 > "$c/pwm$ch"; echo 2440 > "$c/fan${ch}_input"
}
bios 2 20:255 50:255 65:255 75:255 100:255
bios 1 20:51 65:178 70:255 70:255 100:255
curves() {  # curves <CURVE_2> <command>: the script with a config holding only pwm2
  printf 'HWMON_NAME=nct6793\nCHANNELS="2"\nCURVE_2="%s"\nWAIT=0\n' "$1" > "$cw/conf"
  FAN_CURVES_CONF="$cw/conf" SYSFS_ROOT="$cw/sys" STATE_DIR="$cw/state" "$fan/fan-curves.sh" "$2"
}
pts2() { for i in 1 2 3 4 5; do printf '%s:%s ' "$(cat "$c/pwm2_auto_point${i}_temp")" "$(cat "$c/pwm2_auto_point${i}_pwm")"; done; }
full="$(pts2)"

refuses() {  # refuses <name> <CURVE_2>: ok when apply fails with the error it should
  local name="$1" want="$3"
  if curves "$2" apply > /dev/null 2> "$cw/err"; then fail "$name: apply succeeded"
  elif ! grep -q -- "$want" "$cw/err"; then fail "$name: $(cat "$cw/err")"
  else ok "$name"; fi
}
refuses "curves: refuses 5 points (the 5th is critical)" "10:10 20:20 30:30 40:40 50:50" "1 to 4 points"
refuses "curves: refuses descending temperatures" "50:30 40:40" "must ascend"
refuses "curves: refuses a percent above 100" "50:130" "out of range"
refuses "curves: refuses a point that is not temp:percent" "50-30" "not temp:percent"
echo 70000 > "$c/pwm2_auto_point5_temp"
refuses "curves: refuses a point above the critical temperature" "20:30 75:100" "critical point"
echo 100000 > "$c/pwm2_auto_point5_temp"
mkdir -p "$cw/sys/hwmon2" && echo nct6793 > "$cw/sys/hwmon2/name" && touch "$cw/sys/hwmon2/pwm2_enable"
refuses "curves: refuses a chip without the header's auto points" "50:30" "no automatic curve"
rm -rf "$cw/sys/hwmon2"
check "curves: a refused plan writes nothing" test "$(pts2)" = "$full"
check "curves: nothing saved before a write" test ! -e "$cw/state/nct6793-pwm2"

if curves "20:30 50:40 65:75 75:100" apply > "$cw/apply.log" 2>&1; then ok "curves: apply"; else fail "curves: apply: $(cat "$cw/apply.log")"; fi
check "curves: points written" test "$(pts2)" = "20000:77 50000:102 65000:191 75000:255 100000:255 "
check "curves: floor at the first point" test "$(cat "$c/pwm2_floor")" = 77
check "curves: still automatic" test "$(cat "$c/pwm2_enable")" = 5
check "curves: pwm1 not touched" test "$(cat "$c/pwm1_auto_point1_pwm")-$(cat "$c/pwm1_floor")" = 51-1
check "curves: boot values saved" grep -q '^pwm2_auto_point1_pwm 255$' "$cw/state/nct6793-pwm2"
check "curves: logged the curve" grep -q '^pwm2: 20°C:30% 50°C:40% 65°C:75% 75°C:100% (critical 100°C) mode 5' "$cw/apply.log"

echo 1 > "$c/pwm2_enable"
if curves "30:25 60:60" apply > /dev/null; then ok "curves: a short curve applies"; else fail "curves: a short curve applies"; fi
check "curves: short curve written" test "$(pts2)" = "30000:64 60000:153 60000:153 60000:153 100000:255 "
check "curves: back to automatic from manual" test "$(cat "$c/pwm2_enable")" = 5
check "curves: second apply keeps the boot values" grep -q '^pwm2_auto_point1_pwm 255$' "$cw/state/nct6793-pwm2"
check "curves: show" grep -q "^pwm2: 30°C:25% 60°C:60% 60°C:60% 60°C:60% (critical 100°C) mode 5, now 100% 2440 rpm$" <(curves "30:25 60:60" show)

if curves "30:25 60:60" release > /dev/null; then ok "curves: release"; else fail "curves: release"; fi
check "curves: release restored the BIOS curve" test "$(pts2)" = "$full"
check "curves: release restored floor and mode" test "$(cat "$c/pwm2_floor")-$(cat "$c/pwm2_enable")" = 1-5
check "curves: release removed the saved values" test ! -e "$cw/state/nct6793-pwm2"
check "curves: release without saved values" grep -q "nothing saved" <(curves "30:25" release)

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
