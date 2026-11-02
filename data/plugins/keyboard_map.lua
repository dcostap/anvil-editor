-- mod-version:3
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local panes = require "core.panes"
local style = require "core.style"
local ui = require "core.ui"
local View = require "core.view"
local view_icons = require "core.view_icons"
local TextField = require "core.ui.text_field"

-- The Keyboard Map: the physical keyboard, with the command that each key runs on the shown modifier layer.
-- It reads the live keymap, so it shows the bindings of all plugins and of the User Module.
-- Key names come from the keyboard layout, as for a key press: on a Spanish layout the Ñ key is ";".
-- With Alt Navigation, an Alt chord such as Alt+J shows the command of the key that it types, Ctrl+Left.
local KeyboardMap = View:extend()
KeyboardMap.context = "workspace"
KeyboardMap.view_icon = view_icons.register("keyboard_map", view_icons.ui("\u{F030C}"))

function KeyboardMap:__tostring() return "KeyboardMap" end
function KeyboardMap:get_name() return "Keyboard Map" end
function KeyboardMap:supports_text_input() return true end

------------------------------------------------------------------------------------------------------------------
-- The physical keyboard: a compact ISO board, in key units. `sc` is the set 1 scan code of a key that types
-- text, and `id` is its scancode name, which Anvil uses as the key name when the layout types no ASCII text.
-- A key with `name` has a fixed key name. A key with `mod` turns its modifier layer on or off.

local ROW_Y = { 0, 1.25, 2.25, 3.25, 4.25, 5.25 }
local LAYOUT = {}

local function add_row(y, x, specs)
  for _, spec in ipairs(specs) do
    spec.x, spec.y, spec.w, spec.h = spec.x or x, spec.y or y, spec.w or 1, spec.h or 1
    LAYOUT[#LAYOUT + 1] = spec
    x = spec.x + spec.w + (spec.gap or 0)
  end
end

local function text_keys(ids, first_scancode)
  local specs = {}
  for i = 1, #ids do
    local id = ids:sub(i, i)
    specs[i] = { id = id, sc = first_scancode + i - 1 }
  end
  return specs
end

local function named(name, label, w, extra)
  local spec = { id = name, name = name, label = label, w = w }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return spec
end

local function modifier(id, label, mod, w)
  return { id = id, label = label, mod = mod, w = w }
end

local function concat(...)
  local all = {}
  for _, list in ipairs({ ... }) do
    for _, spec in ipairs(list) do all[#all + 1] = spec end
  end
  return all
end

do
  local function fkeys(from, to)
    local specs = {}
    for i = from, to do specs[#specs + 1] = named("f" .. i, "F" .. i) end
    specs[#specs].gap = 0.25
    return specs
  end
  add_row(ROW_Y[1], 0, concat({ named("escape", "Esc", 1, { gap = 0.25 }) }, fkeys(1, 4), fkeys(5, 8), fkeys(9, 12),
    { named("delete", "Del") }))
  add_row(ROW_Y[2], 0, concat({ { id = "`", sc = 0x29 } }, text_keys("1234567890-=", 0x02),
    { named("backspace", "Backspace", 2) }))
  add_row(ROW_Y[3], 0, concat({ named("tab", "Tab", 1.5) }, text_keys("qwertyuiop[]", 0x10),
    { named("return", "Enter", 1.5) }))
  add_row(ROW_Y[4], 0, concat({ named("capslock", "Caps", 1.75) }, text_keys("asdfghjkl;'", 0x1E),
    { { id = "\\", sc = 0x2B }, named("return", nil, 1.25, { part = 2 }) }))
  add_row(ROW_Y[5], 0, concat({ modifier("left shift", "Shift", "shift", 1.25), { id = "nonusbackslash", sc = 0x56 } },
    text_keys("zxcvbnm,./", 0x2C), { modifier("right shift", "Shift", "shift", 2.75) }))
  add_row(ROW_Y[6], 0, {
    modifier("left ctrl", "Ctrl", "ctrl", 1.25), modifier("left gui", "Win", nil, 1.25),
    modifier("left alt", "Alt", "alt", 1.25), named("space", nil, 5.75), modifier("right alt", "AltGr", nil, 1.25),
    modifier("right ctrl", "Ctrl", "ctrl", 1.25), named("left", "←"),
    named("up", "↑", 1, { h = 0.5 }), named("down", "↓", 1, { x = 13, y = ROW_Y[6] + 0.5, h = 0.5 }),
    named("right", "→"),
  })
end
KeyboardMap.layout = LAYOUT
local BOARD_W, BOARD_H = 15, ROW_Y[6] + 1

------------------------------------------------------------------------------------------------------------------
-- The model

local CTRL, SHIFT, ALT = 1, 2, 4
local MOD_BITS = { ctrl = CTRL, shift = SHIFT, alt = ALT }
-- The order in which the details list each key's layers.
local LAYERS = { 0, SHIFT, CTRL, CTRL + SHIFT, ALT, ALT + SHIFT, CTRL + ALT, CTRL + ALT + SHIFT }
local EMPTY = {}

---The keymap stroke of `name` with the modifiers in `mask`, in the keymap's order, such as "ctrl+shift+a".
function KeyboardMap.stroke(name, mask)
  return (mask % 2 >= 1 and "ctrl+" or "") .. (mask % 4 >= 2 and "shift+" or "")
    .. (mask >= 4 and "alt+" or "") .. name
end

---The texts that a physical key types: plain, with Shift and with AltGr. Windows only.
function KeyboardMap.layout_text(scancode)
  if not keyboard then return nil end
  return keyboard.layout_text(scancode)
end

local chords
---Alt Navigation chords by physical key id and held modifiers.
local function chord_for(id, mask)
  if not chords then
    chords = {}
    for _, chord in ipairs(keyboard and keyboard.alt_navigation_chords() or EMPTY) do
      local target_mask = (chord.target_ctrl and CTRL or 0) + (chord.target_shift and SHIFT or 0)
        + (chord.target_alt and ALT or 0)
      chord.target_stroke = KeyboardMap.stroke(chord.target, target_mask)
      local held = ALT + (chord.ctrl and CTRL or 0) + (chord.shift and SHIFT or 0)
      chords[chord.key] = chords[chord.key] or {}
      chords[chord.key][held] = chord
    end
  end
  return chords[id] and chords[id][mask]
end

---What a physical key does on one layer. `commands` are the keymap's candidates, in the order that it tries them.
---With Alt Navigation, a chord gives the commands of the stroke that it types, `target`, and `hidden` holds the
---commands that the chord keeps from running.
---@return { stroke: string, commands: table, target: string?, count: integer?, hidden: table? }
function KeyboardMap.resolve(id, name, mask, alt_navigation, into)
  local entry = into or {}
  entry.stroke = KeyboardMap.stroke(name, mask)
  local chord = alt_navigation and mask >= ALT and chord_for(id, mask)
  if chord then
    entry.target, entry.count = chord.target_stroke, chord.count
    entry.commands = keymap.map[chord.target_stroke] or EMPTY
    entry.hidden = keymap.map[entry.stroke]
  else
    entry.target, entry.count, entry.hidden = nil, nil, nil
    entry.commands = keymap.map[entry.stroke] or EMPTY
  end
  return entry
end

---The candidate that a key runs in most places. The keymap tries contextual commands first, such as the
---Fuzzy Searcher's, and ends with the general command. Dialog and prompt commands only fill gaps.
function KeyboardMap.main_command(commands)
  for i = #commands, 1, -1 do
    local name = commands[i]
    if type(name) ~= "string" or not (name:find("dialog", 1, true) or name:find("prompt", 1, true)) then
      return name
    end
  end
  return commands[#commands]
end

---A command's namespace and its words, such as "editor", "move lines up".
function KeyboardMap.command_parts(name)
  if type(name) ~= "string" then
    local info = debug.getinfo(name, "S")
    local path = info.source:gsub("^@", "")
    for _, dir in ipairs({ DATADIR, USERDIR }) do
      if path:sub(1, #dir + 1) == dir .. PATHSEP then path = path:sub(#dir + 2) end
    end
    return "function", path .. ":" .. tostring(info.linedefined)
  end
  local namespace, rest = name:match("^([^:]*):(.*)$")
  return namespace or "", ((rest or name):gsub("_", " "))
end

---True when each word of the query is in the command's name.
function KeyboardMap.matches(name, words)
  if type(name) ~= "string" or #words == 0 then return false end
  local text = name:lower():gsub("_", " ")
  for _, word in ipairs(words) do
    if not text:find(word, 1, true) then return false end
  end
  return true
end

------------------------------------------------------------------------------------------------------------------
-- Labels

local function first_codepoint(text)
  local a, b = text:byte(1, 2)
  if not a then return nil, 0 end
  if a < 0x80 then return a, 1 end
  if a >= 0xC0 and a < 0xE0 and b then return (a - 0xC0) * 64 + (b - 0x80), 2 end
  return nil, #text
end

-- A letter key types a lowercase letter and its capital with Shift, such as ñ and Ñ.
local function letter_pair(plain, shifted)
  if not (plain and shifted) then return false end
  local p, plen = first_codepoint(plain)
  local s, slen = first_codepoint(shifted)
  if not (p and s) or plen ~= #plain or slen ~= #shifted then return false end
  local lower = (p >= 0x61 and p <= 0x7A) or (p >= 0xE0 and p <= 0xFE and p ~= 0xF7)
  return lower and s == p - 0x20
end

local PRETTY = {
  ["return"] = "Enter", escape = "Esc", backspace = "Backspace", delete = "Del", pageup = "PgUp",
  pagedown = "PgDn", left = "←", right = "→", up = "↑", down = "↓", space = "Space", plus = "+",
  ["keypad enter"] = "Keypad Enter",
}

------------------------------------------------------------------------------------------------------------------
-- The View

function KeyboardMap:new(state)
  KeyboardMap.super.new(self)
  state = state or {}
  self.scrollable = true
  self.layer = state.layer or 0
  self.selected = state.selected
  self.alt_navigation = state.alt_navigation
  if self.alt_navigation == nil then self.alt_navigation = config.plugins.keyboard_map.alt_navigation end
  self.field = TextField({
    text = state.query, placeholder = "Filter commands",
    on_change = function(text) self:set_query(text) end,
  })
  self.keys = {}
  self.words = {}
  self.matches = {}
  self.rows = {}
  self.content_h = 0
  self:refresh()
end

function KeyboardMap:get_state()
  return { layer = self.layer, selected = self.selected, alt_navigation = self.alt_navigation,
    query = self.field:get_text() }
end

function KeyboardMap.from_state(state)
  return KeyboardMap(state)
end

---Read the keyboard layout and the keymap again.
function KeyboardMap:refresh()
  self.name_labels = {}
  for _, spec in ipairs(LAYOUT) do
    local key = self.keys[spec] or {}
    self.keys[spec] = key
    if spec.sc then
      local plain, shifted, altgr = KeyboardMap.layout_text(spec.sc)
      local byte = plain and #plain == 1 and plain:byte()
      key.name = (byte and byte > 0x20 and byte < 0x7F) and plain:lower() or spec.id
      if key.name == "+" then key.name = "plus" end
      if letter_pair(plain, shifted) then
        key.label, key.shift_label = shifted, nil
      else
        key.label = plain or spec.id:upper()
        key.shift_label = shifted ~= plain and shifted or nil
      end
      key.altgr_label = altgr
    else
      key.name, key.label = spec.name, spec.label
    end
    if key.name and key.label and not self.name_labels[key.name] then self.name_labels[key.name] = key.label end
  end
  self.shown_layer = nil
  self:set_query(self.field:get_text())
  core.redraw = true
end

---The layer that shows: the held modifiers, or else the layer that the user chose.
function KeyboardMap:current_layer()
  local held = (keymap.modkeys.ctrl and CTRL or 0) + (keymap.modkeys.shift and SHIFT or 0)
    + (keymap.modkeys.alt and ALT or 0)
  return held ~= 0 and held or self.layer
end

-- Resolve each key on the shown layer. Only a layer, keymap or filter change does this, not each frame.
function KeyboardMap:resolve_keys()
  local layer = self:current_layer()
  if self.shown_layer == layer then return end
  self.shown_layer = layer
  for _, spec in ipairs(LAYOUT) do
    local key = self.keys[spec]
    key.entry = key.name and not spec.mod and KeyboardMap.resolve(spec.id, key.name, layer, self.alt_navigation,
      key.entry) or nil
    key.main = key.entry and KeyboardMap.main_command(key.entry.commands)
    key.lines_width = nil
    key.match = false
    if key.entry and #self.words > 0 then
      for _, name in ipairs(key.entry.commands) do
        if KeyboardMap.matches(name, self.words) then key.match = true end
      end
    end
  end
  self.details = nil
end

local function stroke_layer(stroke)
  return (stroke:find("ctrl+", 1, true) and CTRL or 0) + (stroke:find("shift+", 1, true) and SHIFT or 0)
    + (stroke:find("alt+", 1, true) and ALT or 0)
end

---A stroke as the user reads it, with the layout's key labels, such as "Ctrl+Ñ".
function KeyboardMap:stroke_text(stroke)
  local parts = {}
  for part in stroke:gmatch("[^+]+") do parts[#parts + 1] = part end
  local key = parts[#parts]
  parts[#parts] = self.name_labels[key] or PRETTY[key]
    or (#key == 1 and key:upper() or key:sub(1, 1):upper() .. key:sub(2))
  for i = 1, #parts - 1 do parts[i] = parts[i]:sub(1, 1):upper() .. parts[i]:sub(2) end
  return table.concat(parts, "+")
end

-- A line of the details: a command with its namespace, or a note.
local function command_line(name, kind)
  local namespace, words = KeyboardMap.command_parts(name)
  return { prefix = namespace ~= "" and namespace .. ": " or "", text = words, kind = kind }
end

---The strokes whose commands match the filter. Each row names the key that shows it on the board: the key with
---the stroke's own name, or else the Alt chord that types it.
function KeyboardMap:set_query(text)
  if text ~= self.query then self.scroll.to.y = 0 end
  self.query = text
  self.words = {}
  for word in text:lower():gmatch("%S+") do self.words[#self.words + 1] = word end
  local typed_by, hidden = {}, {}
  if self.alt_navigation then
    for _, spec in ipairs(LAYOUT) do
      local key = self.keys[spec]
      for _, mask in ipairs(LAYERS) do
        local chord = key.name and mask >= ALT and chord_for(spec.id, mask)
        if chord then
          typed_by[chord.target_stroke] = typed_by[chord.target_stroke] or { spec = spec, layer = mask }
          hidden[KeyboardMap.stroke(key.name, mask)] = true
        end
      end
    end
  end
  local by_name = {}
  for _, spec in ipairs(LAYOUT) do
    local name = self.keys[spec].name
    if name and not spec.mod and not by_name[name] then by_name[name] = spec end
  end
  self.matches = {}
  if #self.words > 0 then
    for stroke, commands in pairs(keymap.map) do
      local row = { stroke = stroke, label = self:stroke_text(stroke), lines = {}, dim = hidden[stroke] }
      for _, name in ipairs(commands) do
        if KeyboardMap.matches(name, self.words) then row.lines[#row.lines + 1] = command_line(name) end
      end
      if #row.lines > 0 then
        local chord = typed_by[stroke]
        row.spec, row.layer = by_name[stroke:match("([^+]+)$")], stroke_layer(stroke)
        if chord then
          row.label = row.label .. "  (" .. self:stroke_text(KeyboardMap.stroke(self.keys[chord.spec].name,
            chord.layer)) .. ")"
          if not row.spec then row.spec, row.layer = chord.spec, chord.layer end
        end
        self.matches[#self.matches + 1] = row
      end
    end
    table.sort(self.matches, function(a, b) return a.stroke < b.stroke end)
  end
  self.match_heading = #self.words > 0
    and (#self.matches == 0 and "No bindings" or #self.matches .. (#self.matches == 1 and " binding" or " bindings"))
    or nil
  self.shown_layer = nil
  core.redraw = true
end

---The details of a key: all its layers, each with its stroke and commands.
function KeyboardMap:key_details(spec)
  local key = self.keys[spec]
  local details = { spec = spec, title = key.label or spec.id, rows = {} }
  local entry = {}
  for _, mask in ipairs(LAYERS) do
    KeyboardMap.resolve(spec.id, key.name, mask, self.alt_navigation, entry)
    if #entry.commands > 0 or entry.target or entry.hidden or mask == self.shown_layer then
      local row = { spec = spec, layer = mask, label = self:stroke_text(entry.stroke), lines = {} }
      if entry.target then
        row.lines[1] = { prefix = "", kind = "good",
          text = "→ " .. self:stroke_text(entry.target) .. (entry.count > 1 and " ×" .. entry.count or "") }
      end
      for _, name in ipairs(entry.commands) do row.lines[#row.lines + 1] = command_line(name) end
      for _, name in ipairs(entry.hidden or EMPTY) do
        local line = command_line(name, "dim")
        line.prefix = "not reached: " .. line.prefix
        row.lines[#row.lines + 1] = line
      end
      if #row.lines == 0 then row.lines[1] = { prefix = "", text = "—", kind = "dim" } end
      details.rows[#details.rows + 1] = row
    end
  end
  return details
end

------------------------------------------------------------------------------------------------------------------
-- Geometry

local small_fonts = setmetatable({}, { __mode = "k" })
local function small_font()
  local font = ui.font()
  small_fonts[font] = small_fonts[font] or font:copy(math.max(1, math.floor(font:get_size() * 0.8 + 0.5)))
  return small_fonts[font]
end

function KeyboardMap:layout_geometry()
  local pad = math.floor(16 * SCALE + 0.5)
  local m = ui.metrics()
  local x, y = self:get_content_offset()
  local w = self.size.x - 2 * pad
  self.pad = pad
  self.field:set_rect(x + pad, y + pad, math.min(math.floor(360 * SCALE), w), m.control_h)
  local chip_w = ui.font():get_width("Alt Navigation") + m.control_h + m.gap
  self.chip = self.chip or {}
  self.chip.x, self.chip.y, self.chip.w, self.chip.h = x + pad + w - chip_w, y + pad, chip_w, m.control_h
  self.unit = math.max(24 * SCALE, math.min(68 * SCALE, w / BOARD_W))
  self.board_x = x + pad + math.max(0, math.floor((w - BOARD_W * self.unit) / 2))
  self.board_y = y + pad + m.control_h + pad
  self.details_y = self.board_y + BOARD_H * self.unit + pad
end

function KeyboardMap:key_rect(spec)
  local u, gap = self.unit, math.max(2, math.floor(self.unit * 0.08))
  return self.board_x + spec.x * u + gap / 2, self.board_y + spec.y * u + gap / 2, spec.w * u - gap, spec.h * u - gap
end

function KeyboardMap:spec_at(px, py)
  for _, spec in ipairs(LAYOUT) do
    local x, y, w, h = self:key_rect(spec)
    if px >= x and py >= y and px < x + w and py < y + h then return spec end
  end
end

local function inside(rect, x, y)
  return rect and x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end

function KeyboardMap:get_scrollable_size()
  return self.content_h
end

------------------------------------------------------------------------------------------------------------------
-- Input

function KeyboardMap:update()
  local active = core.active_view == self
  if active and not self.was_active then self:refresh() end
  self.was_active = active
  if self.shown_layer ~= self:current_layer() then core.redraw = true end
  KeyboardMap.super.update(self)
end

function KeyboardMap:on_mouse_moved(x, y, dx, dy)
  if KeyboardMap.super.on_mouse_moved(self, x, y, dx, dy) then return true end
  if self.field.pressed then return self.field:on_mouse_moved(x, y) end
  local spec = self.unit and self:spec_at(x, y)
  if spec ~= self.hovered then
    self.hovered = spec
    core.redraw = true
  end
  local row = self:row_at(x, y)
  if row ~= self.hovered_row then
    self.hovered_row = row
    core.redraw = true
  end
  if self.field:contains(x, y) then
    core.request_cursor("ibeam")
  elseif (spec and (spec.mod or self.keys[spec].name)) or row or inside(self.chip, x, y) then
    core.request_cursor("hand")
  else
    core.request_cursor("arrow")
  end
end

function KeyboardMap:on_mouse_left()
  KeyboardMap.super.on_mouse_left(self)
  self.hovered, self.hovered_row = nil, nil
  core.redraw = true
end

function KeyboardMap:row_at(x, y)
  for i = 1, self.row_count or 0 do
    local row = self.rows[i]
    if inside(row, x, y) then return row end
  end
end

---Show `layer` and select the key `spec`.
function KeyboardMap:show_key(spec, layer)
  if layer then self.layer = layer end
  self.selected = spec and spec.id
  self.shown_layer = nil
  core.redraw = true
end

function KeyboardMap:on_mouse_pressed(button, x, y, clicks)
  if KeyboardMap.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return true end
  if self.field:contains(x, y) then
    self.field.pressed = true
    return self.field:on_mouse_pressed(x, y, clicks)
  end
  if inside(self.chip, x, y) then
    self.alt_navigation = not self.alt_navigation
    self:set_query(self.field:get_text())
    return true
  end
  local row = self:row_at(x, y)
  if row then
    self:show_key(row.spec, row.layer)
    return true
  end
  local spec = self:spec_at(x, y)
  if spec and spec.mod then
    self.layer = bit.bxor(self.layer, MOD_BITS[spec.mod])
    self.shown_layer = nil
    core.redraw = true
  elseif spec and self.keys[spec].name then
    self:show_key(self.selected ~= spec.id and spec or nil)
  end
  return true
end

function KeyboardMap:on_mouse_released(button, x, y)
  KeyboardMap.super.on_mouse_released(self, button, x, y)
  if self.field.pressed then
    self.field.pressed = false
    self.field:on_mouse_released(x, y)
  end
end

function KeyboardMap:on_text_input(text)
  self.field:on_text(text)
end

-- The keymap's commands for the editor do not run in this View, so its keys come here.
-- The filter takes the editor's line commands, with the user's bindings.
function KeyboardMap:on_key_pressed(key, event)
  if keymap.is_modifier_key(key) then
    core.redraw = true
    return false
  end
  local stroke = keymap.stroke_for_event(key, event)
  for _, name in ipairs(keymap.map[stroke] or EMPTY) do
    local line_command = type(name) == "string" and name:match("^core:(.+)$")
    if line_command and self.field:perform(line_command) then return true end
  end
  if key == "escape" and self.field:get_text() ~= "" then
    self.field:set_text("")
    self:set_query("")
    return true
  end
  return false
end

function KeyboardMap:on_key_released()
  core.redraw = true
end

------------------------------------------------------------------------------------------------------------------
-- Drawing

local ENTER_TOP
for _, spec in ipairs(LAYOUT) do
  if spec.id == "return" and not spec.part then ENTER_TOP = spec end
end

-- The command label of a key, cut into lines that fit its width.
local function key_lines(key, font, width, max_lines)
  if key.lines_width == width and key.lines_max == max_lines then return key.lines end
  key.lines_width, key.lines_max, key.lines = width, max_lines, {}
  if not key.main then return key.lines end
  local _, words = KeyboardMap.command_parts(key.main)
  local line = ""
  for word in words:gmatch("%S+") do
    local next_line = line == "" and word or line .. " " .. word
    if font:get_width(next_line) <= width or line == "" then
      line = next_line
    else
      key.lines[#key.lines + 1] = line
      line = word
    end
  end
  key.lines[#key.lines + 1] = line
  if #key.lines > max_lines then
    key.lines[max_lines] = table.concat(key.lines, " ", max_lines)
    for i = #key.lines, max_lines + 1, -1 do key.lines[i] = nil end
  end
  for i, text in ipairs(key.lines) do key.lines[i] = ui.fit_text(font, text, width) end
  return key.lines
end

local function layer_has(layer, spec)
  return spec.mod ~= nil and bit.band(layer, MOD_BITS[spec.mod]) ~= 0
end

function KeyboardMap:key_color(spec, key, layer)
  local base = style.background2
  if spec.mod then return layer_has(layer, spec) and style.accent or base end
  local entry = key.entry
  if not entry or (#entry.commands == 0 and not entry.target) then return base end
  if #self.words > 0 then return key.match and ui.mix(base, style.accent, 0.55) or base end
  if entry.target then return ui.mix(base, style.good, 0.28) end
  return ui.mix(base, style.accent, 0.22)
end

function KeyboardMap:draw_key(spec, layer)
  local key = self.keys[spec]
  local x, y, w, h = self:key_rect(spec)
  local r = math.floor(4 * SCALE + 0.5)
  local color = self:key_color(spec, key, layer)
  local hovered = self.hovered and self.hovered.id == spec.id
  if self.selected == spec.id then
    local ring = math.max(1, math.floor(2 * SCALE + 0.5))
    renderer.draw_rounded_rect(x - ring, y - ring, w + 2 * ring, h + 2 * ring, r + ring, style.accent)
  end
  renderer.draw_rounded_rect(x, y, w, h, r, color)
  if hovered then renderer.draw_rounded_rect(x, y, w, h, r, ui.fade(style.text, 0.08)) end
  if spec.part == 2 then
    -- The lower part of the ISO Enter key joins the upper part.
    local _, top_y, _, top_h = self:key_rect(ENTER_TOP)
    local join_y, join_h = top_y + top_h - r, y - top_y - top_h + 2 * r
    renderer.draw_rect(x, join_y, w, join_h, color)
    if hovered then renderer.draw_rect(x, join_y, w, join_h, ui.fade(style.text, 0.08)) end
    return
  end
  local font, small = ui.font(), small_font()
  local inset = math.floor(5 * SCALE + 0.5)
  local top = y + math.floor(inset * 0.6)
  if key.label then
    renderer.draw_text(font, key.label, x + inset, top, layer_has(layer, spec) and style.background or style.text)
  end
  if key.shift_label then
    renderer.draw_text(small, key.shift_label, x + w - inset - small:get_width(key.shift_label), top, style.dim)
  end
  if key.altgr_label then
    renderer.draw_text(small, key.altgr_label, x + w - inset - small:get_width(key.altgr_label),
      top + small:get_height(), style.dim)
  end
  if key.main then
    local label_h = key.label and font:get_height() or 0
    local max_lines = math.floor((h - label_h - inset) / small:get_height())
    if max_lines < 1 then return end
    local lines = key_lines(key, small, w - 2 * inset, max_lines)
    local ty = y + h - math.floor(inset * 0.6) - #lines * small:get_height()
    local text_color = key.entry.target and style.good or style.text
    if #self.words > 0 and not key.match then text_color = style.dim end
    for _, line in ipairs(lines) do
      renderer.draw_text(small, line, x + inset, ty, text_color)
      ty = ty + small:get_height()
    end
  end
end

-- Rows of strokes and their command lines. A click on a row shows its key and layer on the board.
function KeyboardMap:draw_rows(rows, x, y, w, marked_layer)
  local font = ui.font()
  local line_h = font:get_height() + math.floor(4 * SCALE)
  local stroke_x = x + math.floor(10 * SCALE)
  local stroke_w = math.floor(190 * SCALE)
  for _, row in ipairs(rows) do
    local h = #row.lines * line_h
    row.x, row.y, row.w, row.h = x, y, w, h
    if row.spec then
      self.row_count = self.row_count + 1
      self.rows[self.row_count] = row
      if self.hovered_row == row then renderer.draw_rect(x, y, w, h, ui.fade(style.text, 0.06)) end
    end
    if marked_layer and row.layer == marked_layer then
      renderer.draw_rect(x, y, math.max(1, math.floor(3 * SCALE)), h, style.accent)
    end
    renderer.draw_text(font, ui.fit_text(font, row.label, stroke_w - (stroke_x - x)), stroke_x, y,
      row.dim and style.dim or style.text)
    local cy = y
    for _, line in ipairs(row.lines) do
      local color = (row.dim or line.kind == "dim") and style.dim or line.kind == "good" and style.good or style.text
      local cx = renderer.draw_text(font, line.prefix, x + stroke_w, cy, line.kind and color or style.dim)
      renderer.draw_text(font, ui.fit_text(font, line.text, x + w - cx), cx, cy, color)
      cy = cy + line_h
    end
    y = y + h
  end
  return y
end

function KeyboardMap:draw_heading(text, x, y)
  renderer.draw_text(ui.bold_font(), text, x, y, style.text)
  return y + ui.bold_font():get_height() + math.floor(6 * SCALE)
end

---The key whose details show: the hovered key, or else the selected key.
function KeyboardMap:details_spec()
  local hovered = self.hovered
  if hovered and not hovered.mod and self.keys[hovered].name then
    return hovered.part and ENTER_TOP or hovered
  end
  if self.selected then
    for _, spec in ipairs(LAYOUT) do
      if spec.id == self.selected and not spec.part then return spec end
    end
  end
end

function KeyboardMap:draw()
  self:draw_background(style.background)
  self:resolve_keys()
  self:layout_geometry()
  local layer = self.shown_layer
  self.field:draw(core.active_view == self)
  local m = ui.metrics()
  local font = ui.font()
  local box = font:get_height()
  local chip = self.chip
  ui.draw_check_box(chip.x, chip.y + math.floor((chip.h - box) / 2), box, self.alt_navigation and 1 or 0)
  renderer.draw_text(font, "Alt Navigation", chip.x + box + m.gap,
    chip.y + math.floor((chip.h - font:get_height()) / 2), style.text)
  for _, spec in ipairs(LAYOUT) do self:draw_key(spec, layer) end

  self.row_count = 0
  local x, w = self.board_x, BOARD_W * self.unit
  local y = self.details_y
  if self.match_heading then
    y = self:draw_heading(self.match_heading, x, y)
    y = self:draw_rows(self.matches, x, y, w) + self.pad
  end
  local spec = self:details_spec()
  if spec then
    if not (self.details and self.details.spec == spec) then self.details = self:key_details(spec) end
    y = self:draw_heading(self.details.title, x, y)
    y = self:draw_rows(self.details.rows, x, y, w, layer)
  end
  self.content_h = y + self.pad - (self.position.y - self.scroll.y)
  self:draw_scrollbar()
end

------------------------------------------------------------------------------------------------------------------

command.add(nil, {
  ["keyboard_map:open"] = command.palette(function()
    panes.place(function() return KeyboardMap() end, {
      placement = "current",
      focus = true,
      reason = "open-keyboard-map",
    })
  end, {
    keywords = { "shortcuts", "keys", "bindings", "keymap", "keybindings", "cheatsheet" },
    opens_view = true,
  }),
})

return KeyboardMap
