#!/usr/bin/env bash
# Regenerate the keymap HUD art from config/totem.keymap and reload the overlay.
#
# Run it by hand after editing the keymap, or let keymap-hud-sync.path fire it
# automatically on every change (see ~/.config/systemd/user/keymap-hud-sync.*).
# The daemon reads its SVGs once at startup, so we restart it to pick up new art.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"   # uvx (used by gen-keymap-hud.sh) lives here

"$REPO/tools/gen-keymap-hud.sh"

# Only restart the overlay if we're in a graphical session (it's a Wayland app).
# When edited from a TTY there's nothing to reload; new art loads on next start.
if [ -n "${WAYLAND_DISPLAY:-}" ] || systemctl --user is-active --quiet keymap-hud.service; then
    systemctl --user restart keymap-hud.service
    echo "HUD art regenerated and overlay restarted."
else
    echo "HUD art regenerated (no graphical session; overlay not restarted)."
fi
