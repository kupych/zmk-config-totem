# TOTEM keymap HUD — macOS (Hammerspoon)

A macOS port of the Linux overlay (`tools/keymap-hud-daemon.py`). The Linux
daemon's two core dependencies are Linux/Wayland-only — `gtk4-layer-shell` (the
overlay) and `evdev` (input) — so this reimplements those two layers with
native macOS equivalents while **reusing the same SVG art pipeline**:

| Concern        | Linux                     | macOS (here)                          |
| -------------- | ------------------------- | ------------------------------------- |
| Overlay        | gtk4-layer-shell          | Hammerspoon `hs.canvas`               |
| Input          | evdev `/dev/input`        | Hammerspoon `hs.eventtap`             |
| Layer tracking | F16/F17/F18 sentinels     | **same** (firmware-side, unchanged)   |
| Art            | librsvg renders SVG live  | PNGs baked by `export-hud-assets.py`  |

The F16–F18 sentinels we picked for the firmware are already macOS-safe (no
display dimming, no IME) and ghostty swallows them — so **no firmware changes
are needed**; the Mac just listens for the same keys.

## Files

- `export-hud-assets.py` — renders each layer SVG to a PNG (via `rsvg-convert`,
  so the drop-shadow is preserved) and writes `positions.json` (key geometry +
  label→position maps + sentinel mapping). **Tested on Linux.**
- `keymap-hud.lua` — the Hammerspoon overlay: canvas + eventtap + layer
  following + key highlighting + toggle. **Written/reviewed on Linux but not yet
  run on a Mac** — see "On-device tuning" below.

## Setup

1. **Install deps** (Homebrew):
   ```sh
   brew install --cask hammerspoon
   brew install librsvg          # rsvg-convert
   brew install uv               # for keymap-drawer (uvx)
   pip3 install pyyaml
   ```

2. **Generate the art + assets** (re-run after any keymap change):
   ```sh
   ./tools/gen-keymap-hud.sh          # SVGs + keymap.yaml -> ~/.config/keymap-hud
   python3 mac/export-hud-assets.py   # PNGs + positions.json -> ~/.config/keymap-hud/mac
   ```

3. **Load it in Hammerspoon** — add to `~/.hammerspoon/init.lua`:
   ```lua
   totemHud = dofile(os.getenv("HOME") .. "/zmk-config-totem/mac/keymap-hud.lua")
   ```
   Reload Hammerspoon's config.

4. **Grant permissions:** System Settings → Privacy & Security → **Accessibility**
   *and* **Input Monitoring** → enable Hammerspoon. The eventtap won't see keys
   otherwise.

5. **Toggle:** default is **⌘⌥K** (configurable at the top of the `.lua`).

## The toggle / ⌘K caveat

The firmware's pinky-chord sends **Cmd+K** (`LGUI+K`). On Linux that toggles the
HUD because `Super+K` is free, but on macOS **Cmd+K is widely used** (Slack quick
switcher, browser search). So the Lua defaults to a separate hotkey (⌘⌥K) you
press manually. To make the *pinky chord* drive the Mac HUD, the cleanest fix is
to change the firmware `hud_toggle` macro to send an **inert key like F19**
(same family as the sentinels) and bind that here — then it's conflict-free on
both OSes. (Doing that would also mean updating the Linux daemon, which currently
toggles on `Super+K`.)

## On-device tuning (I couldn't run Hammerspoon to verify)

The exporter is verified; the Lua is structurally complete but a few
macOS-specific spots are marked `NOTE` in `keymap-hud.lua` and may need a tweak:

- **Rotation direction** — if outer-column key highlights look mirrored, negate
  `k.rot` in `highlight_element`.
- **Canvas behavior flags** — if the overlay steals focus or hides on Spaces
  changes, adjust the `canvas:behavior({...})` list.
- **keycode→label table** — `SHIFT`/`SPECIAL` map macOS key names to the SVG
  legends. If some keys don't highlight, compare against the real legends:
  ```sh
  python3 -c 'import json,os;d=json.load(open(os.path.expanduser("~/.config/keymap-hud/mac/positions.json")));print(sorted(d["layers"][0]["label_pos"]))'
  ```
  and add any missing name→legend entries.

## Keeping it in sync

Unlike the Linux side (a systemd `.path` watcher auto-regenerates), this is
manual: after editing the keymap, re-run step 2. You could wire the same with a
`launchd` `WatchPaths` agent on `config/totem.keymap` if you want it automatic.
