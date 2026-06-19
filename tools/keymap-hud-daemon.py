#!/usr/bin/env python3
"""
Live keymap HUD for the TOTEM (ZMK split, Hyprland/Wayland).

A persistent daemon that draws a transparent, focus-free overlay (GTK4
layer-shell) showing the current keymap layer, highlights keys as you press
them (read from evdev), toggles on Super+K, and follows the active ZMK layer
via sentinel keys (F16=layer1, F17=layer2, F18=layer3) emitted by the firmware.
F16-F18 are used (not F13-F15, which dim the display on macOS, nor LANG1-3,
which toggle the IME under fcitx) so the held sentinel is inert across hosts.
Terminals still encode them, so ghostty is set to swallow F16-F18
(keybind = fN = ignore); the daemon reads them straight off evdev regardless.

Run with the SYSTEM python (has gi/Rsvg/evdev):  /usr/bin/python3 this.py
Assets come from ~/.config/keymap-hud/ (see tools/gen-keymap-hud.sh).
"""
import gi, glob, math, os, re, signal, threading, time
import cairo
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
gi.require_version("Rsvg", "2.0")
from gi.repository import Gtk, Gdk, GLib, Gtk4LayerShell as LayerShell, Rsvg
import yaml
import evdev
from evdev import ecodes as e

HUD_DIR = os.path.expanduser("~/.config/keymap-hud")
LAYERS_DIR = os.path.join(HUD_DIR, "layers")
KEYMAP_YAML = os.path.join(HUD_DIR, "keymap.yaml")
KBD_NAME = "TOTEM Keyboard"

WIN_W, WIN_H = 1640, 760          # overlay size (≈ image aspect 2.159)
HILITE = (1.0, 0.83, 0.0, 0.62)   # translucent yellow fill for pressed keys
HILITE_OUTLINE = (0.15, 0.10, 0.0, 0.9)  # dark edge so it reads on light backgrounds
HILITE_SHADOW = (0.0, 0.0, 0.0, 0.35)    # soft drop shadow beneath the highlight
HILITE_OUTLINE_W = 2.0            # outline stroke width (svg user units)
FADE_S = 0.22                     # how long a highlight lingers after release

# Sentinel keys the firmware holds while a layer is active -> follow live layer.
# F16/F17/F18: no default action on macOS or Linux, so the held key disturbs
# nothing; ghostty is configured to swallow them so they don't reach vim.
SENTINEL_LAYER = {e.KEY_F16: 1, e.KEY_F17: 2, e.KEY_F18: 3}

# evdev keycode -> candidate legends (unshifted, shifted) as they appear in
# keymap.yaml. We try each candidate against the current layer so symbol layers
# (where e.g. "!" is physically Shift+1) highlight correctly.
EVDEV_TO_LABELS = {}
for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":          # NB: evdev codes aren't alphabetical
    EVDEV_TO_LABELS[getattr(e, f"KEY_{ch}")] = [ch]
_PAIRS = {
    e.KEY_1: ("1", "!"), e.KEY_2: ("2", "@"), e.KEY_3: ("3", "#"),
    e.KEY_4: ("4", "$"), e.KEY_5: ("5", "%"), e.KEY_6: ("6", "^"),
    e.KEY_7: ("7", "&"), e.KEY_8: ("8", "*"), e.KEY_9: ("9", "("),
    e.KEY_0: ("0", ")"), e.KEY_MINUS: ("-", "_"), e.KEY_EQUAL: ("=", "+"),
    e.KEY_LEFTBRACE: ("[", "{"), e.KEY_RIGHTBRACE: ("]", "}"),
    e.KEY_SEMICOLON: (";", ":"), e.KEY_APOSTROPHE: ("'", '"'),
    e.KEY_COMMA: (",", "<"), e.KEY_DOT: (".", ">"), e.KEY_SLASH: ("/", "?"),
    e.KEY_BACKSLASH: ("\\", "|"), e.KEY_GRAVE: ("`", "~"),
}
for code, pair in _PAIRS.items():
    EVDEV_TO_LABELS[code] = list(pair)
_SINGLE = {
    e.KEY_ESC: "ESC", e.KEY_TAB: "TAB", e.KEY_SPACE: "SPACE", e.KEY_ENTER: "RET",
    e.KEY_BACKSPACE: "BSPC", e.KEY_DELETE: "DEL",
    e.KEY_UP: "UP", e.KEY_DOWN: "DOWN", e.KEY_LEFT: "LEFT", e.KEY_RIGHT: "RIGHT",
    e.KEY_PAGEUP: "PG UP", e.KEY_PAGEDOWN: "PG DN",
    e.KEY_KP7: "KP 7", e.KEY_KP8: "KP 8", e.KEY_KP9: "KP 9",
    e.KEY_KP4: "KP 4", e.KEY_KP5: "KP 5", e.KEY_KP6: "KP 6",
    e.KEY_KP1: "KP 1", e.KEY_KP2: "KP 2", e.KEY_KP3: "KP 3", e.KEY_KP0: "KP 0",
    e.KEY_KPPLUS: "KP PLUS", e.KEY_KPMINUS: "KP MINUS", e.KEY_KPASTERISK: "KP MULTIPLY",
}
for code, lbl in _SINGLE.items():
    EVDEV_TO_LABELS[code] = [lbl]
for n in range(1, 13):
    EVDEV_TO_LABELS[getattr(e, f"KEY_F{n}")] = [f"F{n}"]

META_KEYS = {e.KEY_LEFTMETA, e.KEY_RIGHTMETA}


def rounded_rect(cr, x, y, w, h, r):
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    cr.close_path()


class Layer:
    """One keymap layer: its rendered SVG + key geometry + label->position map."""
    def __init__(self, svg_path, legends):
        self.handle = Rsvg.Handle.new_from_file(svg_path)
        svg = open(svg_path).read()
        m = re.search(r'<svg[^>]*\bviewBox="[\d.]+ [\d.]+ ([\d.]+) ([\d.]+)"', svg) \
            or re.search(r'<svg[^>]*\bwidth="([\d.]+)"[^>]*\bheight="([\d.]+)"', svg)
        self.vbw, self.vbh = float(m.group(1)), float(m.group(2))
        # Wrapper offset = layer-group translate + inner-group translate.
        lm = re.search(r'translate\(([-\d.]+),\s*([-\d.]+)\)"\s*class="layer-', svg)
        im = re.search(r'class="layer-[^"]*">\s*<text\b.*?</text>\s*'
                       r'<g transform="translate\(([-\d.]+),\s*([-\d.]+)\)">', svg, re.S)
        self.ox = (float(lm.group(1)) if lm else 0) + (float(im.group(1)) if im else 0)
        self.oy = (float(lm.group(2)) if lm else 0) + (float(im.group(2)) if im else 0)
        # keypos -> (x, y, rotation)
        self.keypos = {}
        for x, y, rot, n in re.findall(
            r'translate\(([-\d.]+),\s*([-\d.]+)\)(?:\s*rotate\(([-\d.]+)\))?"'
            r'\s*class="key keypos-(\d+)"', svg):
            self.keypos[int(n)] = (float(x), float(y), float(rot or 0))
        # label -> position (first match wins)
        self.label_pos = {}
        for pos, entry in enumerate(legends):
            label = entry["t"] if isinstance(entry, dict) and "t" in entry else entry
            if isinstance(label, str) and label not in self.label_pos:
                self.label_pos[label] = pos


class HUD(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="ch.kupy.keymaphud")
        self.layers = []
        self.current = 0
        self._cache = {}          # (layer, w, h) -> pre-rendered ImageSurface
        self.held = set()         # positions physically held down
        self.shown = {}           # pos -> release stamp (stays lit until min time)
        self.sentinels = set()    # sentinel keycodes currently held (layer stack)
        self.visible = False
        self.meta = False

    def do_activate(self):
        legends = yaml.safe_load(open(KEYMAP_YAML))["layers"]
        names = list(legends.keys())
        for i, svg in enumerate(sorted(glob.glob(os.path.join(LAYERS_DIR, "*.svg")))):
            self.layers.append(Layer(svg, legends[names[i]]))

        self.win = Gtk.ApplicationWindow(application=self)
        self.win.set_default_size(WIN_W, WIN_H)
        LayerShell.init_for_window(self.win)
        LayerShell.set_layer(self.win, LayerShell.Layer.OVERLAY)
        LayerShell.set_keyboard_mode(self.win, LayerShell.KeyboardMode.NONE)
        LayerShell.set_namespace(self.win, "keymap-hud")

        css = Gtk.CssProvider()
        css.load_from_data(b"window, .background { background-color: transparent; }")
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.area = Gtk.DrawingArea()
        self.area.set_draw_func(self.on_draw)
        self.win.set_child(self.area)
        self.win.present()
        self.win.set_visible(False)
        print("activated; window created", flush=True)

        # SIGUSR1 toggles, SIGUSR2 cycles layer (handy for testing/scripting).
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1,
                             lambda *_: (self.toggle(), True)[1])
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2,
                             lambda *_: (self.set_layer((self.current + 1) % len(self.layers)), True)[1])

        def _report():
            n = getattr(self, "_draws", 0)
            self._draws = 0
            if n:
                print(f"draws/s: {n}", flush=True)
            return True
        GLib.timeout_add_seconds(1, _report)

        self.hold()  # keep running with no visible window
        threading.Thread(target=self.evdev_loop, daemon=True).start()

    # ---- rendering ----
    def _surface(self, idx, width, height):
        """Rasterize a layer's SVG to an ImageSurface once; reuse across frames."""
        key = (idx, width, height)
        surf = self._cache.get(key)
        if surf is None:
            self._cache.clear()  # only ever keep the current layer/size
            layer = self.layers[idx]
            surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
            c = cairo.Context(surf)
            s = min(width / layer.vbw, height / layer.vbh)
            c.translate((width - layer.vbw * s) / 2, (height - layer.vbh * s) / 2)
            c.scale(s, s)
            vp = Rsvg.Rectangle()
            vp.x, vp.y, vp.width, vp.height = 0, 0, layer.vbw, layer.vbh
            layer.handle.render_document(c, vp)
            self._cache[key] = surf
        return surf

    def on_draw(self, area, cr, width, height):
        self._draws = getattr(self, "_draws", 0) + 1
        cr.set_operator(1)  # SOURCE -> respect alpha
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(2)  # OVER
        layer = self.layers[self.current]
        cr.set_source_surface(self._surface(self.current, width, height), 0, 0)
        cr.paint()
        s = min(width / layer.vbw, height / layer.vbh)
        cr.translate((width - layer.vbw * s) / 2, (height - layer.vbh * s) / 2)
        cr.scale(s, s)
        for pos in self.held | set(self.shown):
            if pos in layer.keypos:
                kx, ky, rot = layer.keypos[pos]
                cr.save()
                cr.translate(layer.ox + kx, layer.oy + ky)
                cr.rotate(math.radians(rot))
                # Soft drop shadow (same box nudged down) for depth.
                cr.set_source_rgba(*HILITE_SHADOW)
                rounded_rect(cr, -28, -23, 55, 52, 6)
                cr.fill()
                # Yellow fill; keep the path so we can stroke its edge.
                rounded_rect(cr, -28, -26, 55, 52, 6)
                cr.set_source_rgba(*HILITE)
                cr.fill_preserve()
                # Dark outline so the highlight reads on light backgrounds.
                cr.set_source_rgba(*HILITE_OUTLINE)
                cr.set_line_width(HILITE_OUTLINE_W)
                cr.stroke()
                cr.restore()

    # ---- state changes (always via main thread) ----
    def set_visible(self, vis):
        self.visible = vis
        self.win.set_visible(vis)
        print(f"set_visible({vis})", flush=True)

    def toggle(self):
        self.set_visible(not self.visible)

    def set_layer(self, idx):
        idx = max(0, min(len(self.layers) - 1, idx))
        if idx != self.current:
            self.current = idx
            self.held.clear()
            self.shown.clear()
            self.area.queue_draw()

    def press(self, pos, down):
        if down:
            self.held.add(pos)
            self.shown.pop(pos, None)
        else:
            self.held.discard(pos)
            stamp = time.monotonic()
            self.shown[pos] = stamp
            GLib.timeout_add(int(FADE_S * 1000), self._clear, pos, stamp)
        self.area.queue_draw()

    def _clear(self, pos, stamp):
        # only clear if this exact release is still the latest for the key
        if self.shown.get(pos) == stamp:
            del self.shown[pos]
            self.area.queue_draw()
        return False

    # ---- input ----
    def evdev_loop(self):
        dev = next((evdev.InputDevice(p) for p in evdev.list_devices()
                    if evdev.InputDevice(p).name == KBD_NAME), None)
        if not dev:
            print("keymap-hud: keyboard not found:", KBD_NAME)
            return
        for ev in dev.read_loop():
            if ev.type != e.EV_KEY:
                continue
            code, val = ev.code, ev.value  # val: 1 down, 0 up, 2 repeat
            if code in META_KEYS:
                self.meta = val != 0
                continue
            if code in SENTINEL_LAYER:
                # Layers nest (ADJ is reached while NAV/SYM is held), so several
                # sentinels can be down at once. Track them and show the topmost;
                # fall back to BASE only when all are released.
                if val:
                    self.sentinels.add(code)
                else:
                    self.sentinels.discard(code)
                top = max((SENTINEL_LAYER[c] for c in self.sentinels), default=0)
                GLib.idle_add(self.set_layer, top)
                continue
            if val == 1 and self.meta and code == e.KEY_K:
                GLib.idle_add(self.toggle)
                continue
            if val == 2:
                continue
            labels = EVDEV_TO_LABELS.get(code)
            if not labels:
                continue
            lp = self.layers[self.current].label_pos
            pos = next((lp[l] for l in labels if l in lp), None)
            if pos is not None:
                GLib.idle_add(self.press, pos, val == 1)


if __name__ == "__main__":
    HUD().run(None)
