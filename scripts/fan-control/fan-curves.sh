#!/usr/bin/env bash
# BIOS fan curves for poseidon, the Proxmox host. Rewrites the Super I/O chip's own automatic curve (Smart Fan IV on
# nct67xx chips) for some fan headers at boot. See docs/runbooks/fan-curves.md.
#
# The chip keeps driving those headers from its temperature input (on poseidon the CPU's PECI reading). This only
# replaces the points of the curve the BIOS wrote, because the BIOS's own (e.g. "Full Speed", 100 % at every point)
# cannot be changed without a screen on the host. Nothing runs after boot: when this host hangs, the chip still
# follows the CPU temperature.
#
# Fail-safe rules:
#   - A header is only touched when it has the auto_point files; anything missing fails the run before any write.
#   - Points are written on a header the BIOS left in automatic mode, and the header is put (back) in mode 5.
#   - The floor (the duty below the first point) is set to the first point's duty, so the fan never drops under it.
#   - The last auto_point is the chip's critical temperature (100 % above it) and is never changed.
#   - Every write is read back; a mismatch fails the run (and the unit, and the OpenTofu apply).
#   - The values found at the first `apply` after boot are saved under STATE_DIR (/run: what the BIOS wrote);
#     `release` (run by OpenTofu on uninstall) puts them back.
#
# Installed by OpenTofu (infrastructure/environments/homelab/proxmox/fan-curves.tf) as /usr/local/sbin/fan-curves,
# configured by /etc/default/fan-curves:
#   HWMON_NAME   hwmon chip name, as in /sys/class/hwmon/hwmon*/name (e.g. nct6793)
#   CHANNELS     the headers' pwm numbers, space separated (pwm2 -> 2)
#   CURVE_<n>    for each channel: "temp:percent ..." in ascending temperature (°C, 0-100 %); the chip ramps
#                linearly between points. At most as many points as the chip has, without the critical one.
#   WAIT         seconds to wait for the chip at boot (the driver may still be loading; default 30)
#
# Usage: fan-curves apply|release|show
set -euo pipefail

conf="${FAN_CURVES_CONF:-/etc/default/fan-curves}"
if [ -r "$conf" ]; then
  # shellcheck source=/dev/null
  . "$conf"
fi

WAIT="${WAIT:-30}"
SYSFS_ROOT="${SYSFS_ROOT:-/sys/class/hwmon}"
STATE_DIR="${STATE_DIR:-/run/fan-curves}"

log() { printf '%s\n' "$*"; }
die() { printf 'fan-curves: %s\n' "$*" >&2; exit 1; }

need_config() {
  : "${HWMON_NAME:?set HWMON_NAME in $conf}"
  : "${CHANNELS:?set CHANNELS in $conf}"
}

# The hwmon directory whose `name` is HWMON_NAME, waiting up to WAIT seconds for it.
find_hwmon() {
  local d i
  for ((i = 0; i <= WAIT; i++)); do
    for d in "$SYSFS_ROOT"/hwmon*; do
      [ -r "$d/name" ] || continue
      if [ "$(cat "$d/name")" = "$HWMON_NAME" ]; then
        printf '%s\n' "$d"
        return 0
      fi
    done
    [ "$i" -lt "$WAIT" ] && sleep 1
  done
  return 1
}

# The number of auto points on a header, the critical one included (5 on nct6779 and later).
point_count() {
  local n=0
  while [ -e "$hw/pwm$1_auto_point$((n + 1))_pwm" ] && [ -e "$hw/pwm$1_auto_point$((n + 1))_temp" ]; do
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# The files that make up a header's curve, in the order they are saved and restored.
curve_files() {
  local c="$1" n="$2" i
  for ((i = 1; i < n; i++)); do printf '%s\n' "pwm${c}_auto_point${i}_temp" "pwm${c}_auto_point${i}_pwm"; done
  [ -e "$hw/pwm${c}_floor" ] && printf '%s\n' "pwm${c}_floor"
  printf '%s\n' "pwm${c}_enable"
}

# Writes a value and reads it back.
put() {
  echo "$2" > "$hw/$1"
  [ "$(cat "$hw/$1")" = "$2" ] || die "$hw/$1: wrote $2, reads $(cat "$hw/$1")"
}

# Checks every channel and its curve; sets the globals temps_<c>, duties_<c> and points_<c> for apply.
plan() {
  local c curve pts p t pc n i
  for c in $CHANNELS; do
    [[ "$c" =~ ^[0-9]+$ ]] || die "CHANNELS: '$c' is not a pwm number"
    curve="CURVE_$c"
    [ -n "${!curve:-}" ] || die "set $curve in $conf"
    [ -w "$hw/pwm${c}_enable" ] || die "$hw/pwm${c}_enable missing or not writable"
    n="$(point_count "$c")"
    [ "$n" -ge 2 ] || die "pwm$c has no automatic curve (auto_point files) on $HWMON_NAME"
    read -r -a pts <<< "${!curve}"
    [ "${#pts[@]}" -ge 1 ] && [ "${#pts[@]}" -lt "$n" ] || die "$curve: 1 to $((n - 1)) points on this chip, got ${#pts[@]}"
    local temps="" duties="" last=-1 lastd=0 crit
    for p in "${pts[@]}"; do
      [[ "$p" =~ ^([0-9]+):([0-9]+)$ ]] || die "$curve: '$p' is not temp:percent"
      t="$((10#${BASH_REMATCH[1]}))"; pc="$((10#${BASH_REMATCH[2]}))"
      [ "$t" -le 100 ] && [ "$pc" -le 100 ] || die "$curve: '$p' out of range (0-100 °C, 0-100 %)"
      [ "$t" -gt "$last" ] || die "$curve: temperatures must ascend"
      last="$t"; lastd="$(((pc * 255 + 50) / 100))"
      temps+="$((t * 1000)) "; duties+="$lastd "
    done
    crit="$(($(cat "$hw/pwm${c}_auto_point${n}_temp") / 1000))"
    [ "$last" -le "$crit" ] || die "$curve: ${last} °C is above the chip's critical point (${crit} °C)"
    # Fewer points than the chip has: the rest repeat the last one (the BIOS does the same, e.g. 70 °C twice).
    for ((i = ${#pts[@]}; i < n - 1; i++)); do
      temps+="$((last * 1000)) "; duties+="$lastd "
    done
    printf -v "temps_$c" '%s' "$temps"
    printf -v "duties_$c" '%s' "$duties"
    printf -v "points_$c" '%s' "$n"
  done
}

save() {  # save <channel> <points>: the values found, once per boot
  local f="$STATE_DIR/$HWMON_NAME-pwm$1" x
  [ -e "$f" ] && return 0
  mkdir -p "$STATE_DIR"
  for x in $(curve_files "$1" "$2"); do printf '%s %s\n' "$x" "$(cat "$hw/$x")"; done > "$f.tmp"
  mv "$f.tmp" "$f"
}

cmd_apply() {
  need_config
  hw="$(find_hwmon)" || die "no hwmon chip named '$HWMON_NAME' under $SYSFS_ROOT after ${WAIT}s (module loaded? see the runbook)"
  plan
  local c n i t d temps duties
  for c in $CHANNELS; do
    n="points_$c"; n="${!n}"
    temps="temps_$c"; read -r -a t <<< "${!temps}"
    duties="duties_$c"; read -r -a d <<< "${!duties}"
    save "$c" "$n"
    # Temperatures first, rising, then duties: the curve is never steeper than either the old or the new one.
    for ((i = 1; i < n; i++)); do put "pwm${c}_auto_point${i}_temp" "${t[i - 1]}"; done
    for ((i = 1; i < n; i++)); do put "pwm${c}_auto_point${i}_pwm" "${d[i - 1]}"; done
    [ -e "$hw/pwm${c}_floor" ] && put "pwm${c}_floor" "${d[0]}"
    [ "$(cat "$hw/pwm${c}_enable")" = 5 ] || put "pwm${c}_enable" 5
    log "pwm$c: $(cmd_show_one "$c" "$n")"
  done
}

cmd_release() {
  need_config
  hw="$(find_hwmon)" || die "no hwmon chip named '$HWMON_NAME' under $SYSFS_ROOT"
  local c f x v
  for c in $CHANNELS; do
    f="$STATE_DIR/$HWMON_NAME-pwm$c"
    if [ ! -r "$f" ]; then
      log "pwm$c: nothing saved this boot; it keeps its curve until the next boot, when the BIOS writes its own"
      continue
    fi
    while read -r x v; do echo "$v" > "$hw/$x"; done < "$f"
    rm -f "$f"
    log "pwm$c: restored the curve found at boot"
  done
}

cmd_show_one() {  # cmd_show_one <channel> <points>: "temp°C:percent% ... (crit X°C), mode M, now D% R rpm"
  local c="$1" n="$2" i out=""
  for ((i = 1; i <= n; i++)); do
    local t p
    t=$(($(cat "$hw/pwm${c}_auto_point${i}_temp") / 1000))
    p=$((($(cat "$hw/pwm${c}_auto_point${i}_pwm") * 100 + 127) / 255))
    if [ "$i" -lt "$n" ]; then out+="${t}°C:${p}% "; else out+="(critical ${t}°C) "; fi
  done
  out+="mode $(cat "$hw/pwm${c}_enable"), now $((($(cat "$hw/pwm$c") * 100 + 127) / 255))%"
  [ -r "$hw/fan${c}_input" ] && out+=" $(cat "$hw/fan${c}_input") rpm"
  printf '%s\n' "$out"
}

cmd_show() {
  need_config
  WAIT=0
  hw="$(find_hwmon)" || die "no hwmon chip named '$HWMON_NAME' under $SYSFS_ROOT"
  local c
  for c in $CHANNELS; do log "pwm$c: $(cmd_show_one "$c" "$(point_count "$c")")"; done
}

case "${1:-}" in
  apply) cmd_apply ;;
  release) cmd_release ;;
  show) cmd_show ;;
  *) die "usage: fan-curves apply|release|show" ;;
esac
