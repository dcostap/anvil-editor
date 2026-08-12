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

  local cols, rows = self:cell_geometry()
  if cols ~= self.cols or rows ~= self.rows then
    local ok = self.session:resize(cols, rows, self.cell_width, self.cell_height)
    if ok then
      self.cols, self.rows = cols, rows
      self.snapshot = self.session:snapshot()
      core.redraw = true
    end
  end

  local was_running = self.running
  local changed, running = self.session:update()
  self.running = running ~= false
  if changed or self.running ~= was_running then
    self.snapshot = self.session:snapshot()
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

function TerminalView:on_key_pressed(key)
  if not self.session or self.running == false then return false end
  local mods = {
    shift = keymap.modkeys.shift == true,
    ctrl = keymap.modkeys.ctrl == true,
    alt = keymap.modkeys.alt == true or keymap.modkeys.altgr == true,
    super = keymap.modkeys.super == true,
  }
  return self.session:key(key, mods) == true
end

function TerminalView:on_mouse_pressed(button)
  if button == "left" then core.set_active_view(self) end
  return true
end

function TerminalView:on_mouse_wheel(delta_y)
  if not self.session then return false end
  local delta = delta_y > 0 and -3 or 3
  if self.session:scroll(delta) then
    self.snapshot = self.session:snapshot()
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

return M
