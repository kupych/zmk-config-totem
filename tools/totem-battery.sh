#!/usr/bin/env bash
# Read TOTEM split-keyboard battery levels over BLE.
#
# ZMK exposes a standard Battery Service (0x180f) per half; with the central's
# BATTERY_LEVEL_PROXY/FETCHING config both show up under the one BLE device.
# BlueZ doesn't surface them via the Battery1 D-Bus interface here, so we read
# the GATT Battery Level characteristic (0x2a19) directly.
#
# There is no "charging" flag in what ZMK advertises, so to tell whether a half
# is charging, use --watch and look for the percentage stepping UP over a few
# minutes. (ZMK reports battery coarsely and only ~every 60s, so be patient.)
#
# Usage:
#   tools/totem-battery.sh [MAC]                 one-shot read
#   tools/totem-battery.sh --watch [SECS] [MAC]  poll until Ctrl-C (default 60s)
#   tools/totem-battery.sh --waybar [MAC]        one line of JSON for Waybar
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
ADAPTER="hci0"
BASE="/org/bluez/${ADAPTER}/dev_${MAC//:/_}"
ICON=""   # nerd-font keyboard glyph

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

# Populate parallel arrays SIDES[] (L/R), NAMES[] (char id), PCTS[] (number/"" ).
collect() {
  SIDES=(); NAMES=(); PCTS=()
  local paths p out pct
  mapfile -t paths < <(
    bluetoothctl gatt.list-attributes "$MAC" 2>/dev/null \
      | grep -iB1 '00002a19-' \
      | grep -o "${BASE}/service[0-9a-f]*/char[0-9a-f]*"
  )
  for p in "${paths[@]:-}"; do
    [ -z "$p" ] && continue
    # ReadValue returns "ay <count> <byte ...>"; the byte is the percentage.
    out=$(busctl call org.bluez "$p" org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null) \
      || out=$(busctl call org.bluez "$p" org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null) # 0x0e is often transient
    pct=$(printf '%s\n' "$out" | grep -o '[0-9]*$')
    SIDES+=("$(side_for "${p##*/}")"); NAMES+=("${p##*/}"); PCTS+=("$pct")
  done
}

print_human() {
  collect
  if [ "${#PCTS[@]}" -eq 0 ]; then echo "TOTEM not connected."; return 1; fi
  local i word
  for i in "${!PCTS[@]}"; do
    case "${SIDES[$i]}" in L) word=Left ;; R) word=Right ;; *) word="Half $((i + 1))" ;; esac
    printf '%-5s (%s): %s%%\n' "$word" "${NAMES[$i]}" "${PCTS[$i]:-?}"
  done
}

print_waybar() {
  collect
  local nl='\n' i p s min="" min_side="?" tip="TOTEM"
  for i in "${!PCTS[@]}"; do
    p="${PCTS[$i]}"; s="${SIDES[$i]}"
    tip+="${nl}${s}: ${p:-?}%"
    if [ -n "$p" ] && { [ -z "$min" ] || [ "$p" -lt "$min" ]; }; then min="$p"; min_side="$s"; fi
  done
  if [ -z "$min" ]; then
    printf '{"text":"%s ?","class":"disconnected","tooltip":"TOTEM not connected"}\n' "$ICON"
    return 0
  fi
  local cls="good"
  if   [ "$min" -le 15 ]; then cls="critical"
  elif [ "$min" -le 30 ]; then cls="warning"; fi
  # Headline shows the lower half AND which side it is, e.g. "  L 30%".
  printf '{"text":"%s %s %s%%","percentage":%s,"class":"%s","tooltip":"%s"}\n' \
    "$ICON" "$min_side" "$min" "$min" "$cls" "$tip"
}

case "$MODE" in
  oneshot) print_human ;;
  waybar)  print_waybar ;;
  watch)
    echo "Polling every ${INTERVAL}s — a rising % means that half is charging. Ctrl-C to stop."
    while true; do echo "--- $(date +%H:%M:%S) ---"; print_human || true; sleep "$INTERVAL"; done ;;
esac
