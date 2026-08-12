-- mod-version:3
-- First integrated Terminal View prototype.
local command = require "core.command"
local core = require "core"
local keymap = require "core.keymap"
local panes = require "core.panes"
local style = require "core.style"
local View = require "core.view"

local M = {}
local native_override
local views = {}

local PADDING = 6

local function terminal_native()
  if native_override then return native_override end
  if PLATFORM ~= "Windows" then return nil, "The Terminal View prototype requires Windows." end
  local ok, native = pcall(require, "terminal_native")
  if not ok then return nil, tostring(native) end
  return native
end

local function rgb(value, fallback)
  if type(value) ~= "number" then return fallback end
  return {
    math.floor(value / 0x10000) % 0x100,
    math.floor(value / 0x100) % 0x100,
    value % 0x100,
    255,
  }
end

local function project_path()
  local project = core.root_project and core.root_project()
  return project and project.path or system.getcwd()
end

---@class plugins.terminal.view : core.view
local TerminalView = View:extend()

function TerminalView:__tostring() return "TerminalView" end

function TerminalView:new(options)
  TerminalView.super.new(self)
  options = options or {}
  self.context = "workspace"
  self.terminal_view = true
  self.cursor = "ibeam"
  self.font = style.terminal_font or style.code_font
  self.cell_width = math.max(1, math.ceil(self.font:get_width("M")))
  self.cell_height = math.max(1, math.ceil(self.font:get_height()))
  self.cols, self.rows = 80, 24

  local native, load_error = terminal_native()
  if not native then error(load_error) end
  local session, start_error = native.new({
    cols = self.cols,
    rows = self.rows,
    cell_width = self.cell_width,
    cell_height = self.cell_height,
    cwd = options.cwd or project_path(),
    shell = options.shell,
  })
  if not session then error(start_error or "Could not start the terminal.") end
  self.session = session
  self.snapshot = session:snapshot()
  self.running = true
  views[#views + 1] = self
  core.log_quiet("Terminal View started: cwd=%s cols=%d rows=%d", options.cwd or project_path(), self.cols, self.rows)
end

function TerminalView:get_name()
  local title = self.snapshot and self.snapshot.title
  if title and title ~= "" then return title end
  return self.running == false and "Terminal (exited)" or "Terminal"
end

function TerminalView:supports_text_input()
  return true
end

function TerminalView:cell_geometry()
  local width = math.max(1, self.size.x - PADDING * 2)
  local height = math.max(1, self.size.y - PADDING * 2)
  return math.max(2, math.floor(width / self.cell_width)),
    math.max(1, math.floor(height / self.cell_height))
end

function TerminalView:update()
  TerminalView.super.update(self)
  if not self.session then return end

  local focused = core.active_view == self
  if focused ~= self.focused then
    self.focused = focused
    self.session:focus(focused)
  end

  local cols, rows = self:cell_geometry()
  if cols ~= self.cols or rows ~= self.rows then
    local ok = self.session:resize(cols, rows, self.cell_width, self.cell_height)
    if ok then
      self.cols, self.rows = cols, rows
      self.snapshot = self.session:snapshot(self.snapshot)
      core.redraw = true
    end
  end

  local was_running = self.running
  local changed, running = self.session:update()
  self.running = running ~= false
  if changed or self.running ~= was_running then
    self.snapshot = self.session:snapshot(self.snapshot)
    core.redraw = true
  end
end

local function cell_font(view, cell)
  -- The first prototype keeps one font. Native style data remains available
  -- for proper bold and italic font roles in the next rendering pass.
  return view.font
end

function TerminalView:draw()
  local snapshot = self.snapshot
  local background = rgb(snapshot and snapshot.background, style.background)
  self:draw_background(background)
  if not snapshot then return end

  local origin_x = self.position.x + PADDING
  local origin_y = self.position.y + PADDING
  for row_index, row in ipairs(snapshot.rows or {}) do
    local y = origin_y + (row_index - 1) * self.cell_height
    if y >= self.position.y + self.size.y then break end
    for col_index, cell in ipairs(row) do
      if cell then
        local x = origin_x + (col_index - 1) * self.cell_width
        if cell.bg then
          renderer.draw_rect(x, y, self.cell_width, self.cell_height, rgb(cell.bg, background))
        end
        if cell.selected then
          renderer.draw_rect(x, y, self.cell_width, self.cell_height, style.selection)
        end
        if cell.text and cell.text ~= "" and not cell.invisible then
          local color = rgb(cell.fg, style.text)
          renderer.draw_text(cell_font(self, cell), cell.text, x, y, color)
          if cell.bold then
            renderer.draw_text(cell_font(self, cell), cell.text, x + math.max(1, SCALE), y, color)
          end
          if cell.underline and cell.underline ~= 0 then
            renderer.draw_rect(x, y + self.cell_height - math.max(1, SCALE), self.cell_width, math.max(1, SCALE), color)
          end
          if cell.strikethrough then
            renderer.draw_rect(x, y + math.floor(self.cell_height / 2), self.cell_width, math.max(1, SCALE), color)
          end
        end
      end
    end
  end

  local cursor = snapshot.cursor
  if cursor and cursor.visible and self.running ~= false then
    local x = origin_x + (cursor.x or 0) * self.cell_width
    local y = origin_y + (cursor.y or 0) * self.cell_height
    local color = rgb(cursor.color or snapshot.foreground, style.caret)
    if cursor.style == "bar" then
      renderer.draw_rect(x, y, math.max(1, style.caret_width or SCALE), self.cell_height, color)
    elseif cursor.style == "underline" then
      renderer.draw_rect(x, y + self.cell_height - math.max(2, 2 * SCALE), self.cell_width, math.max(2, 2 * SCALE), color)
    else
      color[4] = 110
      renderer.draw_rect(x, y, self.cell_width, self.cell_height, color)
    end
  end
end

function TerminalView:on_text_input(text)
  if not self.session or self.running == false then return false end
  return self.session:write(text) == true
end

function TerminalView:paste(text, allow_unsafe)
  if not self.session or self.running == false or not text or text == "" then return false end
  local ok, reason = self.session:paste(text, allow_unsafe == true)
  if ok then return true end
  if reason ~= "unsafe" then return false end

  core.nag_view:show(
    "Paste Multiple Lines Into Terminal",
    "This text contains a newline. It can run one or more commands. Paste it?",
    {
      { text = "Paste", default_yes = false },
      { text = "Cancel", default_no = true },
    },
    function(item)
      if item.text == "Paste" and self.session and self.running ~= false then
        self.session:paste(text, true)
      end
    end
  )
  return true
end

local function key_modifiers(event)
  if event and event.modifiers then return { raw = event.modifiers } end
  return {
    shift = keymap.modkeys.shift == true,
    ctrl = keymap.modkeys.ctrl == true,
    alt = keymap.modkeys.alt == true or keymap.modkeys.altgr == true,
    super = keymap.modkeys.super == true,
  }
end

function TerminalView:on_key_pressed(key, event)
  if not self.session or self.running == false then return false end
  local action = event and event["repeat"] and "repeat" or "press"
  return self.session:key(key, key_modifiers(event), action, event) == true
end

function TerminalView:on_key_released(key, event)
  if not self.session or self.running == false then return false end
  return self.session:key(key, key_modifiers(event), "release", event) == true
end

local function mouse_modifiers()
  return {
    shift = keymap.modkeys.shift == true,
    ctrl = keymap.modkeys.ctrl == true,
    alt = keymap.modkeys.alt == true or keymap.modkeys.altgr == true,
    super = keymap.modkeys.super == true,
  }
end

function TerminalView:mouse_position(x, y)
  local local_x = x - self.position.x - PADDING
  local local_y = y - self.position.y - PADDING
  local col = math.max(0, math.min(self.cols - 1, math.floor(local_x / self.cell_width)))
  local row = math.max(0, math.min(self.rows - 1, math.floor(local_y / self.cell_height)))
  return col, row, math.max(0, local_x), math.max(0, local_y)
end

function TerminalView:refresh_snapshot()
  self.snapshot = self.session:snapshot(self.snapshot)
  core.redraw = true
end

function TerminalView:on_mouse_pressed(button, x, y)
  core.set_active_view(self)
  local col, row, pixel_x, pixel_y = self:mouse_position(x, y)
  local tracking = self.snapshot and self.snapshot.mouse_tracking
  if tracking and not keymap.modkeys.shift then
    self.mouse_button = button
    self.session:clear_selection()
    self.session:mouse("press", button, pixel_x, pixel_y, mouse_modifiers())
  elseif button == "left" then
    self.selection_start = { col, row }
    self.session:select(col, row, col, row, keymap.modkeys.alt == true)
    self:refresh_snapshot()
  end
  return true
end

function TerminalView:on_mouse_moved(x, y)
  local col, row, pixel_x, pixel_y = self:mouse_position(x, y)
  if self.selection_start then
    self.session:select(
      self.selection_start[1], self.selection_start[2], col, row,
      keymap.modkeys.alt == true
    )
    self:refresh_snapshot()
    return true
  end
  if self.snapshot and self.snapshot.mouse_tracking then
    self.session:mouse("motion", self.mouse_button, pixel_x, pixel_y, mouse_modifiers())
    return true
  end
  return false
end

function TerminalView:on_mouse_released(button, x, y)
  local _, _, pixel_x, pixel_y = self:mouse_position(x, y)
  if self.selection_start and button == "left" then
    self.selection_start = nil
    return true
  end
  if self.snapshot and self.snapshot.mouse_tracking then
    self.session:mouse("release", button, pixel_x, pixel_y, mouse_modifiers())
    self.mouse_button = nil
    return true
  end
  return false
end

function TerminalView:on_mouse_wheel(delta_y)
  if not self.session then return false end
  if self.snapshot and self.snapshot.mouse_tracking and not keymap.modkeys.shift then
    local x, y = core.root_panel.mouse.x, core.root_panel.mouse.y
    local _, _, pixel_x, pixel_y = self:mouse_position(x, y)
    local button = delta_y > 0 and "four" or "five"
    self.session:mouse("press", button, pixel_x, pixel_y, mouse_modifiers())
    return true
  end
  local delta = delta_y > 0 and -3 or 3
  if self.session:scroll(delta) then
    self.snapshot = self.session:snapshot(self.snapshot)
    core.redraw = true
    return true
  end
  return false
end

function TerminalView:try_close(do_close)
  if self.session then
    self.session:close()
    self.session = nil
    core.log_quiet("Terminal View closed")
  end
  do_close()
end

function M.open(options)
  local ok, view = core.try(TerminalView, options)
  if not ok or not view then return nil end
  panes.open_view(view, { pane = "right", focus = true })
  return view
end

function M.open_views()
  local open = {}
  for _, view in ipairs(views) do
    if view.session or panes.pane_for_view(view) then open[#open + 1] = view end
  end
  views = open
  return open
end

function M._set_native_for_tests(native)
  native_override = native
end

M.TerminalView = TerminalView

command.add(nil, {
  ["terminal:open"] = function() return M.open() ~= nil end,
})

command.add(function()
  local view = core.active_view
  return view and view.terminal_view == true and view.running ~= false, view
end, {
  ["terminal:paste"] = function(view)
    return view:paste(system.get_clipboard())
  end,
  ["terminal:copy"] = function(view)
    local text = view.session:selected_text()
    if not text or text == "" then return false end
    system.set_clipboard(text)
    return true
  end,
})

keymap.add({
  ["ctrl+shift+c"] = "terminal:copy",
  ["ctrl+shift+v"] = "terminal:paste",
})

return M
