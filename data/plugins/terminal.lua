-- mod-version:3
-- Integrated Windows Terminal View.
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Buffer = require "core.buffer"
local file_context = require "core.file_context"
local ime = require "core.ime"
local keymap = require "core.keymap"
local panes = require "core.panes"
local style = require "core.style"
local TextView = require "core.textview"
local View = require "core.view"
local view_icons = require "core.view_icons"

local M = {}
local native_override
local views = {}

local PADDING = 6

---@class config.plugins.terminal
local terminal_config = config.plugins.terminal
terminal_config.config_spec = {
  name = "Terminal",
  {
    label = "Shell Command",
    description = "Command that starts new terminal sessions. Empty uses PowerShell.",
    path = "shell",
    type = "string",
    default = "",
  },
  {
    label = "Starting Directory",
    description = "Directory used when a command does not specify one.",
    path = "cwd_mode",
    type = "selection",
    default = "project",
    values = {
      { "Project", "project" },
      { "Active Buffer", "buffer" },
    },
  },
}

local function buffer_path()
  for _, view in ipairs({ core.active_view, core.last_active_view }) do
    local path = view and view.buffer and view.buffer.abs_filename
    if path then return common.dirname(path) end
  end
end

local function terminal_native()
  if native_override then return native_override end
  if PLATFORM ~= "Windows" then return nil, "The Terminal View requires Windows." end
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

local function packed_color(color)
  return color[1] * 0x10000 + color[2] * 0x100 + color[3]
end

local function session_colors()
  local palette = {}
  for index, color in ipairs(style.terminal_palette) do
    palette[index] = packed_color(color)
  end
  return {
    foreground = packed_color(style.terminal_foreground),
    background = packed_color(style.terminal_background),
    cursor_color = packed_color(style.terminal_cursor),
    palette = palette,
  }
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
  if mode == "buffer" then
    local path = buffer_path()
    if path then return path end
  end
  local project = core.root_project and core.root_project()
  return project and project.path or system.getcwd()
end

local function terminal_pwd(snapshot)
  local pwd = snapshot and snapshot.pwd
  if type(pwd) ~= "string" or pwd == "" then return nil end
  if pwd:match("^file://") then
    local authority, path = pwd:match("^file://([^/]*)(/.*)$")
    if authority and authority ~= "" and authority:lower() ~= "localhost" then
      pwd = "\\\\" .. authority .. path:gsub("/", "\\")
    else
      pwd = path or pwd:gsub("^file:///?", "")
      if pwd:match("^/[A-Za-z]:") then pwd = pwd:sub(2) end
    end
    pwd = pwd:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  end
  return pwd ~= "" and pwd or nil
end

---@class plugins.terminal.view : core.view
local TerminalView = View:extend()
TerminalView.view_icon = view_icons.register("terminal", view_icons.ui("t"))

function TerminalView:__tostring() return "TerminalView" end

function TerminalView:new(options)
  TerminalView.super.new(self)
  options = options or {}
  self.context = "workspace"
  self.terminal_view = true
  self.scrollable = true
  self.cursor = "ibeam"
  self.font = style.terminal_font or style.code_font
  self.cell_width = math.max(1, self.font:get_width("M"))
  self.native_cell_width = math.max(1, math.ceil(self.cell_width))
  self.cell_height = math.max(1, math.ceil(self.font:get_height()))
  self.cols, self.rows = 80, 24
  self.color_cache = {}
  self.launch_options = {
    cwd = options.cwd or project_path(options.cwd_mode or terminal_config.cwd_mode),
    shell = options.shell or terminal_config.shell,
  }

  local native, load_error = terminal_native()
  if not native then error(load_error) end
  local native_options = session_colors()
  native_options.cols, native_options.rows = self.cols, self.rows
  native_options.cell_width, native_options.cell_height = self.native_cell_width, self.cell_height
  native_options.cwd, native_options.shell = self.launch_options.cwd, self.launch_options.shell
  local session, start_error = native.new(native_options)
  if not session then error(start_error or "Could not start the terminal.") end
  self.session = session
  self.snapshot = session:snapshot()
  self.theme_generation = core.color_theme_generation or 0
  self.running = true
  views[#views + 1] = self
  core.log_quiet("Terminal View started: cwd=%s cols=%d rows=%d", self.launch_options.cwd, self.cols, self.rows)
end

function TerminalView:get_name()
  local title = self.snapshot and self.snapshot.title
  if self.running == false then
    local status = self.exit_code ~= nil and string.format("exit %d", self.exit_code) or "exited"
    return title and title ~= "" and string.format("%s (%s)", title, status)
      or string.format("Terminal (%s)", status)
  end
  return title and title ~= "" and title or "Terminal"
end

---@class plugins.terminal.text_capture_view : core.textview
local TerminalTextCaptureView = TextView:extend()

function TerminalTextCaptureView:__tostring() return "TerminalTextCaptureView" end

function TerminalTextCaptureView:new(source, capture)
  local buffer = Buffer()
  buffer.display_name = "Terminal Text"
  buffer:insert(1, 1, tostring(capture.text or ""))
  buffer:clear_undo_redo()
  buffer:clean()
  local line = common.clamp(
    math.floor(tonumber(capture.cursor_line) or 1), 1, #buffer.lines
  )
  local col = common.clamp(
    math.floor(tonumber(capture.cursor_col) or 1), 1, #buffer.lines[line]
  )
  buffer:set_selection(line, col)
  buffer.read_only = true
  buffer.read_only_reason = "Terminal text captures are read-only"

  TerminalTextCaptureView.super.new(self, buffer)
  self.context = "workspace"
  self.terminal_text_capture = true
  self.terminal_source_view = source
  self.terminal_title = source:get_name()
  self.font = "terminal_font"
  self.show_line_numbers = false
  self.gutter_padding = PADDING
  self:set_wrapping_enabled(false)
  self.terminal_cell_height = source.cell_height
  self.last_line1, self.last_col1 = line, col
  self.last_line2, self.last_col2 = line, col
  local viewport_line = common.clamp(
    math.floor(tonumber(capture.viewport_line) or 1), 1, #buffer.lines
  )
  self.scroll.y = (viewport_line - 1) * self:get_line_height()
  self.scroll.to.y = self.scroll.y
  core.log_quiet(
    "Terminal text capture opened: lines=%d cursor=%d:%d viewport=%d",
    #buffer.lines, line, col, viewport_line
  )
end

function TerminalTextCaptureView:get_name()
  return string.format("Terminal Text — %s", self.terminal_title or "Terminal")
end

function TerminalTextCaptureView:get_line_height()
  return self.terminal_cell_height or TerminalTextCaptureView.super.get_line_height(self)
end

function TerminalTextCaptureView:get_content_offset()
  local x, y = TerminalTextCaptureView.super.get_content_offset(self)
  return x, y + PADDING - style.padding.y
end

function TerminalView:get_cwd()
  return terminal_pwd(self.snapshot) or self.launch_options.cwd
end

function TerminalView:get_state()
  return {
    cwd = self:get_cwd(),
    shell = self.launch_options.shell,
  }
end

function TerminalView:duplicate()
  return TerminalView {
    cwd = self:get_cwd(),
    shell = self.launch_options.shell,
  }
end

function TerminalView.from_state(state)
  if type(state) ~= "table" then return nil end
  local ok, view = pcall(TerminalView, { cwd = state.cwd, shell = state.shell })
  return ok and view or nil
end

function TerminalView:can_discard_from_history()
  return self.session == nil or self.running == false
end

function TerminalView:create_session()
  local native, load_error = terminal_native()
  if not native then return false, load_error end
  local native_options = session_colors()
  native_options.cols, native_options.rows = self.cols, self.rows
  native_options.cell_width, native_options.cell_height = self.native_cell_width, self.cell_height
  native_options.cwd, native_options.shell = self.launch_options.cwd, self.launch_options.shell
  local session, start_error = native.new(native_options)
  if not session then return false, start_error or "Could not start the terminal." end
  return session
end

function TerminalView:adopt_session(session)
  self.session = session
  self.snapshot = session:snapshot()
  self.theme_generation = core.color_theme_generation or 0
  self.running = true
  self.exit_code = nil
  self.reported_error = nil
  self.focused = nil
  if core.active_view == self then
    self.focused = true
    session:focus(true)
  end
  core.redraw = true
end

function TerminalView:restart()
  local replacement, err = self:create_session()
  if not replacement then
    core.error("Could not restart terminal: %s", tostring(err))
    return false
  end
  local previous = self.session
  self:adopt_session(replacement)
  if previous then previous:close() end
  return true
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

function TerminalView:get_scrollable_size()
  local scrollbar = self.snapshot and self.snapshot.scrollbar
  return scrollbar and math.max(self.size.y, scrollbar.total * self.cell_height)
    or self.size.y
end

function TerminalView:on_touch_moved(x, y, dx, dy)
  if not self.session or dy == 0 then return false end
  local rows = math.max(1, math.floor(math.abs(dy) / self.cell_height + 0.5))
  if not self.session:scroll("delta", dy > 0 and -rows or rows) then return false end
  self:refresh_snapshot()
  return true
end

function TerminalView:update_scrollbar()
  local scrollbar = self.snapshot and self.snapshot.scrollbar
  local total = scrollbar and scrollbar.total or self.rows
  local visible = scrollbar and scrollbar.len or self.rows
  local offset = scrollbar and scrollbar.offset or 0
  self.v_scrollbar:set_size(
    self.position.x, self.position.y, self.size.x, self.size.y,
    math.max(self.size.y, total * self.cell_height)
  )
  local range = math.max(0, total - visible)
  self.v_scrollbar:set_percent(range > 0 and offset / range or 1)
  self.v_scrollbar:update()
end

function TerminalView:scroll_to_percent(percent)
  local scrollbar = self.snapshot and self.snapshot.scrollbar
  if not (scrollbar and self.session) then return false end
  local range = math.max(0, scrollbar.total - scrollbar.len)
  local row = math.floor(math.max(0, math.min(1, percent)) * range + 0.5)
  if not self.session:scroll("row", row) then return false end
  self:refresh_snapshot()
  return true
end

function TerminalView:update()
  TerminalView.super.update(self)
  if not self.session then return end

  local theme_generation = core.color_theme_generation or 0
  if theme_generation ~= self.theme_generation then
    self.theme_generation = theme_generation
    if self.session:set_colors(session_colors()) then
      self.snapshot = self.session:snapshot(self.snapshot)
      core.redraw = true
    end
  end

  if self.search_pending then
    self:search(self.search_pending.query, self.search_pending.reverse)
  end

  local blink_phase = math.floor((system.get_time() - core.blink_start) /
    math.max(0.1, config.blink_period / 2))
  if not config.disable_blink and self.has_blinking_content and blink_phase ~= self.blink_phase then
    self.blink_phase = blink_phase
    core.redraw = true
  end

  if self.selection_start and self.selection_autoscroll then
    local x, y = core.root_panel.mouse.x, core.root_panel.mouse.y
    local col, row, pixel_x, pixel_y = self:mouse_position(x, y)
    if self.session:scroll("delta", self.selection_autoscroll == "up" and -1 or 1) then
      local _, autoscroll = self.session:selection_gesture(
        "drag", col, row, pixel_x, pixel_y, 1, keymap.modkeys.alt == true
      )
      self.selection_autoscroll = autoscroll ~= "none" and autoscroll or nil
      self:refresh_snapshot()
    end
  end

  local focused = core.active_view == self
  if focused ~= self.focused then
    self.focused = focused
    self.session:focus(focused)
  end

  local cols, rows = self:cell_geometry()
  if cols ~= self.cols or rows ~= self.rows then
    local ok = self.session:resize(cols, rows, self.native_cell_width, self.cell_height)
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
    self:handle_events()
    if record_perf then
      perf_detail("terminal_snapshot_ms", (system.get_time() - snapshot_started) * 1000)
      perf_detail("terminal_snapshot_calls", 1)
    end
    core.redraw = true
  end
end

function TerminalView:open_text_capture()
  if not self.session then return false end
  local capture, err = self.session:text_capture()
  if not capture then
    core.error("Could not capture terminal text: %s", tostring(err or "unknown error"))
    return false
  end
  local pane = panes.pane_for_view(self)
  if not pane then return false end
  local view, place_error = panes.place(function()
    return TerminalTextCaptureView(self, capture)
  end, {
    pane = pane,
    placement = "current",
    focus = true,
    reason = "terminal-text-capture",
  })
  if not view then
    core.error("Could not open terminal text: %s", tostring(place_error or "unknown error"))
    return false
  end
  return true
end

function TerminalView:update_suspended()
  if not self.session then return end
  local changed, running, status = self.session:update()
  self.running = running ~= false
  self.exit_code = status and status.exit_code or self.exit_code
  if status and status.error and status.error ~= self.reported_error then
    self.reported_error = status.error
    core.error(status.error)
  end
  if changed or status then
    self.snapshot = self.session:snapshot(self.snapshot)
    self:handle_events()
    core.redraw = true
  end
end

function TerminalView:handle_events()
  for _, event in ipairs((self.snapshot and self.snapshot.events) or {}) do
    if event.type == "bell" then
      self.bell_count = (self.bell_count or 0) + (event.count or 1)
      self.bell_until = system.get_time() + 0.15
      if system.flash_window and (core.active_view ~= self or
          not system.window_has_focus(core.window)) then
        system.flash_window(core.window, "briefly")
      end
      core.redraw = true
    elseif event.type == "clipboard" and event.text ~= nil then
      self.pending_clipboard = { text = event.text, clear = event.clear == true }
      if self.clipboard_prompt_open then goto continue end
      self.clipboard_prompt_open = true
      core.nag_view:show(
        "Terminal Clipboard Request",
        "A terminal program wants to replace the clipboard. Allow it?",
        {
          { text = "Allow", default_yes = false },
          { text = "Deny", default_no = true },
        },
        function(item)
          local pending = self.pending_clipboard
          if item.text == "Allow" and pending and self.session then
            system.set_clipboard(pending.text)
          end
          self.pending_clipboard = nil
          self.clipboard_prompt_open = false
        end
      )
    elseif event.type == "notification" then
      self.notification_count = (self.notification_count or 0) + (event.count or 1)
      local title = event.title ~= "" and event.title or "Terminal"
      core.log("%s: %s", title, event.body or "")
      if system.flash_window and (core.active_view ~= self or
          not system.window_has_focus(core.window)) then
        system.flash_window(core.window, "until_focused")
      end
    end
    ::continue::
  end
  if self.snapshot then self.snapshot.events = {} end
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
  if self.bell_until and system.get_time() < self.bell_until then
    background = style.line_highlight or background
    core.redraw = true
  end
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
  self.has_blinking_content = snapshot.cursor and snapshot.cursor.blinking or false
  local blink_on = config.disable_blink or
    (system.get_time() - core.blink_start) % config.blink_period < config.blink_period / 2
  for row_index, row in ipairs(snapshot.rows or {}) do
    local y = origin_y + (row_index - 1) * self.cell_height
    if y >= self.position.y + self.size.y then break end
    for _, run in ipairs(row.text_runs or {}) do
      if run.blink then self.has_blinking_content = true end
      if run.blink and not blink_on then goto continue_run end
      local x = origin_x + run.col * self.cell_width
      local width = run.columns * self.cell_width
      local color = rgb(self, run.fg, style.text)
      if run.faint then color = rgb(self, run.fg, style.text, 140) end
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
        local underline_color = rgb(self, run.underline_color, color)
        local thickness = math.max(1, SCALE)
        local underline_y = y + self.cell_height - thickness
        if run.underline == 3 then
          local step = math.max(2, 2 * SCALE)
          for offset = 0, width - 1, step do
            renderer.draw_rect(x + offset, underline_y - ((offset / step) % 2) * thickness,
              math.min(step, width - offset), thickness, underline_color)
          end
        elseif run.underline == 4 or run.underline == 5 then
          local mark = run.underline == 4 and thickness or math.max(3, 3 * SCALE)
          local gap = run.underline == 4 and math.max(2, 2 * SCALE) or math.max(2, 2 * SCALE)
          for offset = 0, width - 1, mark + gap do
            renderer.draw_rect(x + offset, underline_y, math.min(mark, width - offset),
              thickness, underline_color)
          end
        else
          renderer.draw_rect(x, underline_y, width, thickness, underline_color)
        end
        if run.underline == 2 then
          renderer.draw_rect(x, underline_y - 2 * thickness, width, thickness, underline_color)
        end
      end
      if run.strikethrough then
        renderer.draw_rect(
          x, y + math.floor(self.cell_height / 2),
          width, math.max(1, SCALE), color
        )
      end
      if run.overline then
        renderer.draw_rect(x, y, width, math.max(1, SCALE), color)
      end
      ::continue_run::
    end
  end
  perf_scope_end(phase_scope)

  phase_scope = perf_scope_begin("cursor")
  local cursor = snapshot.cursor
  local cursor_on = not (cursor and cursor.blinking) or blink_on
  if cursor and cursor.visible and cursor_on and self.running ~= false then
    local x = origin_x + (cursor.x or 0) * self.cell_width
    local y = origin_y + (cursor.y or 0) * self.cell_height
    local value = cursor.color or snapshot.foreground
    local color = rgb(self, value, style.caret)
    if cursor.style == "bar" then
      renderer.draw_rect(x, y, math.max(1, style.caret_width or SCALE), self.cell_height, color)
    elseif cursor.style == "underline" then
      renderer.draw_rect(x, y + self.cell_height - math.max(2, 2 * SCALE), self.cell_width, math.max(2, 2 * SCALE), color)
    elseif cursor.style == "hollow" then
      local thickness = math.max(1, SCALE)
      renderer.draw_rect(x, y, self.cell_width, thickness, color)
      renderer.draw_rect(x, y + self.cell_height - thickness, self.cell_width, thickness, color)
      renderer.draw_rect(x, y, thickness, self.cell_height, color)
      renderer.draw_rect(x + self.cell_width - thickness, y, thickness, self.cell_height, color)
    else
      renderer.draw_rect(
        x, y, self.cell_width, self.cell_height,
        rgb(self, value, style.caret, 110)
      )
    end
  end
  perf_scope_end(phase_scope)

  if self.composition and self.composition.text ~= "" and
      snapshot.cursor and snapshot.cursor.visible then
    local cursor = snapshot.cursor or {}
    local x = origin_x + (cursor.x or 0) * self.cell_width
    local y = origin_y + (cursor.y or 0) * self.cell_height
    local text = self.composition.text
    local width = math.max(self.cell_width, self.font:get_width(text))
    renderer.draw_rect(x, y, width, self.cell_height, style.background2 or background)
    renderer.draw_text(self.font, text, x, y, style.text)
    local before = text:sub(1, self.composition.start)
    local selected = text:sub(
      self.composition.start + 1,
      self.composition.start + self.composition.length
    )
    local selection_x = x + self.font:get_width(before)
    local selection_width = math.max(1, self.font:get_width(selected))
    renderer.draw_rect(
      selection_x, y + self.cell_height - math.max(1, SCALE),
      selection_width, math.max(1, SCALE), style.caret
    )
    ime.set_location(x, y, width, self.cell_height)
  end
  self:draw_scrollbar()
  perf_scope_end(draw_scope)
end

function TerminalView:on_text_input(text)
  if not self.session or self.running == false then return false end
  self.composition = nil
  core.blink_reset()
  self.session:scroll("bottom")
  if self.encoded_text_input then
    local encoded = self.encoded_text_input
    self.encoded_text_input = nil
    if text == encoded then return true end
  end
  return self.session:write(text) == true
end

function TerminalView:on_ime_text_editing(text, start, length)
  if not text or text == "" then
    self.composition = nil
  else
    self.composition = { text = text, start = start or 0, length = length or 0 }
  end
  core.redraw = true
  return true
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

function TerminalView:search(query, reverse)
  if not self.session or not query or query == "" then return false end
  self.search_query = query
  local found, state = self.session:search(query, reverse == true)
  if state == "pending" then
    self.search_pending = { query = query, reverse = reverse == true }
    return true
  end
  self.search_pending = nil
  if found then self:refresh_snapshot() end
  return found == true
end

function TerminalView:prompt_search()
  core.global_prompt_bar:enter("Terminal Search", {
    text = self.search_query or "",
    select_text = true,
    show_suggestions = false,
    submit = function(text) self:search(text, false) end,
  })
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
  self.encoded_text_input = nil
  if event and event.altgr and (#key == 1 or key == "space") then return false end
  local function scroll(kind, value)
    if not self.session:scroll(kind, value) then return false end
    self:refresh_snapshot()
    return true
  end
  if key == "pageup" and event and event.shift then
    return scroll("delta", -math.max(1, self.rows - 1))
  elseif key == "pagedown" and event and event.shift then
    return scroll("delta", math.max(1, self.rows - 1))
  elseif key == "home" and event and event.ctrl and event.shift then
    return scroll("top")
  elseif key == "end" and event and event.ctrl and event.shift then
    return scroll("bottom")
  end
  core.blink_reset()
  if not ({ lshift = true, rshift = true, lctrl = true, rctrl = true,
    lalt = true, ralt = true, lgui = true, rgui = true })[key] then
    self.session:scroll("bottom")
  end
  local action = event and event["repeat"] and "repeat" or "press"
  local encoded = self.session:key(key, key_modifiers(event), action, event) == true
  if encoded and event and type(event.text) == "string" and event.text ~= "" then
    self.encoded_text_input = event.text
  end
  return encoded
end

function TerminalView:on_key_released(key, event)
  if not self.session or self.running == false then return false end
  if event and event.altgr and (#key == 1 or key == "space") then return false end
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
  if not self.session then return end
  self.snapshot = self.session:snapshot(self.snapshot)
  core.redraw = true
end

function TerminalView:on_mouse_pressed(button, x, y, clicks)
  if not self.session then return false end
  local scrollbar = self.v_scrollbar:on_mouse_pressed(button, x, y, clicks)
  if scrollbar then
    if scrollbar ~= true then self:scroll_to_percent(scrollbar) end
    return true
  end
  core.set_active_view(self)
  local col, row, pixel_x, pixel_y = self:mouse_position(x, y)
  local tracking = self.snapshot and self.snapshot.mouse_tracking
  if tracking and not keymap.modkeys.shift then
    self.selection_start = nil
    self.selection_autoscroll = nil
    self.session:reset_selection_gesture()
    self.mouse_button = button
    self.session:clear_selection()
    self.session:mouse("press", button, pixel_x, pixel_y, mouse_modifiers())
  elseif button == "left" then
    if keymap.modkeys.ctrl then
      return self.session:open_hyperlink(col, row) == true
    end
    self.selection_start = true
    self.session:selection_gesture(
      "press", col, row, pixel_x, pixel_y, clicks or 1,
      keymap.modkeys.alt == true
    )
    self:refresh_snapshot()
  end
  return true
end

function TerminalView:on_mouse_moved(x, y, dx, dy)
  if not self.session then return false end
  local scrollbar = self.v_scrollbar:on_mouse_moved(x, y, dx or 0, dy or 0)
  if scrollbar then
    if scrollbar ~= true then self:scroll_to_percent(scrollbar) end
    return true
  end
  local col, row, pixel_x, pixel_y = self:mouse_position(x, y)
  if self.selection_start then
    local _, autoscroll = self.session:selection_gesture(
      "drag", col, row, pixel_x, pixel_y, 1,
      keymap.modkeys.alt == true
    )
    self.selection_autoscroll = autoscroll ~= "none" and autoscroll or nil
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
  if not self.session then return false end
  local _, _, pixel_x, pixel_y = self:mouse_position(x, y)
  if self.selection_start and button == "left" then
    local col, row = self:mouse_position(x, y)
    self.session:selection_gesture("release", col, row, 0, 0, 1, false)
    self.selection_start = nil
    self.selection_autoscroll = nil
    return true
  end
  if self.v_scrollbar.dragging then
    self.v_scrollbar:on_mouse_released(button, x, y)
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
  if self.session:scroll("delta", delta) then
    self.snapshot = self.session:snapshot(self.snapshot)
    core.redraw = true
    return true
  end
  return false
end

function TerminalView:can_close(approve)
  approve()
end

function TerminalView:on_close()
  self.pending_clipboard = nil
  if self.session then
    self.session:close()
    self.session = nil
    core.log_quiet("Terminal View closed")
  end
  TerminalView.super.on_close(self)
end

function M.open(options)
  options = options or {}
  return panes.place(function() return TerminalView(options) end, {
    pane = options.pane,
    placement = options.placement or "current",
    direction = options.direction,
    focus = options.focus,
    preserve_focus = options.preserve_focus,
    reason = options.reason or "terminal-open",
  })
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
M.TerminalTextCaptureView = TerminalTextCaptureView
M.from_state = TerminalView.from_state
TerminalView._module_name = "plugins.terminal"

command.add(nil, {
  ["terminal:open"] = command.palette(function()
    local context = command.get_invocation_context() or {}
    local pane = panes.find(context.source_pane or panes.active())
    local source_view = context.source_view or (pane and pane.current_view)
    return M.open {
      pane = pane,
      placement = context.placement or "current",
      direction = context.direction,
      focus = true,
      cwd = file_context.source_directory(source_view) or project_path("project"),
      reason = "terminal-open-here",
    } ~= nil
  end, {
    keywords = { "shell", "command", "view" },
    supports_placement = true,
    opens_view = true,
  }),
  ["terminal:open_at_project_root"] = command.palette(function()
    local context = command.get_invocation_context() or {}
    return M.open {
      pane = context.source_pane,
      placement = context.placement or "current",
      direction = context.direction,
      focus = true,
      cwd = project_path("project"),
      reason = "terminal-open-project-root",
    } ~= nil
  end, {
    keywords = { "shell", "command", "view" },
    supports_placement = true,
    opens_view = true,
  }),
  ["terminal:open_at_path"] = command.palette(function()
    local context = command.get_invocation_context() or {}
    local pane = panes.find(context.source_pane or panes.active())
    local source_view = context.source_view or (pane and pane.current_view)
    require("plugins.file_picker").open {
      select = "folder",
      source_pane = pane,
      source_view = source_view,
      submit = function(path, selection_context)
        M.open {
          pane = selection_context.source_pane,
          placement = selection_context.placement,
          direction = selection_context.direction,
          focus = true,
          cwd = path,
          reason = "terminal-open-path",
        }
      end,
    }
    return true
  end, {
    keywords = { "shell", "command", "folder", "external", "view" },
    supports_placement = true,
    opens_view = true,
  }),
})

command.add(function()
  local view = core.active_view
  return view and view.terminal_view == true, view
end, {
  ["terminal:paste"] = function(view)
    return view:paste(system.get_clipboard())
  end,
  ["terminal:copy"] = function(view)
    if not view.session then return false end
    local text = view.session:selected_text()
    if not text or text == "" then return false end
    system.set_clipboard(text)
    return true
  end,
  ["terminal:restart"] = command.palette(function(view) return view:restart() end),
  ["terminal:clear"] = command.palette(function(view)
    if not view.session:clear() then return false end
    view:refresh_snapshot()
    return true
  end),
  ["terminal:open_text_capture"] = command.palette(function(view)
    return view:open_text_capture()
  end, {
    keywords = { "navigate", "buffer", "scrollback", "text" },
    opens_view = true,
  }),
  ["terminal:search"] = command.palette(function(view) return view:prompt_search() end),
  ["terminal:search_next"] = function(view) return view:search(view.search_query, false) end,
  ["terminal:search_previous"] = function(view) return view:search(view.search_query, true) end,
})

keymap.add({
  ["ctrl+shift+c"] = "terminal:copy",
  ["ctrl+shift+v"] = "terminal:paste",
  ["ctrl+shift+f"] = { "terminal:search", "fuzzy:open_grep" },
  ["f3"] = "terminal:search_next",
  ["shift+f3"] = "terminal:search_previous",
  ["ctrl+shift+k"] = "terminal:clear",
})

return M
