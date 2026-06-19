#!/usr/bin/env bash
# Watch for a TOTEM half in UF2 bootloader mode and flash it, with a dialog.
#
# Double-tapping reset on a XIAO nRF52840 mounts it as a small FAT volume
# (label XIAO-SENSE) containing INFO_UF2.TXT; copying a .uf2 onto it flashes
# the firmware and the board auto-reboots (the volume vanishes on its own).
#
# Both halves use the *same* bootloader label, so left/right can't be told
# apart automatically — the dialog asks which half each detected board is.
#
# Flow: run it, then double-tap reset on a half. A wofi menu pops asking
# Left/Right; pick one and it mounts, copies the matching firmware, and waits
# for the next board. Esc/Cancel in the menu exits.
#
# Usage:
#   tools/totem-flash.sh [--download] [FIRMWARE_DIR]
#     --download     fetch the latest master CI artifact first (needs gh)
#     FIRMWARE_DIR   where to find *left*.uf2 / *right*.uf2 (default: ./firmware)
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FWDIR="$REPO_DIR/firmware"
DOWNLOAD=0
LABEL_RE='XIAO'          # bootloader volume label match (case-insensitive)

case "${1:-}" in --download) DOWNLOAD=1; shift ;; esac
[ -n "${1:-}" ] && FWDIR="$1"

note() { notify-send -a "totem-flash" "$@" 2>/dev/null || true; printf '%s\n' "$*"; }
die()  { note "TOTEM flash" "$*"; exit 1; }

# --- optional: pull the latest firmware from CI --------------------------------
if [ "$DOWNLOAD" -eq 1 ]; then
  command -v gh >/dev/null || die "gh not installed (needed for --download)"
  run=$(gh run list --branch master --workflow build.yml --status success \
          --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
  [ -n "$run" ] || die "no successful build found on master"
  rm -rf "$FWDIR" && mkdir -p "$FWDIR"
  gh run download "$run" -D "$FWDIR" || die "firmware download failed"
fi

# --- locate the two firmware files (newest of each, searched recursively) ------
newest() { find "$FWDIR" -name "$1" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-; }
FW_LEFT="$(newest '*left*.uf2')"
FW_RIGHT="$(newest '*right*.uf2')"
[ -n "$FW_LEFT" ]  || die "no *left*.uf2 in $FWDIR (try --download)"
[ -n "$FW_RIGHT" ] || die "no *right*.uf2 in $FWDIR (try --download)"
printf 'left : %s\nright: %s\n' "$FW_LEFT" "$FW_RIGHT"

# Find a connected bootloader device node by volume label, or empty.
find_boot() { lsblk -rno NAME,LABEL | awk -v re="$LABEL_RE" 'tolower($2) ~ tolower(re) {print "/dev/"$1; exit}'; }

# Ask which half; echoes Left|Right, or empty if cancelled.
ask_half() { printf 'Left\nRight\n' | wofi --dmenu --no-cache -i \
               --prompt "TOTEM bootloader — flash which half? (Esc to quit)" 2>/dev/null; }

flash_one() {
  local devnode="$1" half fw mp
  half="$(ask_half)"
  case "$half" in
    Left)  fw="$FW_LEFT"  ;;
    Right) fw="$FW_RIGHT" ;;
    *)     note "TOTEM flash" "Cancelled — exiting."; exit 0 ;;
  esac

  # Mount (rootless) if the desktop hasn't already auto-mounted it.
  mp="$(lsblk -rno MOUNTPOINT "$devnode" | head -1)"
  if [ -z "$mp" ]; then
    udisksctl mount -b "$devnode" >/dev/null 2>&1 || true
    mp="$(lsblk -rno MOUNTPOINT "$devnode" | head -1)"
  fi
  [ -n "$mp" ] || { note "TOTEM flash" "Could not mount $devnode"; return 1; }

  note "TOTEM flash" "Flashing $half → $(basename "$fw")…"
  # The board resets the instant the write completes, so cp/sync may report the
  # volume vanishing mid-write — that's success, not failure.
  cp "$fw" "$mp/" 2>/dev/null; sync 2>/dev/null
  note "TOTEM flash" "$half flashed ✓  (board rebooting)"

  # Wait for the bootloader volume to disappear before watching again.
  while [ -e "$devnode" ]; do sleep 0.5; done
}

note "TOTEM flash" "Watching for a half in bootloader — double-tap reset on one."
while true; do
  dev="$(find_boot)"
  if [ -n "$dev" ]; then flash_one "$dev"; fi
  sleep 1
done
