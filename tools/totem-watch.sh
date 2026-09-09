#!/usr/bin/env bash
# Log TOTEM BLE link transitions, to pin down the idle wedge.
#
# Event-driven: this watches BlueZ's PropertiesChanged signal for the device, so
# it costs the keyboard nothing -- no GATT traffic, no radio wakeups, nothing
# that reaches the peripheral half. A battery snapshot is taken only when the
# link actually changes state, and even then both values are served from the
# central's own RAM rather than fetched across the split link.
#
# The point is to answer one question about the wedge: did the BLE link drop, or
# did the keyboard stop responding with the link still nominally up? Those have
# very different causes, and it is hard to catch by hand if you are away from
# the desk when it happens.
#
# Usage:
#   tools/totem-watch.sh [MAC]              follow and log (Ctrl-C to stop)
#   tools/totem-watch.sh --mark "TEXT"      note something you just observed
#   tools/totem-watch.sh --tail             follow the existing log
#   tools/totem-watch.sh --path             print the log path
#
# To leave it running across sessions:
#   systemd-run --user --unit=totem-watch --working-directory="$PWD" \
#       tools/totem-watch.sh
#   systemctl --user stop totem-watch
#
# When the keyboard next wedges, before touching it, run:
#   tools/totem-watch.sh --mark "wedged, no response"
# so your observation lands in the same timeline as the link events.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATTERY="$HERE/totem-battery.sh"
LOG="${TOTEM_WATCH_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/totem-watch.log}"
HEARTBEAT="${TOTEM_WATCH_HEARTBEAT:-900}"   # silence before noting we are still alive

MODE=watch
MARK=""
case "${1:-}" in
  --mark) MODE=mark; MARK="${2:-observation}"; shift; [ $# -gt 0 ] && shift ;;
  --tail) MODE=tail; shift ;;
  --path) MODE=path; shift ;;
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

mkdir -p "$(dirname "$LOG")"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# BlueZ's own view of the link. Free -- a local property, no radio traffic.
connected() {
  case "$(busctl get-property org.bluez "$BASE" org.bluez.Device1 Connected 2>/dev/null)" in
    *true*)  echo yes ;;
    *false*) echo no ;;
    *)       echo unknown ;;
  esac
}

# Both halves on one line. Only called on an actual transition.
snapshot() {
  "$BATTERY" 2>/dev/null | sed 's/  */ /g' | paste -sd'|' - | sed 's/|/; /g'
}

case "$MODE" in
  path) echo "$LOG"; exit 0 ;;
  tail) exec tail -f "$LOG" ;;
  mark) log "MARK      $MARK  [link=$(connected)] $(snapshot)"; exit 0 ;;
esac

log "--------- watching $MAC (link=$(connected)) $(snapshot)"

# gdbus prints one line per signal, e.g.
#   /org/bluez/...: org.freedesktop.DBus.Properties.PropertiesChanged
#     ('org.bluez.Device1', {'Connected': <false>}, @as [])
# so a grep per property of interest is enough.
gdbus monitor --system --dest org.bluez --object-path "$BASE" 2>/dev/null |
  while true; do
    line=""
    IFS= read -r -t "$HEARTBEAT" line
    rc=$?
    # A read timeout (status >128) is the heartbeat; anything else non-zero is
    # EOF, meaning gdbus went away.
    if [ "$rc" -gt 128 ]; then
      log "heartbeat link=$(connected)"
      continue
    elif [ "$rc" -ne 0 ]; then
      log "--------- monitor exited"
      break
    fi

    case "$line" in
      *"'Connected': <true>"*)
        log "CONNECTED" ;;
      *"'Connected': <false>"*)
        # A wedge with no line here means the keyboard stopped responding while
        # the link was still nominally up -- a different fault entirely.
        log "DISCONNECTED" ;;
      *"'ServicesResolved': <true>"*)
        # Safe to read GATT only once the services are back.
        log "services resolved  $(snapshot)" ;;
    esac
  done
