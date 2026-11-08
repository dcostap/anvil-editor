local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local card = require "core.card"
local ui = require "core.ui"

-- The Project Launcher: the tiles that the Project area shows while no Pane Group shows. Each tile opens one of
-- the Project's main Views in a new Pane, or its folder in File Explorer. The Root Panel draws it over the
-- wallpaper and sends it pointer and keyboard input. Keys use the bindings of Dialogs and of caret moves.
local launcher = {}

local function open_folder()
  local path = core.root_project().path
  if not common.open_in_system(path) then core.error("Could not open %s in File Explorer", path) end
end

-- `folder` tiles act on the Project's folder, so the Scratch Project, whose folder holds no work, has none.
-- `local_folder` tiles need a folder on this PC.
local ITEMS = {
  { label = "File Tree", icon = "\u{F0645}", command = "filetree:open_at_project_root", folder = true },
  { label = "Terminal", icon = "\u{F018D}", command = "terminal:open_at_project_root" },
  { label = "Pi", agent = "pi", command = "terminal:open_pi" },
  { label = "File Explorer", icon = ui.icons.reveal, run = open_folder, folder = true, local_folder = true },
}

local state = { selected = 1, items = {}, path = nil }

local function panes() return core.panes or require "core.panes" end

---Whether the Project area shows the Launcher.
function launcher.shown()
  return core.root_project() ~= nil and panes().shown_group() == nil
end

-- The tiles that this Project shows, in order.
local function project_items()
  local project = core.root_project()
  local path = project and project.path
  if state.path ~= path then
    state.path, state.items, state.selected = path, {}, 1
    local scratch = path and core.is_scratch_project(path)
    local machine = path and require("core.fs").on_machine(path)
    for _, item in ipairs(ITEMS) do
      if not (item.folder and scratch) and not (item.local_folder and machine) then
        state.items[#state.items + 1] = setmetatable({}, { __index = item })
      end
    end
  end
  return state.items
end

local function metrics()
  local font = ui.font()
  return {
    font = font,
    icon_size = math.floor(30 * SCALE + 0.5),
    pad_x = math.floor(18 * SCALE + 0.5),
    pad_top = math.floor(20 * SCALE + 0.5),
    pad_bottom = math.floor(16 * SCALE + 0.5),
    label_gap = math.floor(12 * SCALE + 0.5),
    gap = math.floor(14 * SCALE + 0.5),
    min_w = math.floor(116 * SCALE + 0.5),
    radius = math.floor(10 * SCALE + 0.5),
  }
end

-- Places the tiles in the middle of the content area. They wrap to more rows when the area is narrow.
local function layout(m)
  local items = project_items()
  local rect = core.root_panel.content_rect
  local w = m.min_w
  for _, item in ipairs(items) do w = math.max(w, m.font:get_width(item.label) + 2 * m.pad_x) end
  local h = m.pad_top + m.icon_size + m.label_gap + m.font:get_height() + m.pad_bottom
  local cols = common.clamp(math.floor((rect.w - 2 * m.gap + m.gap) / (w + m.gap)), 1, math.max(1, #items))
  local rows = math.ceil(#items / cols)
  local total_h = rows * h + (rows - 1) * m.gap
  -- Slightly above the middle looks centered.
  local top = math.floor(rect.y + math.max(0, rect.h - total_h) * 0.45)
  for index, item in ipairs(items) do
    local row, col = math.floor((index - 1) / cols), (index - 1) % cols
    local in_row = math.min(cols, #items - row * cols)
    local left = rect.x + (rect.w - (in_row * w + (in_row - 1) * m.gap)) / 2
    item.x, item.y = math.floor(left + col * (w + m.gap)), top + row * (h + m.gap)
    item.w, item.h = w, h
  end
  return items, cols
end

---The tiles that this Project shows, in order. Each has its `label` and its rect `x`, `y`, `w`, `h`.
function launcher.items()
  return (layout(metrics()))
end

local function item_at(x, y)
  if not launcher.shown() then return nil end
  for _, item in ipairs(layout(metrics())) do
    if x >= item.x and y >= item.y and x < item.x + item.w and y < item.y + item.h then return item end
  end
end

local function activate(item)
  core.log_quiet("Project Launcher: %s", item.label)
  if item.run then
    item.run()
  else
    command.perform_with_context(item.command, { placement = "new" })
  end
  return true
end

---The Launcher has the keyboard when this Project has it and no other View takes it.
local function has_keyboard()
  local root = core.root_panel
  return core.active_window == core.window and system.window_has_focus(core.window)
    and not root:modal_input_owner() and root:keyboard_target() == nil
end

function launcher.draw()
  local m = metrics()
  local items = layout(m)
  local focused = has_keyboard()
  for index, item in ipairs(items) do
    local x, y, w, h, r = item.x, item.y, item.w, item.h, m.radius
    local hover = ui.approach(item, "hover_amount", item == state.hovered and 1 or 0, 30)
    local selected = focused and index == state.selected
    card.draw(x, y, w, h, r)
    if selected then ui.draw_focus_ring(x, y, w, h, r) end
    if item == state.pressed and item == state.hovered then
      renderer.draw_rounded_rect(x, y, w, h, r, style.button_pressed)
    elseif hover > 0 then
      renderer.draw_rounded_rect(x, y, w, h, r, ui.fade(style.button_hover, hover))
    end
    local color = ui.mix(style.card_text, style.text, selected and 1 or hover)
    local icon_y = y + m.pad_top
    if item.agent then
      -- The mark fills its square, so it draws smaller than the glyphs, which leave a margin in their cell.
      local size = math.floor(m.icon_size * 0.8)
      require("core.agent_icons").draw_mark(item.agent, x + (w - size) / 2, icon_y + (m.icon_size - size) / 2, size)
    else
      local font = style.get_scaled_font(style.menu_icon_font, math.floor(style.menu_icon_font:get_size() * 2.2))
      common.draw_text(font, color, item.icon, "center", x, icon_y, w, m.icon_size)
    end
    common.draw_text(m.font, color, item.label, "center", x, icon_y + m.icon_size + m.label_gap, w,
      m.font:get_height())
  end
end

local function set_hovered(item)
  if state.hovered ~= item then
    state.hovered = item
    core.redraw = true
  end
end

function launcher.on_mouse_moved(x, y)
  local item = item_at(x, y)
  set_hovered(item)
  core.request_cursor(item and "hand" or "arrow")
end

function launcher.on_mouse_left()
  set_hovered(nil)
end

function launcher.on_mouse_pressed(button, x, y)
  local item = button == "left" and item_at(x, y)
  if not item then return false end
  state.pressed = item
  for index, other in ipairs(state.items) do
    if other == item then state.selected = index end
  end
  core.redraw = true
  return true
end

function launcher.on_mouse_released(button, x, y)
  local pressed = state.pressed
  if button ~= "left" or not pressed then return false end
  state.pressed = nil
  core.redraw = true
  if item_at(x, y) == pressed then activate(pressed) end
  return true
end

-- Moves the selection by `delta` tiles. Tab wraps; caret moves stop at the ends.
local function move(delta, wrap)
  local count = #project_items()
  if count == 0 then return false end
  local index = state.selected + delta
  if wrap then index = (index - 1) % count + 1 else index = common.clamp(index, 1, count) end
  state.selected = index
  core.redraw = true
  return true
end

function launcher.on_key_pressed(key, event)
  if not launcher.shown() or keymap.is_modifier_key(key) then return false end
  local _, cols = layout(metrics())
  local items = state.items
  for _, name in ipairs(keymap.map[keymap.stroke_for_event(key, event)] or {}) do
    if name == "dialog:confirm" then
      local item = items[state.selected]
      return item ~= nil and activate(item)
    end
    if name == "dialog:focus_next" then return move(1, true) end
    if name == "dialog:focus_previous" then return move(-1, true) end
    if name == "core:move_to_next_char" then return move(1) end
    if name == "core:move_to_previous_char" then return move(-1) end
    if name == "core:move_to_next_line" then return move(cols) end
    if name == "core:move_to_previous_line" then return move(-cols) end
  end
  return false
end

return launcher
