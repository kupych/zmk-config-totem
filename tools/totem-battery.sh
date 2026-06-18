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
set -euo pipefail

WATCH=0
INTERVAL=60
if [ "${1:-}" = "--watch" ] || [ "${1:-}" = "-w" ]; then
  WATCH=1; shift
  case "${1:-}" in (''|*[!0-9]*) ;; (*) INTERVAL="$1"; shift ;; esac
fi
MAC="${1:-FC:CD:2B:30:B8:9B}"
ADAPTER="hci0"
BASE="/org/bluez/${ADAPTER}/dev_${MAC//:/_}"

read_batteries() {
  mapfile -t paths < <(
    bluetoothctl gatt.list-attributes "$MAC" 2>/dev/null \
      | grep -iB1 '00002a19-' \
      | grep -o "${BASE}/service[0-9a-f]*/char[0-9a-f]*"
  )
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "No battery characteristics found. Is the TOTEM connected? (bluetoothctl info $MAC)" >&2
    return 1
  fi
  local i=1 p out pct
  for p in "${paths[@]}"; do
    # ReadValue returns "ay <count> <byte ...>"; the byte is the percentage.
    out=$(busctl call org.bluez "$p" org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null) \
      || out=$(busctl call org.bluez "$p" org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null) # 0x0e is often transient
    pct=$(printf '%s\n' "$out" | grep -o '[0-9]*$')
    printf 'Half %d (%s): %s%%\n' "$i" "${p##*/}" "${pct:-?}"
    i=$((i + 1))
  done
}

if [ "$WATCH" -eq 0 ]; then
  read_batteries
else
  echo "Polling every ${INTERVAL}s — a rising % means that half is charging. Ctrl-C to stop."
  while true; do
    echo "--- $(date +%H:%M:%S) ---"
    read_batteries || true
    sleep "$INTERVAL"
  done
fi
