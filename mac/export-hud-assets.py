#!/usr/bin/env python3
"""Export macOS HUD assets from the generated keymap-HUD SVGs.

The Linux daemon (tools/keymap-hud-daemon.py) renders the layer SVGs live with
librsvg and reads key geometry out of them. The macOS HUD (mac/keymap-hud.lua,
Hammerspoon) can't do that, so this bakes the same information ahead of time:

  - one PNG per layer (rendered from the SVG via rsvg-convert, so the CSS
    drop-shadow is preserved), and
  - positions.json: per-layer key geometry + label->position maps, plus the
    constants the Lua side needs to place highlight boxes.

Geometry is emitted in SVG *point* units (the PNG is rendered at `--scale`x for
retina sharpness, but Hammerspoon displays it in point space), so the Lua can
map a key position straight onto the canvas.

Run tools/gen-keymap-hud.sh first to (re)generate the SVGs, then:
    python3 mac/export-hud-assets.py
Output goes to ~/.config/keymap-hud/mac/ by default.

Requires: rsvg-convert (brew install librsvg), PyYAML (pip install pyyaml).
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

import yaml

HUD_DIR = os.path.expanduser("~/.config/keymap-hud")

# The highlight box the daemon draws around a pressed key, in SVG point units:
# rounded_rect(-28, -26, 55, 52, 6) translated to the key point and rotated.
BOX_DX, BOX_DY, KEY_W, KEY_H, KEY_R = -28, -26, 55, 52, 6


def parse_layer_svg(path):
    """Return (vbw, vbh, ox, oy, keypos) — mirrors the daemon's Layer parser."""
    svg = open(path).read()
    m = re.search(r'<svg[^>]*\bviewBox="[\d.]+ [\d.]+ ([\d.]+) ([\d.]+)"', svg) \
        or re.search(r'<svg[^>]*\bwidth="([\d.]+)"[^>]*\bheight="([\d.]+)"', svg)
    vbw, vbh = float(m.group(1)), float(m.group(2))
    # Wrapper offset = layer-group translate + inner-group translate.
    lm = re.search(r'translate\(([-\d.]+),\s*([-\d.]+)\)"\s*class="layer-', svg)
    im = re.search(r'class="layer-[^"]*">\s*<text\b.*?</text>\s*'
                   r'<g transform="translate\(([-\d.]+),\s*([-\d.]+)\)">', svg, re.S)
    ox = (float(lm.group(1)) if lm else 0) + (float(im.group(1)) if im else 0)
    oy = (float(lm.group(2)) if lm else 0) + (float(im.group(2)) if im else 0)
    keypos = {}
    for x, y, rot, n in re.findall(
            r'translate\(([-\d.]+),\s*([-\d.]+)\)(?:\s*rotate\(([-\d.]+)\))?"'
            r'\s*class="key keypos-(\d+)"', svg):
        keypos[int(n)] = (float(x), float(y), float(rot or 0))
    return vbw, vbh, ox, oy, keypos


def label_pos(legends):
    """label -> first position carrying it (mirrors the daemon)."""
    out = {}
    for pos, entry in enumerate(legends):
        label = entry["t"] if isinstance(entry, dict) and "t" in entry else entry
        if isinstance(label, str) and label not in out:
            out[label] = pos
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hud-dir", default=HUD_DIR,
                    help="where the layer SVGs + keymap.yaml live")
    ap.add_argument("--out", default=os.path.join(HUD_DIR, "mac"),
                    help="output dir for PNGs + positions.json")
    ap.add_argument("--scale", type=int, default=2, help="PNG raster scale (retina)")
    args = ap.parse_args()

    if not os.path.exists(os.path.join(args.hud_dir, "keymap.yaml")):
        sys.exit(f"no keymap.yaml in {args.hud_dir} — run tools/gen-keymap-hud.sh first")
    if subprocess.run(["which", "rsvg-convert"], capture_output=True).returncode:
        sys.exit("rsvg-convert not found — install it (brew install librsvg)")

    legends_all = yaml.safe_load(open(os.path.join(args.hud_dir, "keymap.yaml")))["layers"]
    names = list(legends_all.keys())
    svgs = sorted(glob.glob(os.path.join(args.hud_dir, "layers", "*.svg")))
    os.makedirs(args.out, exist_ok=True)

    canvas_w = canvas_h = None
    layers = []
    for i, svg in enumerate(svgs):
        name = names[i]
        vbw, vbh, ox, oy, keypos = parse_layer_svg(svg)
        canvas_w, canvas_h = vbw, vbh  # identical across layers
        png = f"{i}-{name.lower()}.png"
        subprocess.run(["rsvg-convert", "-w", str(round(vbw * args.scale)),
                        "-h", str(round(vbh * args.scale)),
                        "-o", os.path.join(args.out, png), svg], check=True)
        keys = {str(p): {"x": round(ox + kx, 2), "y": round(oy + ky, 2), "rot": rot}
                for p, (kx, ky, rot) in keypos.items()}
        layers.append({"name": name, "image": png,
                       "keys": keys, "label_pos": label_pos(legends_all[name])})
        print(f"  {name}: {png} ({len(keys)} keys)")

    data = {
        "canvas_w": round(canvas_w, 2), "canvas_h": round(canvas_h, 2),
        "scale": args.scale,
        "box_dx": BOX_DX, "box_dy": BOX_DY,
        "key_w": KEY_W, "key_h": KEY_H, "key_radius": KEY_R,
        # Hammerspoon key NAMES (resolved to keycodes in Lua) -> layer index.
        "sentinels": {"f16": 1, "f17": 2, "f18": 3},
        "layers": layers,
    }
    out_json = os.path.join(args.out, "positions.json")
    json.dump(data, open(out_json, "w"), indent=2)
    print(f"Wrote {out_json} + {len(layers)} PNG(s) to {args.out}")


if __name__ == "__main__":
    main()
