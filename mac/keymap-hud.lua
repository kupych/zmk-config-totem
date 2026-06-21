-- TOTEM live keymap HUD for macOS (Hammerspoon).
--
-- A port of the Linux GTK/layer-shell overlay (tools/keymap-hud-daemon.py):
--   * a transparent, always-on-top, click-through overlay showing the keymap
--   * follows the active ZMK layer via the F16/F17/F18 sentinels the firmware
--     holds while a layer is active (inert on macOS, swallowed by ghostty)
--   * highlights keys live as you press them
--   * a hotkey toggles it
--
-- Assets are baked by mac/export-hud-assets.py into ~/.config/keymap-hud/mac/
-- (positions.json + one PNG per layer). Regenerate them whenever the keymap
-- changes (tools/gen-keymap-hud.sh && python3 mac/export-hud-assets.py).
--
-- Install: in ~/.hammerspoon/init.lua:
--     totemHud = dofile(os.getenv("HOME") .. "/zmk-config-totem/mac/keymap-hud.lua")
-- Grant Hammerspoon "Accessibility" + "Input Monitoring" in System Settings >
-- Privacy & Security (the eventtap needs them).
--
-- !! Built/reviewed on Linux without a Mac to run it on — the structure is
--    complete, but a few macOS-specific spots are marked NOTE and may need
--    tuning on-device (rotation direction, canvas behavior flags, and the
--    keycode->label table for any legend that doesn't match).

local M = {}

----------------------------------------------------------------- config -------
local ASSET_DIR = os.getenv("HOME") .. "/.config/keymap-hud/mac"
local FADE_S    = 0.22            -- how long a highlight lingers after release
local WIDTH_FRAC = 0.55           -- overlay width as a fraction of the screen
local BOTTOM_GAP = 100            -- px above the bottom of the screen

local HILITE = {
  fill   = { red = 1.0, green = 0.83, blue = 0.0, alpha = 0.62 },
  stroke = { red = 0.15, green = 0.10, blue = 0.0, alpha = 0.9 },
}

-- The firmware's pinky chord taps F19 — inert on macOS, swallowed by ghostty,
-- and caught by the eventtap below. No hs.hotkey, no modifier conflicts. Want a
-- manual shortcut as well? Bind one to M.toggle from your init.lua.
local TOGGLE_KEY = "f19"

------------------------------------------------------ keycode -> label --------
-- macOS virtual keycode -> candidate legend(s) as they appear in the SVG. We
-- try each candidate against the current layer's label map, so symbol layers
-- (where "!" is physically Shift+1) highlight correctly — same approach as the
-- Linux daemon's EVDEV_TO_LABELS. NOTE: verify these legends match your
-- keymap.yaml; dump them with:  jq '.layers[].label_pos|keys' positions.json
local SHIFT = {
  ["1"]="!", ["2"]="@", ["3"]="#", ["4"]="$", ["5"]="%", ["6"]="^",
  ["7"]="&", ["8"]="*", ["9"]="(", ["0"]=")", ["-"]="_", ["="]="+",
  ["["]="{", ["]"]="}", [";"]=":", ["'"]='"', [","]="<", ["."]=">",
  ["/"]="?", ["\\"]="|", ["`"]="~",
}
local SPECIAL = {
  ["return"]="RET", ["tab"]="TAB", ["space"]="SPACE", ["delete"]="BSPC",
  ["forwarddelete"]="DEL", ["escape"]="ESC",
  ["up"]="UP", ["down"]="DOWN", ["left"]="LEFT", ["right"]="RIGHT",
  ["pageup"]="PG UP", ["pagedown"]="PG DN",
  ["padplus"]="+", ["padminus"]="-", ["padmultiply"]="*", ["padclear"]="CLR",
}

-- Invert hs.keycodes.map (name -> code) into code -> name.
local CODE2NAME = {}
for name, code in pairs(hs.keycodes.map) do
  if type(code) == "number" and CODE2NAME[code] == nil then CODE2NAME[code] = name end
end

local function labels_for_code(code)
  local name = CODE2NAME[code]
  if not name then return {} end
  if #name == 1 and name:match("%a") then return { name:upper() } end  -- letter
  if SHIFT[name] then return { SHIFT[name], name } end                 -- digit/punct
  if SPECIAL[name] then return { SPECIAL[name] } end                   -- named key
  return { name:upper() }
end

------------------------------------------------------------- load assets ------
local data = hs.json.read(ASSET_DIR .. "/positions.json")
if not data then
  hs.alert.show("TOTEM HUD: no assets in " .. ASSET_DIR .. " (run export-hud-assets.py)")
  return M
end

local images = {}
for i, L in ipairs(data.layers) do
  images[i] = hs.image.imageFromPath(ASSET_DIR .. "/" .. L.image)
end

-- sentinel key NAME -> layer number, resolved to keycode -> layer number.
local SENTINEL = {}
for name, layernum in pairs(data.sentinels) do
  local code = hs.keycodes.map[name]
  if code then SENTINEL[code] = layernum end
end
local TOGGLE_CODE = hs.keycodes.map[TOGGLE_KEY]

--------------------------------------------------------------- geometry -------
local sf  = hs.screen.primaryScreen():frame()
local DS  = math.min(1.0, (sf.w * WIDTH_FRAC) / data.canvas_w)   -- display scale
local W, H = data.canvas_w * DS, data.canvas_h * DS
local FRAME = { x = sf.x + (sf.w - W) / 2, y = sf.y + sf.h - H - BOTTOM_GAP, w = W, h = H }

----------------------------------------------------------------- state --------
local canvas  = nil
local visible = false
local current = 1            -- 1-based index into data.layers (1 = BASE)
local held    = {}           -- pos -> true (physically down)
local shown   = {}           -- pos -> true (fading after release)
local stack   = {}           -- layer number -> true (held sentinels)
local tap     = nil

local function active_positions()
  local out = {}
  for p in pairs(held) do out[p] = true end
  for p in pairs(shown) do out[p] = true end
  return out
end

local function highlight_element(L, pos)
  local k = L.keys[tostring(pos)]
  if not k then return nil end
  local cx, cy = k.x * DS, k.y * DS
  local el = {
    type = "rectangle", action = "strokeAndFill",
    frame = { x = cx + data.box_dx * DS, y = cy + data.box_dy * DS,
              w = data.key_w * DS, h = data.key_h * DS },
    roundedRectRadii = { xRadius = data.key_radius * DS, yRadius = data.key_radius * DS },
    fillColor = HILITE.fill, strokeColor = HILITE.stroke, strokeWidth = 2 * DS,
  }
  if k.rot and k.rot ~= 0 then
    -- NOTE: if rotations look mirrored on-device, negate k.rot here. SVG and
    -- hs.canvas may differ in rotation sign.
    el.transformation = hs.canvas.matrix.identity()
      :translate(cx, cy):rotate(k.rot):translate(-cx, -cy)
  end
  return el
end

local function redraw()
  if not (canvas and visible) then return end
  canvas[1].image = images[current]
  while #canvas > 1 do canvas:removeElement(#canvas) end
  local L = data.layers[current]
  for pos in pairs(active_positions()) do
    local el = highlight_element(L, pos)
    if el then canvas:appendElements(el) end
  end
end

local function build_canvas()
  canvas = hs.canvas.new(FRAME)
  canvas:level(hs.canvas.windowLevels.overlay)
  -- NOTE: behavior flags — show over all spaces + fullscreen apps, don't
  -- participate in window cycling. Tune if it grabs focus or hides oddly.
  canvas:behavior({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  canvas:clickActivating(false)
  canvas[1] = { type = "image", image = images[current],
                frame = { x = 0, y = 0, w = W, h = H }, imageScaling = "scaleToFit" }
end

--------------------------------------------------------------- layers ---------
local function top_layer()
  local t = 0
  for num in pairs(stack) do if num > t then t = num end end
  return t   -- 0 = BASE
end

local function set_layer(num)            -- num: ZMK layer 0..3
  local idx = num + 1
  if idx ~= current then
    current = idx
    held, shown = {}, {}
    redraw()
  end
end

------------------------------------------------------------ visibility --------
local function show() visible = true; if canvas then canvas:show(); redraw() end end
local function hide() visible = false; if canvas then canvas:hide() end end
function M.toggle() if visible then hide() else show() end end

------------------------------------------------------------- input tap --------
local function on_key(e)
  local down = (e:getType() == hs.eventtap.event.types.keyDown)
  local code = e:getKeyCode()

  if down and code == TOGGLE_CODE then    -- pinky chord (F19): toggle the HUD
    M.toggle()
    return false
  end

  local layernum = SENTINEL[code]
  if layernum then                        -- layer sentinel: follow the layer
    if down then stack[layernum] = true else stack[layernum] = nil end
    set_layer(top_layer())
    return false
  end

  if not visible then return false end    -- only chase highlights when shown
  local L = data.layers[current]
  local pos
  for _, lab in ipairs(labels_for_code(code)) do
    if L.label_pos[lab] ~= nil then pos = L.label_pos[lab]; break end
  end
  if pos ~= nil then
    if down then
      held[pos] = true; shown[pos] = nil
    else
      held[pos] = nil; shown[pos] = true
      hs.timer.doAfter(FADE_S, function() shown[pos] = nil; redraw() end)
    end
    redraw()
  end
  return false                            -- never consume; keys pass through
end

----------------------------------------------------------------- lifecycle ----
function M.start()
  if not canvas then build_canvas() end
  tap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp }, on_key)
  tap:start()
  return M
end

function M.stop()
  if tap then tap:stop(); tap = nil end
  if canvas then canvas:delete(); canvas = nil end
  visible = false
end

M.start()
return M
