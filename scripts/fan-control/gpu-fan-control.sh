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
#   - A fan that stops below 100% (tach under STALL_RPM) gets 100% at once, and from then on never less than 10
#     points above the duty it stopped at, until a restart. So a curve floor set too low costs noise, not cooling.
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
#   STALL_RPM     tach reading below which a fan under 100% counts as stopped (default 300; 0 = no check)
#   TEXTFILE      optional; a .prom file for node-exporter's textfile collector, rewritten every interval with
#                 the duty, the reading, the header's fan rpm and the state (empty = off)
#
# Usage: gpu-fan-control run|failsafe|release|check|curve <temp>
set -euo pipefail

conf="${GPU_FAN_CONTROL_CONF:-/etc/default/gpu-fan-control}"
if [ -r "$conf" ]; then
  # shellcheck source=/dev/null
  . "$conf"
fi

CURVE="${CURVE:-45:35 55:45 62:60 67:85 70:100}"
INTERVAL="${INTERVAL:-5}"
STALE_AFTER="${STALE_AFTER:-30}"
STEP_DOWN="${STEP_DOWN:-5}"
STALL_RPM="${STALL_RPM:-300}"
METRIC="${METRIC:-nvidia_smi_temperature_gpu}"
SYSFS_ROOT="${SYSFS_ROOT:-/sys/class/hwmon}"
STATE_DIR="${STATE_DIR:-/run/gpu-fan-control}"
TEXTFILE="${TEXTFILE:-}"

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

# Sets pwm and pwm_enable to the header's files; fails if they are not there. fan_input is the header's tachometer
# (same number on nct67xx and it87 chips); it may be missing, and only the metrics read it.
locate_pwm() {
  local hw
  hw="$(find_hwmon)" || die "no hwmon chip named '$HWMON_NAME' under $SYSFS_ROOT (module loaded? see the runbook)"
  pwm="$hw/pwm$PWM_CHANNEL"
  pwm_enable="${pwm}_enable"
  fan_input="$hw/fan${PWM_CHANNEL}_input"
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

# The header's fan speed in rpm. Fails when the chip has no tachometer for it or reads garbage.
fan_rpm() {
  local r
  [ -r "$fan_input" ] && r="$(cat "$fan_input" 2>/dev/null)" && [[ "$r" =~ ^[0-9]+$ ]] && printf '%s\n' "$r"
}

# Writes TEXTFILE for node-exporter: state ok|holding|stale|stalled|failsafe, duty, temperature ("?" = none). Renamed into
# place, so a scrape never sees half a file (the collector skips names not ending in .prom). Never fails the caller.
write_metrics() {
  [ -n "$TEXTFILE" ] || return 0
  local state="$1" duty="$2" temp="$3" tmp="$TEXTFILE.$$" s rpm
  {
    printf '# HELP gpu_fan_control_duty_percent Duty the controller set on the GPU fan header.\n'
    printf '# TYPE gpu_fan_control_duty_percent gauge\ngpu_fan_control_duty_percent %s\n' "$duty"
    if [ "$temp" != "?" ]; then
      printf '# HELP gpu_fan_control_gpu_temperature_celsius GPU temperature of the last reading.\n'
      printf '# TYPE gpu_fan_control_gpu_temperature_celsius gauge\ngpu_fan_control_gpu_temperature_celsius %s\n' "$temp"
    fi
    if rpm="$(fan_rpm)"; then
      printf '# HELP gpu_fan_control_fan_rpm Speed of the fan on the controlled header.\n'
      printf '# TYPE gpu_fan_control_fan_rpm gauge\ngpu_fan_control_fan_rpm %s\n' "$rpm"
    fi
    printf '# HELP gpu_fan_control_state 1 for the state the controller is in.\n# TYPE gpu_fan_control_state gauge\n'
    for s in ok holding stale stalled failsafe; do
      printf 'gpu_fan_control_state{state="%s"} %d\n' "$s" "$([ "$s" = "$state" ] && echo 1 || echo 0)"
    done
    if [ -n "${stalls:-}" ]; then
      printf '# HELP gpu_fan_control_stalls_total Times the fan stopped below 100%% since the controller started.\n'
      printf '# TYPE gpu_fan_control_stalls_total counter\ngpu_fan_control_stalls_total %s\n' "$stalls"
      printf '# HELP gpu_fan_control_min_duty_percent Lowest duty the controller allows itself after stalls.\n'
      printf '# TYPE gpu_fan_control_min_duty_percent gauge\ngpu_fan_control_min_duty_percent %s\n' "$min_duty"
    fi
    if [ -n "${last_reading:-}" ]; then
      printf '# HELP gpu_fan_control_last_reading_timestamp_seconds When the exporter last answered.\n'
      printf '# TYPE gpu_fan_control_last_reading_timestamp_seconds gauge\n'
      printf 'gpu_fan_control_last_reading_timestamp_seconds %s\n' "$last_reading"
    fi
    printf '# HELP gpu_fan_control_updated_timestamp_seconds When the controller last wrote this file.\n'
    printf '# TYPE gpu_fan_control_updated_timestamp_seconds gauge\ngpu_fan_control_updated_timestamp_seconds %s\n' "$EPOCHSECONDS"
  } > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$TEXTFILE" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

# From run's stop trap the header is already located: systemd keeps sending SIGTERM to every new process in the
# unit's cgroup while it stops it, so looking the chip up again could lose a `cat` and fail. ExecStopPost runs it
# again from a fresh process either way.
failsafe() {
  if [ -z "${pwm:-}" ]; then
    need_config
    locate_pwm
  fi
  echo 1 > "$pwm_enable"
  echo 255 > "$pwm"
  write_metrics failsafe 100 "?" || true
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
  [ -z "$TEXTFILE" ] || rm -f -- "$TEXTFILE"
}

check() {
  need_config
  locate_pwm
  log "pwm:      $pwm = $(cat "$pwm") (enable $(cat "$pwm_enable"))"
  local rpm
  if rpm="$(fan_rpm)"; then log "fan:      $fan_input = $rpm rpm"; else log "fan:      no tachometer at $fan_input; no stall check"; fi
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

  local current=100 target t state last_state="" last_logged=-100 last_ok="$EPOCHSECONDS" last_reading=""
  local rpm stalls=0 min_duty=0
  set_percent 100
  log "started: $pwm, curve $CURVE, reading $EXPORTER_URL"
  while :; do
    if t="$(read_temp)"; then
      last_ok="$EPOCHSECONDS"
      last_reading="$EPOCHSECONDS"
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
    # The tach shows how the fan took last interval's duty. Full speed is never a stall: a dead fan there has
    # nothing better to fall back to, and the GpuFanStalled alert reports it.
    if ((STALL_RPM > 0 && current < 100)) && rpm="$(fan_rpm)" && ((rpm < STALL_RPM)); then
      stalls=$((stalls + 1))
      min_duty=$((current + 10 > 100 ? 100 : current + 10))
      log "stalled: fan ${rpm} rpm at ${current}%; 100% now, no lower than ${min_duty}% until a restart"
      target=100
      state="stalled"
    fi
    if ((target < min_duty)); then
      target="$min_duty"
    fi
    if ((target < current - STEP_DOWN)); then
      target=$((current - STEP_DOWN))
    fi
    set_percent "$target"
    write_metrics "$state" "$target" "$t" || true
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
