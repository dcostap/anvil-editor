-- mod-version:3
-- First integrated Terminal View prototype.
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local keymap = require "core.keymap"
local panes = require "core.panes"
local style = require "core.style"
local View = require "core.view"

local M = {}
local native_override
local views = {}

local PADDING = 6

---@class config.plugins.terminal
local terminal_config = config.plugins.terminal

local function document_path()
  local view = core.active_view or core.last_active_view
  local path = view and view.doc and view.doc.abs_filename
  return path and common.dirname(path) or nil
end

local function terminal_native()
  if native_override then return native_override end
  if PLATFORM ~= "Windows" then return nil, "The Terminal View prototype requires Windows." end
  local ok, native = pcall(require, "terminal_native")
  if not ok then return nil, tostring(native) end
  return native
end

local function rgb(view, value, fallback, alpha)
  if type(value) ~= "number" then return fallback end
  alpha = alpha or 255
  local key = value * 256 + alpha
  local color = view.color_cache[key]
  if color then return color end
  color = {
    math.floor(value / 0x10000) % 0x100,
    math.floor(value / 0x100) % 0x100,
    value % 0x100,
    alpha,
  }
  view.color_cache[key] = color
  return color
end

local function perf_scope_begin(name, capture_heap)
  local perf = package.loaded["core.perf"]
  return perf and perf.scope_begin and perf.scope_begin(name, capture_heap) or nil
end

local function perf_scope_end(scope)
  if not scope then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.scope_end then perf.scope_end(scope) end
end

local function perf_detail(name, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.add_detail then
    perf.add_detail(name, amount)
  end
end

local function perf_is_recording()
  local perf = package.loaded["core.perf"]
  return perf and perf.is_recording and perf.is_recording()
end

local function project_path(mode)
  if mode == "document" then
    local path = document_path()
    if path then return path end
  end
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
  self.color_cache = {}
  self.launch_options = {
    cwd = options.cwd or project_path(options.cwd_mode or terminal_config.cwd_mode),
    shell = options.shell or terminal_config.shell,
  }

  local native, load_error = terminal_native()
  if not native then error(load_error) end
  local session, start_error = native.new({
    cols = self.cols,
    rows = self.rows,
    cell_width = self.cell_width,
    cell_height = self.cell_height,
    cwd = self.launch_options.cwd,
    shell = self.launch_options.shell,
  })
  if not session then error(start_error or "Could not start the terminal.") end
  self.session = session
  self.snapshot = session:snapshot()
  self.running = true
  views[#views + 1] = self
  core.log_quiet("Terminal View started: cwd=%s cols=%d rows=%d", self.launch_options.cwd, self.cols, self.rows)
end

function TerminalView:get_name()
  local title = self.snapshot and self.snapshot.title
  if title and title ~= "" then return title end
  if self.running == false then
    return self.exit_code ~= nil and string.format("Terminal (exit %d)", self.exit_code)
      or "Terminal (exited)"
  end
  return "Terminal"
end

function TerminalView:start_session()
  local native, load_error = terminal_native()
  if not native then return false, load_error end
  local session, start_error = native.new({
    cols = self.cols, rows = self.rows,
    cell_width = self.cell_width, cell_height = self.cell_height,
    cwd = self.launch_options.cwd, shell = self.launch_options.shell,
  })
  if not session then return false, start_error or "Could not start the terminal." end
  self.session = session
  self.snapshot = session:snapshot()
  self.running = true
  self.exit_code = nil
  self.reported_error = nil
  core.redraw = true
  return true
end

function TerminalView:restart()
  if self.session then self.session:close() end
  self.session = nil
  local ok, err = self:start_session()
  if not ok then core.error("Could not restart terminal: %s", tostring(err)) end
  return ok
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
  local record_perf = perf_is_recording()
  local update_started = record_perf and system.get_time()
  local changed, running, status = self.session:update()
  if record_perf then
    perf_detail("terminal_native_update_ms", (system.get_time() - update_started) * 1000)
  end
  self.running = running ~= false
  self.exit_code = status and status.exit_code or self.exit_code
  if status and status.error and status.error ~= self.reported_error then
    self.reported_error = status.error
    core.error(status.error)
  end
  if changed or self.running ~= was_running then
    local snapshot_started = record_perf and system.get_time()
    self.snapshot = self.session:snapshot(self.snapshot)
    if record_perf then
      perf_detail("terminal_snapshot_ms", (system.get_time() - snapshot_started) * 1000)
      perf_detail("terminal_snapshot_calls", 1)
    end
    core.redraw = true
  end
end

local function cell_font(view, cell)
  if cell.bold and cell.italic then return style.terminal_bold_italic_font or view.font end
  if cell.bold then return style.terminal_bold_font or view.font end
  if cell.italic then return style.terminal_italic_font or view.font end
  return view.font
end

function TerminalView:draw()
  local draw_scope = perf_scope_begin("terminal", true)
  local snapshot = self.snapshot
  local background = rgb(self, snapshot and snapshot.background, style.background)
  self:draw_background(background)
  if not snapshot then
    perf_scope_end(draw_scope)
    return
  end

  local origin_x = self.position.x + PADDING
  local origin_y = self.position.y + PADDING
  local phase_scope = perf_scope_begin("backgrounds")
  for row_index, row in ipairs(snapshot.rows or {}) do
    local y = origin_y + (row_index - 1) * self.cell_height
    if y >= self.position.y + self.size.y then break end
    for _, span in ipairs(row.backgrounds or {}) do
      local color = span.selected and style.selection
        or rgb(self, span.color, background)
      renderer.draw_rect(
        origin_x + span.col * self.cell_width,
        y,
        span.columns * self.cell_width,
        self.cell_height,
        color
      )
    end
  end
  perf_scope_end(phase_scope)

  phase_scope = perf_scope_begin("text_runs")
  for row_index, row in ipairs(snapshot.rows or {}) do
    local y = origin_y + (row_index - 1) * self.cell_height
    if y >= self.position.y + self.size.y then break end
    for _, run in ipairs(row.text_runs or {}) do
      local x = origin_x + run.col * self.cell_width
      local width = run.columns * self.cell_width
      local color = rgb(self, run.fg, style.text)
      local font = cell_font(self, run)
      if renderer.draw_text_known_bounds then
        renderer.draw_text_known_bounds(
          font, run.text, x, y,
          math.floor(x), math.floor(y), math.ceil(width), math.ceil(self.cell_height),
          color
        )
      else
        renderer.draw_text(font, run.text, x, y, color)
      end
      if run.underline and run.underline ~= 0 then
        renderer.draw_rect(
          x, y + self.cell_height - math.max(1, SCALE),
          width, math.max(1, SCALE), color
        )
      end
      if run.strikethrough then
        renderer.draw_rect(
          x, y + math.floor(self.cell_height / 2),
          width, math.max(1, SCALE), color
        )
      end
    end
  end
  perf_scope_end(phase_scope)

  phase_scope = perf_scope_begin("cursor")
  local cursor = snapshot.cursor
  if cursor and cursor.visible and self.running ~= false then
    local x = origin_x + (cursor.x or 0) * self.cell_width
    local y = origin_y + (cursor.y or 0) * self.cell_height
    local value = cursor.color or snapshot.foreground
    local color = rgb(self, value, style.caret)
    if cursor.style == "bar" then
      renderer.draw_rect(x, y, math.max(1, style.caret_width or SCALE), self.cell_height, color)
    elseif cursor.style == "underline" then
      renderer.draw_rect(x, y + self.cell_height - math.max(2, 2 * SCALE), self.cell_width, math.max(2, 2 * SCALE), color)
    else
      renderer.draw_rect(
        x, y, self.cell_width, self.cell_height,
        rgb(self, value, style.caret, 110)
      )
    end
  end
  perf_scope_end(phase_scope)
  perf_scope_end(draw_scope)
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
  return view and view.terminal_view == true, view
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
  ["terminal:restart"] = function(view) return view:restart() end,
})

keymap.add({
  ["ctrl+shift+c"] = "terminal:copy",
  ["ctrl+shift+v"] = "terminal:paste",
})

return M
