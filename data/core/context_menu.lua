local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local card = require "core.card"
local popup = require "core.popup"
local RowHighlight = require "core.row_highlight"
local LineInput = require "core.line_input"

---A Context Menu: a small card of commands that opens at the pointer.
---Each item runs a command, so a menu adds no behavior of its own. Items whose command
---is not valid do not show. Each item shows the command's shortcut.
---
---An item is `"-"` for a separator, or a table:
---  `label`   the visible name
---  `icon`    a glyph or draw function from `context_menu.icons`; functions receive (x, y, height, color)
---  `command` a command name, or a list of names; the first valid one runs
---  `args`    arguments for the command and its predicate
---  `items`   a submenu instead of a command
---
---Typed text filters the menu with a fuzzy query, also the items of submenus.
---
---The menu opens over a host panel: the Root Panel, or a Project Sidebar's surface. The host has `position` and
---`size`, takes the menu's input through `push_modal_input` and `pop_modal_input`, gets a press outside the menu
---through `on_mouse_pressed`, and shows the menu above the other layer through `show_above_sidebar`.
local context_menu = {}

---Icons for menu items: Material Design glyphs from the bundled Nerd Font, or draw functions for program logos.
context_menu.icons = {
  open = "\u{F03CC}", definition = "\u{F0169}", search = "\u{F0349}",
  cut = "\u{F0190}", copy = "\u{F018F}", paste = "\u{F0192}", select_all = "\u{F0486}",
  bold = "\u{F0264}", italic = "\u{F0277}", strikethrough = "\u{F0280}", code = "\u{F0174}", link = "\u{F0339}",
  text = "\u{F0284}", heading_1 = "\u{F026B}", heading_2 = "\u{F026C}", heading_3 = "\u{F026D}",
  bullet_list = "\u{F0279}", numbered_list = "\u{F027B}", task_list = "\u{F0756}", quote = "\u{F0757}",
  table = "\u{F04EB}", code_block = "\u{F0169}", callout = "\u{F02FD}", footnote = "\u{F0283}",
  note = "\u{F1782}", edit = "\u{F0CB6}", delete = "\u{F09E7}", preview = "\u{F06D0}", source = "\u{F0F5B}",
  row_above = "\u{F04F4}", row_below = "\u{F04F3}", row_delete = "\u{F04F5}",
  column_left = "\u{F04ED}", column_right = "\u{F04EC}", column_delete = "\u{F04EE}",
  align_left = "\u{F0262}", align_center = "\u{F0260}", align_right = "\u{F0263}",
  sort_ascending = "\u{F05BD}", sort_descending = "\u{F05BF}", tidy = "\u{F0068}",
  file = "\u{F0224}", split_right = "\u{F0BCC}", split_down = "\u{F0BCB}",
  new_file = "\u{F0EED}", new_folder = "\u{F0B9D}", rename = "\u{F0455}", path = "\u{F0A38}",
  reveal = "\u{F0DCF}", terminal = "\u{F018D}", sort = "\u{F04BA}",
  close = "\u{F0156}", close_others = "\u{F0C5E}", reopen = "\u{F099B}",
  insert = "\u{F0704}", format = "\u{F06D6}", reset = "\u{F0450}",
  pi = function(x, y, height) require("core.agent_icons").draw("pi", x, y, height) end,
}


local OPEN_DURATION = 0.09
local SUBMENU_DELAY = 0.18

---@type table|nil
local state
local modal_handlers

local function now() return system.get_time() end

local function metrics()
  local font = style.font
  return {
    font = font,
    icon_font = style.menu_icon_font,
    icon_w = math.floor(26 * SCALE),
    pad = math.floor(4 * SCALE),
    row_h = font:get_height() + math.floor(9 * SCALE),
    row_x = math.floor(10 * SCALE),
    gap = math.floor(28 * SCALE),
    min_w = math.floor(170 * SCALE),
    sep_h = math.floor(9 * SCALE),
    radius = math.floor(8 * SCALE),
    row_radius = math.floor(5 * SCALE),
    margin = math.floor(6 * SCALE),
  }
end

---"ctrl+shift+l" reads as "Ctrl+Shift+L".
local function shortcut_text(binding)
  if not binding or binding == "" then return nil end
  local parts = {}
  for part in binding:gmatch("[^+]+") do
    parts[#parts + 1] = #part == 1 and part:upper() or part:sub(1, 1):upper() .. part:sub(2)
  end
  if binding:sub(-1) == "+" then parts[#parts + 1] = "+" end
  return table.concat(parts, "+")
end

-- The first valid command of an item, or nil.
local function valid_command(item)
  local names = type(item.command) == "table" and item.command or { item.command }
  local args = item.args or {}
  for _, name in ipairs(names) do
    if command.is_valid(name, table.unpack(args)) then return name end
  end
end

local function binding_for(item, chosen)
  local names = type(item.command) == "table" and item.command or { item.command }
  local binding = keymap.get_binding(chosen)
  for _, name in ipairs(names) do
    if binding then break end
    binding = keymap.get_binding(name)
  end
  return shortcut_text(binding)
end

-- Removes items that cannot run, empty submenus, and extra separators.
local function resolve(items)
  local rows = {}
  for _, item in ipairs(items or {}) do
    if item == "-" then
      if #rows > 0 and not rows[#rows].separator then rows[#rows + 1] = { separator = true } end
    elseif item.items then
      local children = resolve(item.items)
      if #children > 0 then rows[#rows + 1] = { label = item.label, icon = item.icon, items = children } end
    else
      local name = valid_command(item)
      if name then
        rows[#rows + 1] = { label = item.label, icon = item.icon, command = name, args = item.args or {},
          shortcut = binding_for(item, name) }
      end
    end
  end
  if #rows > 0 and rows[#rows].separator then rows[#rows] = nil end
  return rows
end

-- Rows that the keyboard and pointer can select: not separators and not the query field.
local function selectable(row) return not (row.separator or row.field) end

-- The next selectable row after `from` in the direction of `delta`, wrapping around. Without `from`, the first or last.
local function step(level, from, delta)
  local count = #level.rows
  local index = from or (delta > 0 and 0 or count + 1)
  for _ = 1, count do
    index = (index + delta - 1) % count + 1
    if selectable(level.rows[index]) then return index end
  end
end

local PATH_SEPARATOR = " \u{203A} "

-- The query field, then the command rows of all levels that match the query, best match first.
-- A submenu's item shows its path.
local function filtered_rows(rows, query)
  local candidates = {}
  local function collect(list, path)
    for _, row in ipairs(list) do
      if row.items then
        collect(row.items, path and path .. PATH_SEPARATOR .. row.label or row.label)
      elseif row.command then
        candidates[#candidates + 1] = { row = row, path = path, text = path and path .. " " .. row.label or row.label }
      end
    end
  end
  collect(rows)
  local result = { { field = true }, { separator = true } }
  for _, match in ipairs(common.fuzzy_match(candidates, query)) do
    local row = match.row
    result[#result + 1] = { label = row.label, icon = row.icon, command = row.command, args = row.args,
      shortcut = row.shortcut, path = match.path }
  end
  return result
end

-- Lays out one level of rows with its top left corner near (x, y).
-- `flip_x` is the x to use when the level does not fit to the right of x.
local function layout_level(rows, x, y, flip_x, min_w)
  local m = metrics()
  local w = math.max(m.min_w, min_w or 0)
  -- A level with an icon gives every row an icon column, so the labels line up.
  local icon_w = 0
  for _, row in ipairs(rows) do
    if row.icon then icon_w = m.icon_w end
  end
  for _, row in ipairs(rows) do
    if row.label then
      local label_w = icon_w + m.font:get_width(row.label)
        + (row.path and m.font:get_width(row.path .. PATH_SEPARATOR) or 0)
      local extra = row.shortcut and m.gap + m.font:get_width(row.shortcut) or (row.items and m.gap) or 0
      w = math.max(w, label_w + extra + m.row_x * 2 + m.pad * 2)
    end
  end
  local h = m.pad * 2
  for _, row in ipairs(rows) do h = h + (row.separator and m.sep_h or m.row_h) end
  x, y, w = popup.place(state.host, x, y, w, h, flip_x, m.margin)
  local level = { rows = rows, x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h), icon_w = icon_w,
    highlight = RowHighlight(RowHighlight.selection) }
  local ry = level.y + m.pad
  for _, row in ipairs(rows) do
    local rh = row.separator and m.sep_h or m.row_h
    row.x, row.y, row.w, row.h = level.x + m.pad, ry, level.w - m.pad * 2, rh
    ry = ry + rh
  end
  return level
end

local contains = popup.contains

-- The deepest level and row under the point.
local function hit(x, y)
  for depth = #state.levels, 1, -1 do
    local level = state.levels[depth]
    if contains(level, x, y) then
      for index, row in ipairs(level.rows) do
        if selectable(row) and contains(row, x, y) then return depth, index end
      end
      return depth
    end
  end
end

local function close_below(depth)
  for i = #state.levels, depth + 1, -1 do state.levels[i] = nil end
end

local function open_submenu(depth, index, select_first)
  local level = state.levels[depth]
  local row = level.rows[index]
  close_below(depth)
  if not (row and row.items) then return end
  local m = metrics()
  local child = layout_level(row.items, level.x + level.w - m.pad, row.y - m.pad, level.x + m.pad)
  child.selected = select_first and 1 or nil
  child.parent = index
  state.levels[depth + 1] = child
  core.redraw = true
end

local function select(depth, index)
  local level = state.levels[depth]
  if level.selected == index then return end
  level.selected = index
  -- A submenu follows the hovered row after a short rest, so a diagonal move does not close it.
  state.pending = { depth = depth, index = index, since = now() }
  core.redraw = true
end

---True while a Context Menu is open.
function context_menu.is_open() return state ~= nil end

---Closes the open menu without running a command.
function context_menu.close()
  if not state then return end
  local host = state.host
  state = nil
  host:pop_modal_input(context_menu)
  core.redraw = true
end

---Opens a menu at the point. Returns false when no item can run.
---@param x number
---@param y number
---@param items table[]
---@param opts? { button: string?, host: table? } `button` is the mouse button that opened the menu, so its release
---does not choose an item. A menu without `button` opened from the keyboard, so its first item is selected.
---`host` is the panel that the menu opens over, the Root Panel by default.
function context_menu.open(x, y, items, opts)
  context_menu.close()
  local rows = resolve(items)
  if #rows == 0 then
    core.log_quiet("Context Menu: nothing to show at %d,%d", x, y)
    return false
  end
  opts = opts or {}
  local host = opts.host or core.root_panel
  state = {
    host = host,
    started = now(),
    progress = config.transitions and 0 or 1,
    origin = { x = x, y = y, button = opts.button },
    root_size = { host.size.x, host.size.y },
    rows = rows,
    input = LineInput(),
  }
  state.levels = { layout_level(rows, x + 1, y + 1, x - 1) }
  if not opts.button then state.levels[1].selected = step(state.levels[1], nil, 1) end
  host:push_modal_input(context_menu, { label = "context-menu", handlers = modal_handlers })
  core.log_quiet("Context Menu opened: %d row(s) at %d,%d", #rows, x, y)
  core.redraw = true
  return true
end

---The visible labels of one level, with "-" for separators. Level 1 is the menu itself.
---@param depth? integer
---@return string[]
function context_menu.labels(depth)
  local level = state and state.levels[depth or 1]
  local labels = {}
  for _, row in ipairs(level and level.rows or {}) do
    if not row.field then labels[#labels + 1] = row.separator and "-" or row.label end
  end
  return labels
end

---The label of the selected row in the deepest level, or nil.
function context_menu.selected_label()
  if not state then return nil end
  local level = state.levels[#state.levels]
  local row = level.selected and level.rows[level.selected]
  return row and row.label
end

local function activate(depth, index)
  local row = state.levels[depth].rows[index]
  if not row or not selectable(row) then return end
  if row.items then
    select(depth, index)
    open_submenu(depth, index, true)
    return
  end
  context_menu.close()
  core.log_quiet("Context Menu chose %s (%s)", row.label, row.command)
  command.perform(row.command, table.unpack(row.args))
end

---Runs the row with this label in the deepest open level. Returns false when it does not show.
function context_menu.choose(label)
  if not state then return false end
  local depth = #state.levels
  for index, row in ipairs(state.levels[depth].rows) do
    if row.label == label then
      activate(depth, index)
      return true
    end
  end
  return false
end

-- Lays out the menu's first level again: its own rows without a query, or else the rows that match the query.
-- The filtered level starts at the place of the unfiltered level and is not narrower.
local function relayout()
  local origin, old = state.origin, state.levels[1]
  close_below(1)
  state.pending = nil
  local level = layout_level(state.rows, origin.x + 1, origin.y + 1, origin.x - 1)
  if state.input.text ~= "" then
    level = layout_level(filtered_rows(state.rows, state.input.text), level.x, level.y, nil, level.w)
  end
  level.highlight = old.highlight
  state.levels[1] = level
end

-- Filters the menu again after the query changed, and selects the best match.
local function query_changed()
  relayout()
  local level = state.levels[1]
  if state.input.text ~= "" then level.selected = step(level, nil, 1) end
  core.log_quiet("Context Menu query: %d byte(s), %d row(s)", #state.input.text, #level.rows)
end

local line_commands = {}
for _, name in ipairs(LineInput.COMMANDS) do line_commands[name] = true end

-- Performs the user's line command for the key in the query field, such as Backspace. Without a query, only a
-- paste starts one. Returns false when the key has no such command.
local function edit_query(key, event)
  local stroke = keymap.stroke_for_event(key, event)
  for _, name in ipairs(keymap.map[stroke] or {}) do
    local edit = type(name) == "string" and name:match(":(.+)$")
    if edit and line_commands[edit] and (state.input.text ~= "" or edit == "paste") then
      local before = state.input.text
      state.input:perform(edit)
      if state.input.text ~= before then query_changed() end
      return true
    end
  end
  return false
end

local function on_key_pressed(key, event)
  if not state then return false end
  if keymap.is_modifier_key(key) then return "keymap" end
  local depth = #state.levels
  local level = state.levels[depth]
  local querying = state.input.text ~= ""
  local modkeys = keymap.modkeys
  if key == "escape" then
    if querying then
      state.input:set_text("")
      query_changed()
    elseif depth > 1 then close_below(depth - 1) else context_menu.close() end
  elseif key == "down" or key == "up" then
    level.selected = step(level, level.selected, key == "down" and 1 or -1)
    state.pending = nil
  elseif key == "return" or key == "keypad enter" or (key == "space" and not querying) then
    if level.selected then activate(depth, level.selected) end
  elseif edit_query(key, event) then
    -- The query field took the key.
  elseif key == "home" or key == "end" then
    level.selected = step(level, nil, key == "home" and 1 or -1)
  elseif key == "right" then
    if level.selected and level.rows[level.selected].items then open_submenu(depth, level.selected, true) end
  elseif key == "left" then
    if depth > 1 then close_below(depth - 1) end
  elseif not (modkeys.ctrl or modkeys.alt or modkeys.super or modkeys.cmd) then
    -- The key's text arrives in a later text event, and goes to the query.
    return "text"
  end
  core.redraw = true
  return true
end

local function on_text_input(text)
  if not state then return false end
  state.input:insert(text)
  query_changed()
  core.redraw = true
  return true
end

local function on_mouse_moved(x, y)
  if not state then return false end
  core.request_cursor("arrow")
  local depth, index = hit(x, y)
  if depth and index then
    select(depth, index)
  elseif not depth then
    local level = state.levels[#state.levels]
    if level.selected and not (level.rows[level.selected].items and state.levels[#state.levels + 1]) then
      level.selected = nil
      state.pending = nil
      core.redraw = true
    end
  end
  return true
end

local function on_mouse_pressed(button, x, y, clicks)
  if not state then return false end
  local depth, index = hit(x, y)
  if depth then
    state.pressed = { depth = depth, index = index }
    return true
  end
  local host = state.host
  context_menu.close()
  -- A right-click elsewhere opens the menu of that place instead.
  if button == "right" and not host:on_mouse_pressed(button, x, y, clicks) then
    keymap.on_mouse_pressed(button, x, y, clicks)
  end
  return true
end

local function on_mouse_released(button, x, y)
  if not state then return false end
  local origin, pressed = state.origin, state.pressed
  state.pressed = nil
  -- The release of the opening press chooses an item only after the pointer moved onto it.
  local opening = not pressed and origin.button == button
  if opening then
    origin.button = nil
    local slop = 4 * SCALE
    if math.abs(x - origin.x) <= slop and math.abs(y - origin.y) <= slop then return true end
  elseif not pressed then
    return true
  end
  local depth, index = hit(x, y)
  if depth and index then activate(depth, index) end
  return true
end

local function on_mouse_wheel()
  context_menu.close()
  return true
end

modal_handlers = {
  key_pressed = on_key_pressed,
  text_input = on_text_input,
  ime_text_editing = function() return true end,
  mouse_moved = on_mouse_moved,
  mouse_pressed = on_mouse_pressed,
  mouse_released = on_mouse_released,
  mouse_wheel = on_mouse_wheel,
  mouse_left = function() return true end,
}

---Returns true while the menu animates, so its host draws another frame.
function context_menu.update()
  if not state then return false end
  local size = state.host.size
  if state.root_size[1] ~= size.x or state.root_size[2] ~= size.y then
    -- The menu stays at its point, inside the new bounds. Submenus close.
    state.root_size = { size.x, size.y }
    local selected = state.levels[1].selected
    relayout()
    state.levels[1].selected = selected
    core.redraw = true
  end
  if state.progress < 1 then
    state.progress = common.clamp((now() - state.started) / OPEN_DURATION, 0, 1)
    core.redraw = true
  end
  local pending = state.pending
  if pending then
    if now() - pending.since >= SUBMENU_DELAY then
      state.pending = nil
      if state.levels[pending.depth] and state.levels[pending.depth].selected == pending.index then
        local next_level = state.levels[pending.depth + 1]
        if not (next_level and next_level.parent == pending.index) then open_submenu(pending.depth, pending.index) end
      end
    else
      core.redraw = true
    end
  end
  return state.progress < 1 or state.pending ~= nil
end

---The Window lost focus.
function context_menu.on_focus_lost() context_menu.close() end

local function draw_chevron(x, y, h, color)
  local s = math.max(1, math.floor(SCALE + 0.5))
  local size = math.floor(3 * SCALE)
  local cy = math.floor(y + h / 2)
  for i = 0, size do
    renderer.draw_rect(x + i, cy - size + i, s, s, color)
    renderer.draw_rect(x + i, cy + size - i, s, s, color)
  end
end

-- The query field: a search icon, the query with its selection, and the caret.
local function draw_field(row, m)
  local input = state.input
  local font = m.font
  local tx = row.x + m.row_x
  common.draw_text(m.icon_font, style.accent, context_menu.icons.search, "left", tx, row.y, m.icon_w, row.h)
  tx = tx + m.icon_w
  local available = row.x + row.w - m.row_x - tx
  local caret_w = math.max(1, math.floor(1.5 * SCALE))
  local function offset_x(pos) return font:get_width(input.text:sub(1, pos)) end
  -- A long query scrolls so its caret stays in view.
  local scroll = math.max(0, offset_x(input.caret) + caret_w - available)
  local ty = row.y + math.floor((row.h - font:get_height()) / 2)
  core.push_clip_rect(tx, row.y, available, row.h)
  local first, last = input:selection()
  if first ~= last then
    local left = offset_x(first)
    renderer.draw_rect(tx - scroll + left, ty, offset_x(last) - left, font:get_height(), style.selection)
  end
  renderer.draw_text(font, input.text, tx - scroll, ty, style.text)
  renderer.draw_rect(tx - scroll + offset_x(input.caret), ty, caret_w, font:get_height(), style.accent)
  core.pop_clip_rect()
end

local function draw_level(level)
  local m = metrics()
  card.draw(level.x, level.y, level.w, level.h, m.radius)
  card.show_above_sidebar(level.x, level.y, level.w, level.h, m.radius, state.host)
  core.push_clip_rect(level.x, level.y, level.w, level.h)
  local selected_row = level.rows[level.selected]
  if selected_row then
    level.highlight:step(selected_row.y - level.y, selected_row.h)
  else
    level.highlight:step()
  end
  level.highlight:draw(level.x + m.pad, level.y, level.w - m.pad * 2, m.row_radius, style.card_selection)
  for index, row in ipairs(level.rows) do
    if row.separator then
      local line_y = math.floor(row.y + row.h / 2)
      renderer.draw_rect(row.x + m.row_x, line_y, row.w - m.row_x * 2, card.border_width(), style.card_border)
    elseif row.field then
      draw_field(row, m)
    else
      local selected = level.selected == index
      local tx, tw = row.x + m.row_x, row.w - m.row_x * 2
      if row.icon then
        local color = selected and style.text or style.card_text
        if type(row.icon) == "function" then
          row.icon(tx, row.y, row.h, color)
        else
          common.draw_text(m.icon_font, color, row.icon, "left", tx, row.y, level.icon_w, row.h)
        end
      end
      local lx = tx + level.icon_w
      if row.path then
        lx = common.draw_text(m.font, style.card_text, row.path .. PATH_SEPARATOR, "left", lx, row.y, 0, row.h)
      end
      common.draw_text(m.font, style.text, row.label, "left", lx, row.y, tx + tw - lx, row.h)
      if row.shortcut then
        common.draw_text(m.font, style.card_text, row.shortcut, "right", tx, row.y, tw, row.h)
      elseif row.items then
        draw_chevron(row.x + row.w - m.row_x - math.floor(3 * SCALE), row.y, row.h, style.card_text)
      end
    end
  end
  core.pop_clip_rect()
end

function context_menu.draw()
  if not state then return end
  local p = 1 - (1 - state.progress) ^ 3
  local animating = p < 0.999
  if animating then renderer.push_transform(state.origin.x, state.origin.y, 0.96 + 0.04 * p, p) end
  for _, level in ipairs(state.levels) do draw_level(level) end
  if animating then renderer.pop_transform() end
end

return context_menu
