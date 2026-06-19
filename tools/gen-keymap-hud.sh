#!/usr/bin/env bash
# Regenerate the keymap HUD assets from the ZMK keymap using keymap-drawer.
# Outputs one SVG per layer (numbered in keymap order) plus the parsed keymap
# YAML, which the live HUD daemon uses to map keycodes -> key positions.
# Re-run this whenever you change config/totem.keymap.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYMAP="$REPO/config/totem.keymap"
DRAW_CFG="$REPO/tools/keymap-hud-draw.yaml"
OUT="$HOME/.config/keymap-hud/layers"

mkdir -p "$OUT"
rm -f "$OUT"/*.svg

echo "Parsing $KEYMAP ..."
# -c passes the same config used for drawing; its parse_config.raw_binding_map
# rewrites combo/macro bindings (e.g. &walrus -> ":=") at parse time.
uvx --from keymap-drawer keymap -c "$DRAW_CFG" parse -z "$KEYMAP" > "$OUT/../keymap.yaml"
YAML="$OUT/../keymap.yaml"

# Pull layer names (in order) from the parsed YAML. Layer headers end in a
# bare colon (e.g. "  BASE:"), unlike nested keys such as combos' "  k: ...".
mapfile -t NAMES < <(
    awk '/^layers:/{f=1; next}
         /^[a-z]/{f=0}
         f && /^  [A-Za-z0-9_]+:[[:space:]]*$/ {gsub(/[ :]/, ""); print}' "$YAML"
)

i=0
for name in "${NAMES[@]}"; do
    lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    file="$(printf '%d-%s' "$i" "$lower")"
    uvx --from keymap-drawer keymap -c "$DRAW_CFG" draw "$YAML" -s "$name" > "$OUT/$file.svg"
    echo "  $name -> $file.svg"
    i=$((i + 1))
done

echo "Done. $i layer SVG(s) + keymap.yaml in $(dirname "$OUT")"
