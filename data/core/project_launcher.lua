local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local look = require "core.project_look"
local ui = require "core.ui"

-- The Project Launcher: what the Project area shows while no Pane Group shows. It shows the Project's badge and name,
-- and a row of buttons. Each button opens one of the Project's main Views in a new Pane, or its folder in File
-- Explorer. The Root Panel draws it over the wallpaper and sends it pointer and keyboard input. Keys use the
-- bindings of Dialogs and of caret moves.
local launcher = {}

local function open_folder()
  local path = core.root_project().path
  if not common.open_in_system(path) then core.error("Could not open %s in File Explorer", path) end
end

-- `folder` buttons act on the Project's folder, so the Scratch Project, whose folder holds no work, has none.
-- `local_folder` buttons need a folder on this PC.
local ITEMS = {
  { label = "File Tree", icon = "\u{F0645}", command = "filetree:open_at_project_root", folder = true },
  { label = "Terminal", icon = "\u{F018D}", command = "terminal:open_at_project_root" },
  { label = "Pi", agent = "pi", command = "terminal:open_pi" },
  { label = "Open in OS File Explorer", icon = ui.icons.reveal, run = open_folder, folder = true, local_folder = true },
}

-- `selected` is the keyboard selection. The Launcher shows with none; the first move key selects the first button.
local state = { selected = nil, items = {}, path = nil }

local function panes() return core.panes or require "core.panes" end

---Whether the Project area shows the Launcher.
function launcher.shown()
  return core.root_project() ~= nil and panes().shown_group() == nil
end

-- The buttons that this Project shows, in order.
local function project_items()
  local project = core.root_project()
  local path = project and project.path
  if state.path ~= path then
    state.path, state.items, state.selected = path, {}, nil
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
    title_font = style.get_scaled_font(style.prose_heading_font, math.floor(30 * SCALE + 0.5)),
    badge_font = style.get_scaled_font(style.view_text_font, math.floor(20 * SCALE + 0.5), "bold"),
    badge = math.floor(44 * SCALE + 0.5),
    title_gap = math.floor(16 * SCALE + 0.5),
    heading_gap = math.floor(28 * SCALE + 0.5),
    button_h = math.floor(36 * SCALE + 0.5),
    pad_x = math.floor(14 * SCALE + 0.5),
    icon_size = math.floor(17 * SCALE + 0.5),
    icon_gap = math.floor(8 * SCALE + 0.5),
    gap = math.floor(6 * SCALE + 0.5),
    radius = math.floor(8 * SCALE + 0.5),
    outline = math.max(1, math.floor(SCALE + 0.5)),
  }
end

-- The Project as the Project Sidebar shows it, for its badge and name.
local function project_record()
  local path = core.root_project().path
  return { path = path, scratch = core.is_scratch_project(path), state = "ready", exists = true }
end

-- Places the heading and the buttons in the middle of the content area, a little above its center. The buttons wrap
-- to more rows when the area is narrow. Returns the buttons, the number in the first row, and the heading's top.
local function layout(m)
  local items = project_items()
  local rect = core.root_panel.content_rect
  local rows, row = {}, nil
  local max_w = math.max(1, rect.w - 2 * m.pad_x)
  for _, item in ipairs(items) do
    item.w = m.font:get_width(item.label) + m.icon_size + m.icon_gap + 2 * m.pad_x
    item.h = m.button_h
    if not row or row.w + m.gap + item.w > max_w then
      row = { w = item.w }
      rows[#rows + 1] = row
    else
      row.w = row.w + m.gap + item.w
    end
    row[#row + 1] = item
  end
  local buttons_h = #rows * m.button_h + math.max(0, #rows - 1) * m.gap
  local total_h = m.badge + m.heading_gap + buttons_h
  local top = math.floor(rect.y + math.max(0, rect.h - total_h) * 0.45)
  local y = top + m.badge + m.heading_gap
  for _, r in ipairs(rows) do
    local x = math.floor(rect.x + (rect.w - r.w) / 2)
    for _, item in ipairs(r) do
      item.x, item.y = x, y
      x = x + item.w + m.gap
    end
    y = y + m.button_h + m.gap
  end
  return items, rows[1] and #rows[1] or 1, top
end

---The buttons that this Project shows, in order. Each has its `label` and its rect `x`, `y`, `w`, `h`.
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
  local items, _, top = layout(m)
  local rect = core.root_panel.content_rect
  local project = project_record()
  local name = ui.fit_text(m.title_font, look.name(project), math.max(0, rect.w - m.badge - m.title_gap))
  local heading_w = m.badge + m.title_gap + m.title_font:get_width(name)
  local hx = math.floor(rect.x + (rect.w - heading_w) / 2)
  look.draw_badge(project, hx, top, m.badge, m.badge_font, style.background)
  common.draw_text(m.title_font, style.text, name, "left", hx + m.badge + m.title_gap, top, 0, m.badge)
  local focused = has_keyboard()
  for index, item in ipairs(items) do
    local x, y, w, h, r = item.x, item.y, item.w, item.h, m.radius
    local hover = ui.approach(item, "hover_amount", item == state.hovered and 1 or 0, 30)
    -- The keyboard selection is a thin, faint accent outline. It fades as it moves, so it stays quiet.
    local selected = ui.approach(item, "selected_amount", focused and index == state.selected and 1 or 0, 30)
    if selected > 0 then
      ui.draw_rounded_outline(x, y, w, h, r, m.outline, ui.fade(style.accent, 0.5 * selected))
    end
    if item == state.pressed and item == state.hovered then
      renderer.draw_rounded_rect(x, y, w, h, r, style.button_pressed)
    elseif hover > 0 then
      renderer.draw_rounded_rect(x, y, w, h, r, ui.fade(style.button, hover))
    end
    local color = ui.mix(style.card_text, style.text, math.max(selected, hover))
    local icon_x = x + m.pad_x
    local cy = y + h / 2
    if item.agent then
      -- The mark fills its square, so it draws smaller than the glyphs, which leave a margin in their cell.
      local size = math.floor(m.icon_size * 0.8)
      require("core.agent_icons").draw_mark(item.agent, icon_x + (m.icon_size - size) / 2, cy - size / 2, size)
    else
      local font = style.get_scaled_font(style.menu_icon_font, math.floor(m.icon_size * 1.7))
      common.draw_text(font, color, item.icon, "center", icon_x - m.icon_size / 2, y, m.icon_size * 2, h)
    end
    common.draw_text(m.font, color, item.label, "left", icon_x + m.icon_size + m.icon_gap, y, 0, h)
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

-- Moves the selection by `delta` buttons. Tab wraps; caret moves stop at the ends. Without a selection, any move
-- selects the first button.
local function move(delta, wrap)
  local count = #project_items()
  if count == 0 then return false end
  if not state.selected then
    state.selected = 1
    core.redraw = true
    return true
  end
  local index = state.selected + delta
  if wrap then index = (index - 1) % count + 1 else index = common.clamp(index, 1, count) end
  state.selected = index
  core.redraw = true
  return true
end

---Forgets the selection, hover and press while the Launcher does not show, so it shows again with none.
function launcher.hide()
  state.selected, state.hovered, state.pressed = nil, nil, nil
end

function launcher.on_key_pressed(key, event)
  if not launcher.shown() or keymap.is_modifier_key(key) then return false end
  local _, cols = layout(metrics())
  local items = state.items
  for _, name in ipairs(keymap.map[keymap.stroke_for_event(key, event)] or {}) do
    if name == "dialog:confirm" then
      local item = state.selected and items[state.selected]
      return item and activate(item) or false
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
