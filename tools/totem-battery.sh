#!/usr/bin/env bash
# Read TOTEM split-keyboard battery levels over BLE.
#
# ZMK exposes a standard Battery Service (0x180f) per half; with the central's
# BATTERY_LEVEL_PROXY/FETCHING config both show up under the one BLE device.
# BlueZ doesn't surface them via the Battery1 D-Bus interface here, so we read
# the GATT Battery Level characteristic (0x2a19) directly.
#
# Charging: stock ZMK advertises no charging flag over BLE. It *knows* whether a
# half is USB-powered (zmk_usb_is_powered(), what the nice_view battery widget
# draws a bolt from), but only implements the mandatory BAS characteristic
# 0x2a19; there is no BAS 1.1 Battery Level Status (0x2bed), and for a BLE split
# the peripheral's level reaches the central over standard BAS too, which has no
# room for a flag. Our ZMK fork adds CONFIG_ZMK_SPLIT_CHARGING_STATE, which
# publishes a one-byte bitfield on the vendor characteristic below:
#
#   bit 0     the central (right half)
#   bit 1     peripheral 0 (left half)
#
# When that characteristic is present we read it and report exactly. On stock
# firmware it is absent, and we fall back to *inferring*: remember the last
# reading per half in a state file and call a half "charging" once its
# percentage steps UP, until it steps back down (or goes stale). ZMK reports
# coarsely and only ~every 60s, so the fallback can lag by a couple of minutes.
#
# States: BlueZ's Device1.Connected tells us whether the keyboard is talking to
# this host at all (off / out of range / asleep / paired to another host all
# look the same from here). A single half reading 0 means "no report" — ZMK
# initialises the proxied level to 0 and only updates it on change (zmk#2972),
# so an absent peripheral half reads 0 until it checks in.
#
# Usage:
#   tools/totem-battery.sh [MAC]                 one-shot read
#   tools/totem-battery.sh --watch [SECS] [MAC]  poll until Ctrl-C (default 60s)
#   tools/totem-battery.sh --waybar [MAC]        one line of JSON for Waybar
#
# Waybar bar style: TOTEM_BAR_STYLE=blocks (default, one eighth-block glyph per
# half) or =gauge (a 4-cell L/R gauge, wider but easier to read exactly).
#
# Note: no `set -e` on purpose — a transient read failure must not abort the
# Waybar JSON output (it would blank the module).
set -uo pipefail

MODE=oneshot
INTERVAL=60
case "${1:-}" in
  --watch|-w) MODE=watch; shift
    case "${1:-}" in (''|*[!0-9]*) ;; (*) INTERVAL="$1"; shift ;; esac ;;
  --waybar)   MODE=waybar; shift ;;
esac
MAC="${1:-FC:CD:2B:30:B8:9B}"
# Find the device under whatever adapter it lives on. Hardcoding hci0 breaks
# the moment the keyboard is paired via a different controller (e.g. a USB
# dongle used in place of a flaky onboard one).
find_base() {
  local want="dev_${MAC//:/_}" found
  found=$(busctl tree org.bluez 2>/dev/null |
    grep -o "/org/bluez/hci[0-9]*/${want}" | head -1)
  printf '%s\n' "${found:-/org/bluez/hci0/${want}}"
}

BASE="$(find_base)"
ADAPTER="$(basename "$(dirname "$BASE")")"
ICON=""   # nerd-font keyboard glyph
BOLT="󱐋"    # nerd-font flash glyph, shown while a half is charging

# Thresholds and colours (matching the Waybar stylesheet palette).
WARN_PCT=50
CRIT_PCT=20
C_GOOD="#4ade80"
C_WARN="#fbbf24"
C_CRIT="#ff6b6b"
C_CHARGE="#38bdf8"
C_NONE="#6b7280"
DASH="─"     # placeholder bar for a half with no reading

# Vendor charging-state characteristic added by the ZMK fork (see header).
CHARGING_UUID="00000001-0f9c-4b7a-9e2d-6c1a5f3b8e40"

STATE="${XDG_RUNTIME_DIR:-/tmp}/totem-battery.state"
STALE_SECS=1800   # forget a sticky "charging" flag after this long unchanged

# Is the keyboard actually talking to this host? Prints one of:
#   connected   BLE link up, GATT should answer
#   asleep      known+paired but not connected (off, out of range, deep sleep,
#               or switched to another BT profile — indistinguishable from here)
#   unpaired    BlueZ has no such device object
#   bt-off      the adapter itself is down
conn_state() {
  local out
  out=$(busctl get-property org.bluez "$BASE" org.bluez.Device1 Connected 2>/dev/null)
  case "$out" in
    *true*)  echo connected; return ;;
    *false*) echo asleep;    return ;;
  esac
  out=$(busctl get-property org.bluez "/org/bluez/${ADAPTER}" org.bluez.Adapter1 Powered 2>/dev/null)
  case "$out" in
    *false*) echo bt-off ;;
    *true*)  echo unpaired ;;
    *)       echo bt-off ;;
  esac
}

# Map a GATT characteristic id to a physical half. The right half is the split
# central (SHIELD_TOTEM_RIGHT); ZMK registers its own battery service first
# (lower handle), the proxied peripheral after. If these ever look swapped after
# a re-flash, just swap the two ids below.
side_for() {
  case "$1" in
    char0011) echo "R" ;;   # central / right
    char0016) echo "L" ;;   # peripheral / left
    *)        echo "?" ;;
  esac
}

# List this device's GATT characteristics as "<path> <uuid>" lines.
#
# Deliberately NOT bluetoothctl: it registers a BlueZ AdvertisementMonitor on
# startup, which makes the controller run a BLE scan. Firing that from a Waybar
# poll steals radio time from connected devices -- the keyboard included --
# causing typing lag and dropped key-up events (the same reason
# ~/.config/waybar/scripts/bluetooth_status.sh avoids it). Asking the
# ObjectManager is a plain local D-Bus read: no monitor, no scan, no radio.
ATTRS=""
list_attrs() {
  [ -n "$ATTRS" ] || ATTRS=$(
    busctl --json=short call org.bluez / \
      org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null |
      BASE="$BASE" python3 -c '
import json, os, sys
base = os.environ["BASE"]
try:
    objs = json.load(sys.stdin)["data"][0]
except Exception:
    sys.exit(1)
for path, ifaces in objs.items():
    chrc = ifaces.get("org.bluez.GattCharacteristic1")
    if chrc and path.startswith(base + "/"):
        print(path, chrc["UUID"]["data"])
' 2>/dev/null
  )
  printf '%s\n' "$ATTRS"
}

# Populate parallel arrays SIDES[] (L/R), NAMES[] (char id), PCTS[] (number/"" ).
collect() {
  SIDES=(); NAMES=(); PCTS=()
  ATTRS=""   # re-read each pass, so --watch survives a re-flash moving handles
  local paths p out pct
  mapfile -t paths < <(list_attrs | awk 'tolower($2) ~ /^00002a19-/ {print $1}')
  for p in "${paths[@]:-}"; do
    [ -z "$p" ] && continue
    # ReadValue returns "ay <count> <byte ...>"; the byte is the percentage.
    out=$(busctl call org.bluez "$p" org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null) \
      || out=$(busctl call org.bluez "$p" org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null) # 0x0e is often transient
    pct=$(printf '%s\n' "$out" | grep -o '[0-9]*$')
    # A proxied level of 0 means "never reported" far more often than "flat":
    # ZMK seeds it to 0 and only pushes on change, so a half that hasn't
    # checked in since boot sits at 0. Treat it as unknown (see zmk#2972).
    [ "$pct" = 0 ] && pct=""
    SIDES+=("$(side_for "${p##*/}")"); NAMES+=("${p##*/}"); PCTS+=("$pct")
  done
}

# Compare this reading against the state file to guess whether a half is
# charging. State lines are "SIDE PCT CHARGING LAST_CHANGE_EPOCH".
# Sets CHARGING[side] to 1/0 and rewrites the state file.
# Read the fork's charging bitfield. Prints the byte, or fails if the
# characteristic isn't there (i.e. the keyboard is on stock ZMK).
read_charging_bits() {
  local path out
  path=$(list_attrs | awk -v u="$CHARGING_UUID" 'tolower($2) == u {print $1}' | head -1)
  [ -n "$path" ] || return 1
  out=$(busctl call org.bluez "$path" org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null) \
    || return 1
  printf '%s\n' "$out" | grep -o '[0-9]*$'
}

declare -A CHARGING=()
CHARGING_SOURCE=inferred
update_charging() {
  CHARGING=()

  # Prefer the firmware's own answer; fall back to guessing from level changes.
  local bits
  if bits=$(read_charging_bits) && [ -n "$bits" ]; then
    CHARGING_SOURCE=firmware
    CHARGING[R]=$(((bits & 1) ? 1 : 0))  # bit 0: central  = right half
    CHARGING[L]=$(((bits & 2) ? 1 : 0))  # bit 1: periph 0 = left half
    return
  fi
  CHARGING_SOURCE=inferred

  local -A old_pct=() old_chg=() old_ts=()
  local side pct chg ts now; now=$(date +%s)
  if [ -r "$STATE" ]; then
    while read -r side pct chg ts; do
      [ -n "${side:-}" ] || continue
      old_pct[$side]="$pct"; old_chg[$side]="$chg"; old_ts[$side]="$ts"
    done < "$STATE"
  fi

  local i out=""
  for i in "${!PCTS[@]}"; do
    side="${SIDES[$i]}"; pct="${PCTS[$i]}"
    [ -n "$pct" ] || continue
    if [ -z "${old_pct[$side]:-}" ]; then
      chg=0; ts=$now                                  # first ever reading
    elif [ "$pct" -gt "${old_pct[$side]}" ]; then
      chg=1; ts=$now                                  # went up -> charging
    elif [ "$pct" -lt "${old_pct[$side]}" ]; then
      chg=0; ts=$now                                  # went down -> on battery
    else
      chg="${old_chg[$side]:-0}"; ts="${old_ts[$side]:-$now}"
      # A flat reading tells us nothing; drop a stale charging flag eventually
      # (e.g. it hit 100% and stopped moving, or the cable came out).
      [ $((now - ts)) -ge "$STALE_SECS" ] && { chg=0; ts=$now; }
    fi
    CHARGING[$side]="$chg"
    out+="$side $pct $chg $ts"$'\n'
  done
  [ -n "$out" ] && printf '%s' "$out" > "$STATE" 2>/dev/null
}

colour_for() {
  local pct="$1" side="$2"
  [ -n "$pct" ] || { echo "$C_NONE"; return; }
  [ "${CHARGING[$side]:-0}" = 1 ] && { echo "$C_CHARGE"; return; }
  if   [ "$pct" -lt "$CRIT_PCT" ]; then echo "$C_CRIT"
  elif [ "$pct" -lt "$WARN_PCT" ]; then echo "$C_WARN"
  else echo "$C_GOOD"; fi
}

# One eighth-block glyph whose height tracks the percentage.
block_for() {
  local pct="${1:-}" blocks=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █) idx
  [ -n "$pct" ] || { echo "─"; return; }
  idx=$(( pct * 8 / 101 ))
  echo "${blocks[$idx]}"
}

# A 4-cell filled/empty gauge, e.g. "███░".
gauge_for() {
  local pct="${1:-}" cells=4 filled i out=""
  [ -n "$pct" ] || { echo "────"; return; }
  filled=$(( (pct * cells + 50) / 100 ))
  # never round a non-empty half down to a completely empty bar
  [ "$filled" -eq 0 ] && [ "$pct" -gt 0 ] && filled=1
  for ((i = 0; i < cells; i++)); do
    if [ "$i" -lt "$filled" ]; then out+="█"; else out+="░"; fi
  done
  echo "$out"
}

# Human-readable label for a non-connected state.
state_note() {
  case "$1" in
    asleep)   echo "not connected — powered off, asleep, out of range, or on another BT profile" ;;
    unpaired) echo "not paired with this host" ;;
    bt-off)   echo "Bluetooth adapter is off" ;;
    *)        echo "connected, but no battery reading (GATT read failed)" ;;
  esac
}

print_human() {
  local state; state=$(conn_state)
  if [ "$state" != connected ]; then
    echo "TOTEM: $(state_note "$state")"
    return 1
  fi
  collect
  update_charging
  local i side word flag
  local -A pct_of=()
  for i in "${!PCTS[@]}"; do pct_of[${SIDES[$i]}]="${PCTS[$i]}"; done
  if [ "${#PCTS[@]}" -eq 0 ]; then echo "TOTEM: $(state_note read-failed)"; return 1; fi
  for side in L R; do
    case "$side" in L) word=Left ;; R) word=Right ;; esac
    if [ -z "${pct_of[$side]:-}" ]; then
      printf '%-5s: no report (half off, asleep, or flat)\n' "$word"
    else
      flag=""; [ "${CHARGING[$side]:-0}" = 1 ] && flag=" (charging)"
      printf '%-5s: %s%%%s\n' "$word" "${pct_of[$side]}" "$flag"
    fi
  done
}

# Render both halves as one grey placeholder pair, for the states where we have
# no per-half information at all.
blank_bars() {
  if [ "${TOTEM_BAR_STYLE:-blocks}" = gauge ]; then
    printf "<span color='%s'>L────</span> <span color='%s'>R────</span>" "$C_NONE" "$C_NONE"
  else
    printf "<span color='%s'>%s%s</span>" "$C_NONE" "$DASH" "$DASH"
  fi
}

print_waybar() {
  local state; state=$(conn_state)
  if [ "$state" != connected ]; then
    printf '{"text":"%s %s","class":"%s","tooltip":"TOTEM: %s"}\n' \
      "$ICON" "$(blank_bars)" "$state" "$(state_note "$state")"
    return 0
  fi

  collect
  update_charging

  # Index the readings by side so the bars are always ordered L then R,
  # whatever order the GATT characteristics came back in.
  local -A pct_of=()
  local i
  for i in "${!PCTS[@]}"; do pct_of[${SIDES[$i]}]="${PCTS[$i]}"; done

  local nl='\n' side pct bars="" tip="TOTEM" min="" any_charging=0 known=0
  for side in L R; do
    pct="${pct_of[$side]:-}"
    if [ -z "$pct" ]; then
      tip+="${nl}${side}: — no report (half off, asleep, or flat)"
    else
      known=1
      if [ -z "$min" ] || [ "$pct" -lt "$min" ]; then min="$pct"; fi
      tip+="${nl}${side}: ${pct}%"
      if [ "${CHARGING[$side]:-0}" = 1 ]; then tip+=" (charging)"; any_charging=1; fi
    fi
    if [ "${TOTEM_BAR_STYLE:-blocks}" = gauge ]; then
      bars+="<span color='$(colour_for "$pct" "$side")'>${side}$(gauge_for "$pct")</span> "
    else
      bars+=" <span color='$(colour_for "$pct" "$side")'>$(block_for "$pct")</span>"
    fi
  done
  bars="${bars% }"
  [ "$CHARGING_SOURCE" = inferred ] && tip+="${nl}(charging inferred from level changes)"

  # Link is up but neither half answered — a transient GATT failure, not an
  # absent keyboard; keep it visually distinct from "asleep".
  if [ "$known" -eq 0 ]; then
    printf '{"text":"%s %s","class":"stale","tooltip":"TOTEM: %s"}\n' \
      "$ICON" "$bars" "$(state_note read-failed)"
    return 0
  fi

  # Class still reflects the worse half, so the stylesheet rules keep working.
  local cls="good"
  if   [ "$min" -lt "$CRIT_PCT" ]; then cls="critical"
  elif [ "$min" -lt "$WARN_PCT" ]; then cls="warning"; fi
  [ "$any_charging" = 1 ] && bars+=" ${BOLT}"

  printf '{"text":"%s %s","percentage":%s,"class":"%s","tooltip":"%s"}\n' \
    "$ICON" "$bars" "$min" "$cls" "$tip"
}

case "$MODE" in
  oneshot) print_human ;;
  waybar)  print_waybar ;;
  watch)
    echo "Polling every ${INTERVAL}s — a rising % means that half is charging. Ctrl-C to stop."
    while true; do echo "--- $(date +%H:%M:%S) ---"; print_human || true; sleep "$INTERVAL"; done ;;
esac
