#!/usr/bin/env bash
# GPU fan controller for poseidon, the Proxmox host. Drives one motherboard fan header from the Tesla P4's
# temperature. See docs/runbooks/gpu-fan-control.md.
#
# The P4 is passive and passed through to talos-wk-1, so the host cannot read its temperature: it fetches
# the reading from the in-cluster exporter (kubernetes/infrastructure/nvidia-device-plugin/gpu-exporter.yaml)
# and sets the header's PWM duty through the Super I/O chip's hwmon driver (nct6775, it87, ...).
#
# Fail-safe rules:
#   - It starts at 100% and only steps down once it has a reading.
#   - No reading for STALE_AFTER seconds (exporter down, VM off, network) means 100%.
#   - It speeds up at once and slows down by at most STEP_DOWN percent per INTERVAL.
#   - On any stop or crash, the unit's ExecStopPost runs `failsafe`: 100%, still in manual mode.
#   - `release` (run by OpenTofu on uninstall) hands the header back to the BIOS mode saved at start.
#
# Installed by OpenTofu (infrastructure/environments/homelab/proxmox/fan-control.tf) as
# /usr/local/sbin/gpu-fan-control, configured by /etc/default/gpu-fan-control:
#   HWMON_NAME    hwmon chip name, as in /sys/class/hwmon/hwmon*/name (e.g. nct6798). Found by name
#                 because the hwmonN numbers change between boots.
#   PWM_CHANNEL   the header's pwm number on that chip (pwm2 -> 2)
#   EXPORTER_URL  e.g. http://10.20.0.12:9835/metrics
#   CURVE         "temp:percent ..." in ascending temperature; linear in between, flat outside
#   INTERVAL      seconds between readings (default 5)
#   STALE_AFTER   seconds without a reading before going to 100% (default 30)
#   STEP_DOWN     largest decrease in percent per interval (default 5)
#
# Usage: gpu-fan-control run|failsafe|release|check|curve <temp>
set -euo pipefail

conf="${GPU_FAN_CONTROL_CONF:-/etc/default/gpu-fan-control}"
if [ -r "$conf" ]; then
  # shellcheck source=/dev/null
  . "$conf"
fi

CURVE="${CURVE:-35:30 50:45 60:65 70:90 75:100}"
INTERVAL="${INTERVAL:-5}"
STALE_AFTER="${STALE_AFTER:-30}"
STEP_DOWN="${STEP_DOWN:-5}"
METRIC="${METRIC:-nvidia_smi_temperature_gpu}"
SYSFS_ROOT="${SYSFS_ROOT:-/sys/class/hwmon}"
STATE_DIR="${STATE_DIR:-/run/gpu-fan-control}"

log() { printf '%s\n' "$*"; }
die() { printf 'gpu-fan-control: %s\n' "$*" >&2; exit 1; }

need_config() {
  : "${HWMON_NAME:?set HWMON_NAME in $conf}"
  : "${PWM_CHANNEL:?set PWM_CHANNEL in $conf}"
  : "${EXPORTER_URL:?set EXPORTER_URL in $conf}"
}

# The hwmon directory whose `name` is HWMON_NAME.
find_hwmon() {
  local d
  for d in "$SYSFS_ROOT"/hwmon*; do
    [ -r "$d/name" ] || continue
    if [ "$(cat "$d/name")" = "$HWMON_NAME" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# Sets pwm and pwm_enable to the header's files; fails if they are not there.
locate_pwm() {
  local hw
  hw="$(find_hwmon)" || die "no hwmon chip named '$HWMON_NAME' under $SYSFS_ROOT (module loaded? see the runbook)"
  pwm="$hw/pwm$PWM_CHANNEL"
  pwm_enable="${pwm}_enable"
  [ -w "$pwm" ] && [ -w "$pwm_enable" ] || die "$pwm or ${pwm}_enable missing or not writable"
}

# Fan percent for a temperature, from CURVE. Rounded up, so a fan never runs slower than the curve.
curve_percent() {
  awk -v t="$1" -v curve="$CURVE" 'BEGIN {
    n = split(curve, pts, " ")
    for (i = 1; i <= n; i++) { split(pts[i], kv, ":"); T[i] = kv[1] + 0; P[i] = kv[2] + 0 }
    if (t <= T[1]) p = P[1]
    else if (t >= T[n]) p = P[n]
    else for (i = 1; i < n; i++)
      if (t <= T[i + 1]) { p = P[i] + (P[i + 1] - P[i]) * (t - T[i]) / (T[i + 1] - T[i]); break }
    printf "%d\n", (p == int(p)) ? p : int(p) + 1
  }'
}

# The hottest GPU temperature the exporter reports. Fails on no answer, no metric or a non-number.
read_temp() {
  curl -fsS --max-time 3 "$EXPORTER_URL" 2>/dev/null | awk -v m="$METRIC" '
    index($0, m "{") == 1 || index($0, m " ") == 1 {
      line = $0
      if (index(line, "{")) sub(/^.*\}[ \t]+/, "", line); else sub(/^[^ \t]+[ \t]+/, "", line)
      split(line, f, " ")
      if (f[1] ~ /^[0-9]+(\.[0-9]+)?$/ && (max == "" || f[1] + 0 > max)) max = f[1] + 0
    }
    END { if (max == "") exit 1; print max }'
}

set_percent() {
  # Manual mode is re-asserted every time: firmware may take the header back (e.g. after a resume).
  [ "$(cat "$pwm_enable")" = 1 ] || echo 1 > "$pwm_enable"
  echo $((($1 * 255 + 50) / 100)) > "$pwm"
}

failsafe() {
  need_config
  locate_pwm
  echo 1 > "$pwm_enable"
  echo 255 > "$pwm"
  log "failsafe: $pwm at 100%"
}

release() {
  need_config
  locate_pwm
  local saved="$STATE_DIR/enable-$HWMON_NAME-$PWM_CHANNEL" mode
  if [ -s "$saved" ] && mode="$(cat "$saved")" && [ "$mode" != 1 ] && echo "$mode" > "$pwm_enable" 2>/dev/null; then
    log "release: $pwm_enable back to firmware mode $mode"
  else
    echo 1 > "$pwm_enable"
    echo 255 > "$pwm"
    log "release: no firmware mode to restore; $pwm left at 100%"
  fi
  rm -f -- "$saved"
}

check() {
  need_config
  locate_pwm
  log "pwm:      $pwm = $(cat "$pwm") (enable $(cat "$pwm_enable"))"
  local t
  if t="$(read_temp)"; then
    log "exporter: $EXPORTER_URL -> ${t}°C -> $(curve_percent "$t")%"
  else
    # Not an error: the exporter may not be up yet, and `run` copes with that by staying at 100%.
    log "exporter: no $METRIC from $EXPORTER_URL yet; the fan will run at 100% until there is"
  fi
}

run() {
  need_config
  locate_pwm
  mkdir -p "$STATE_DIR"
  # Saved once per boot (/run), so a restart after `failsafe` does not record our own manual mode.
  local saved="$STATE_DIR/enable-$HWMON_NAME-$PWM_CHANNEL"
  [ -s "$saved" ] || cat "$pwm_enable" > "$saved"
  trap 'failsafe; exit 0' INT TERM

  local current=100 target t state last_state="" last_logged=-100 last_ok="$EPOCHSECONDS"
  set_percent 100
  log "started: $pwm, curve $CURVE, reading $EXPORTER_URL"
  while :; do
    if t="$(read_temp)"; then
      last_ok="$EPOCHSECONDS"
      target="$(curve_percent "$t")"
      state="ok"
    elif ((EPOCHSECONDS - last_ok >= STALE_AFTER)); then
      t="?"
      target=100
      state="stale"
    else
      t="?"
      target="$current"
      state="holding"
    fi
    if ((target < current - STEP_DOWN)); then
      target=$((current - STEP_DOWN))
    fi
    set_percent "$target"
    if [ "$state" != "$last_state" ] || ((target - last_logged >= 10 || last_logged - target >= 10)); then
      log "$state: gpu ${t}°C, fan ${target}%"
      last_state="$state"
      last_logged="$target"
    fi
    current="$target"
    sleep "$INTERVAL" &
    wait $!
  done
}

case "${1:-}" in
  run) run ;;
  failsafe) failsafe ;;
  release) release ;;
  check) check ;;
  curve) [ -n "${2:-}" ] || die "usage: gpu-fan-control curve <temp>"; curve_percent "$2" ;;
  *) die "usage: gpu-fan-control run|failsafe|release|check|curve <temp>" ;;
esac
