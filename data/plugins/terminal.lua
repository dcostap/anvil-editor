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
local text_poi_locations = require "core.text_poi_locations"
local View = require "core.view"
local view_icons = require "core.view_icons"

local M = {}
local native_override
local next_session_id = 0

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
  {
    label = "Scrollback Lines",
    description = "Target number of physical output rows retained by new terminal sessions.",
    path = "scrollback_lines",
    type = "number",
    default = 10000,
    min = 1000,
    max = 100000,
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

local function validated_terminal_directory(path)
  if type(path) ~= "string" or path == "" or path:find("[%z%c]") then return nil end
  local local_path = path:match("^[A-Za-z]:[\\/]") ~= nil
    or path:match("^\\\\[^\\]+\\[^\\]+") ~= nil
  if not local_path then return nil end
  local info = system.get_file_info(path)
  return info and info.type == "dir" and path or nil
end

local function terminal_pwd(snapshot)
  local pwd = snapshot and snapshot.pwd
  if type(pwd) ~= "string" or pwd == "" then return nil end
  if pwd:find("[%z%c]") then return nil end
  if pwd:match("^file://") then
    local authority, path = pwd:match("^file://([^/]*)(/.*)$")
    if not path then return nil end
    if authority and authority ~= "" and authority:lower() ~= "localhost" then
      pwd = "\\\\" .. authority .. path:gsub("/", "\\")
    else
      pwd = path
      if pwd:match("^/[A-Za-z]:") then pwd = pwd:sub(2) end
    end
    pwd = pwd:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  end
  if pwd == "" or pwd:find("[%z%c]") then return nil end
  return validated_terminal_directory(pwd)
end

---@class plugins.terminal.view : core.view
local TerminalView = View:extend()
TerminalView.view_icon = view_icons.register("terminal", view_icons.ui("t"))

function TerminalView:__tostring() return "TerminalView" end

function TerminalView:refresh_cell_metrics()
  local font = style.terminal_font or style.code_font
  local cell_width = math.max(1, font:get_width("M"))
  local native_cell_width = math.max(1, math.ceil(cell_width))
  local cell_height = math.max(1, math.ceil(font:get_height()))
  local changed = self.font ~= font or self.cell_width ~= cell_width
    or self.native_cell_width ~= native_cell_width
    or self.cell_height ~= cell_height
  if changed and self.cell_width then
    core.log_quiet(
      "Terminal session %d cell geometry changed: %.2fx%d -> %.2fx%d",
      self.session_id or 0, self.cell_width, self.cell_height, cell_width, cell_height
    )
  end
  self.font = font
  self.cell_width = cell_width
  self.native_cell_width = native_cell_width
  self.cell_height = cell_height
  return changed
end

local function sanitize_title(title)
  if type(title) ~= "string" then return nil end
  title = title:gsub("%c+", " "):gsub("%s+", " ")
    :gsub("^%s+", ""):gsub("%s+$", "")
  if title == "" then return nil end
  local parts, bytes = {}, 0
  for char in common.utf8_chars(title) do
    if bytes + #char > 200 then break end
    parts[#parts + 1] = char
    bytes = bytes + #char
  end
  return table.concat(parts)
end

function TerminalView:new(options)
  TerminalView.super.new(self)
  options = options or {}
  self.context = "workspace"
  self.terminal_view = true
  self.scrollable = true
  self.cursor = "ibeam"
  self:refresh_cell_metrics()
  self.cols, self.rows = 80, 24
  self.color_cache = {}
  self.launch_options = {
    cwd = options.cwd or project_path(options.cwd_mode or terminal_config.cwd_mode),
    shell = options.shell or terminal_config.shell,
  }
  next_session_id = next_session_id + 1
  self.session_id = next_session_id
  self.state = "new"
  core.log_quiet("Terminal session %d start requested: shell=%s cwd=%s",
    self.session_id, self.launch_options.shell ~= "" and "custom" or "default",
    self.launch_options.cwd)

  local native, load_error = terminal_native()
  if not native then
    self.state = "failed"
    self.running = false
    self.launch_error = tostring(load_error or "The native terminal is unavailable.")
    core.log_quiet("Terminal session %d start failed: %s", self.session_id, self.launch_error)
    return
  end
  local native_options = session_colors()
  native_options.cols, native_options.rows = self.cols, self.rows
  native_options.cell_width, native_options.cell_height = self.native_cell_width, self.cell_height
  native_options.cwd, native_options.shell = self.launch_options.cwd, self.launch_options.shell
  native_options.scrollback_lines = terminal_config.scrollback_lines
  local session, start_error = native.new(native_options)
  if not session then
    self.state = "failed"
    self.running = false
    self.launch_error = tostring(start_error or "Could not start the terminal.")
    self.theme_generation = core.color_theme_generation or 0
    core.log_quiet("Terminal session %d start failed: %s", self.session_id, self.launch_error)
    return
  end
  self.session = session
  self.session_cell_width = self.native_cell_width
  self.session_cell_height = self.cell_height
  self.snapshot = session:snapshot()
  self.theme_generation = core.color_theme_generation or 0
  self.state = "running"
  self.running = true
  core.log_quiet("Terminal session %d started: cwd=%s cols=%d rows=%d",
    self.session_id, self.launch_options.cwd, self.cols, self.rows)
end

function TerminalView:get_name()
  local title = sanitize_title(self.snapshot and self.snapshot.title)
  if self.state == "failed" then
    return title and title ~= "" and string.format("%s (failed)", title)
      or "Terminal (failed)"
  elseif self.state == "exited" then
    local status = self.exit_code ~= nil and string.format("exit %d", self.exit_code) or "exited"
    return title and title ~= "" and string.format("%s (%s)", title, status)
      or string.format("Terminal (%s)", status)
  end
  return title and title ~= "" and title or "Terminal"
end

---@class plugins.terminal.text_capture_view : core.textview
local TerminalTextCaptureView = TextView:extend()

function TerminalTextCaptureView:__tostring() return "TerminalTextCaptureView" end

local function terminal_capture_font(view, span)
  if span.bold and span.italic then
    return style.terminal_bold_italic_font or view:get_font()
  end
  if span.bold then return style.terminal_bold_font or view:get_font() end
  if span.italic then return style.terminal_italic_font or view:get_font() end
  return view:get_font()
end

local terminal_capture_style_provider = {}

function terminal_capture_style_provider:render_line(view, line, context)
  local spans = view.terminal_capture_styles[line]
  if type(spans) ~= "table" or #spans == 0 then return nil end
  local fragments = {}
  for _, span in ipairs(spans) do
    local col1 = common.clamp(math.floor(span.col1 or 1), 1, #context.source_text + 1)
    local col2 = common.clamp(
      math.floor(span.col2 or col1), col1, #context.source_text + 1
    )
    if col2 > col1 then
      fragments[#fragments + 1] = {
        source_col1 = col1,
        source_col2 = col2,
        text = context.source_text:sub(col1, col2 - 1),
        color = rgb(
          view, span.fg, view.terminal_foreground or style.text,
          span.faint and 140 or 255
        ),
        background = span.background and rgb(
          view, span.background, view.terminal_background or style.background
        ) or nil,
        background_full_height = span.background ~= nil,
        font = terminal_capture_font(view, span),
        underline = span.underline and span.underline ~= 0,
        strikethrough = span.strikethrough == true,
      }
    end
  end
  return #fragments > 0 and { fragments = fragments } or nil
end

function TerminalTextCaptureView:new(source, capture)
  local terminal_title = sanitize_title(capture.title)
    or source and source.get_name and source:get_name()
    or "Terminal"
  capture = {
    text = tostring(capture.text or ""),
    cursor_line = capture.cursor_line,
    cursor_col = capture.cursor_col,
    viewport_line = capture.viewport_line,
    foreground = capture.foreground,
    background = capture.background,
    styles = capture.styles or {},
    title = terminal_title,
  }
  local buffer = Buffer()
  buffer.display_name = "Terminal Text"
  buffer:insert(1, 1, capture.text)
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
  self.terminal_title = terminal_title
  self.terminal_capture = capture
  self.font = "terminal_font"
  self.color_cache = {}
  self.terminal_foreground = rgb(self, capture.foreground, style.text)
  self.terminal_background = rgb(self, capture.background, style.background)
  self.terminal_capture_styles = capture.styles or {}
  self.show_line_numbers = false
  self.gutter_padding = PADDING
  self:set_wrapping_enabled(false)
  self:add_line_render_provider(
    "terminal-text-capture-styles", terminal_capture_style_provider
  )
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

function TerminalTextCaptureView:draw_background(color)
  return View.draw_background(self, self.terminal_background or color)
end

function TerminalTextCaptureView:get_name()
  return string.format("Terminal Text — %s", self.terminal_title or "Terminal")
end

function TerminalTextCaptureView:get_line_height()
  return math.max(1, math.ceil(self:get_font():get_height()))
end

function TerminalTextCaptureView:get_content_offset()
  local x, y = TerminalTextCaptureView.super.get_content_offset(self)
  return x, y + PADDING - style.padding.y
end

function TerminalTextCaptureView:duplicate()
  local line, col = self.buffer:get_selection()
  local capture = {
    text = self.terminal_capture.text,
    cursor_line = line,
    cursor_col = col,
    viewport_line = math.floor(self.scroll.y / self:get_line_height()) + 1,
    foreground = self.terminal_capture.foreground,
    background = self.terminal_capture.background,
    styles = self.terminal_capture.styles,
    title = self.terminal_title,
  }
  local duplicate = TerminalTextCaptureView(nil, capture)
  duplicate.scroll.x, duplicate.scroll.y = self.scroll.x, self.scroll.y
  duplicate.scroll.to.x, duplicate.scroll.to.y = self.scroll.to.x, self.scroll.to.y
  return duplicate
end

function TerminalView:get_cwd()
  local validated = terminal_pwd(self.snapshot)
  local reported = self.snapshot and self.snapshot.pwd
  if not validated and reported and reported ~= "" and reported ~= self.invalid_reported_directory then
    self.invalid_reported_directory = reported
    core.log_quiet("Terminal session %d ignored an unusable reported directory", self.session_id)
  end
  return validated
    or validated_terminal_directory(self.launch_options.cwd)
    or validated_terminal_directory(project_path("project"))
    or system.getcwd()
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
  return TerminalView { cwd = state.cwd, shell = state.shell }
end

function TerminalView:can_discard_from_history()
  return self.session == nil or self.state == "exited" or self.state == "failed"
end

function TerminalView:create_session()
  local native, load_error = terminal_native()
  if not native then return false, load_error end
  local native_options = session_colors()
  native_options.cols, native_options.rows = self.cols, self.rows
  native_options.cell_width, native_options.cell_height = self.native_cell_width, self.cell_height
  native_options.cwd, native_options.shell = self.launch_options.cwd, self.launch_options.shell
  native_options.scrollback_lines = terminal_config.scrollback_lines
  local session, start_error = native.new(native_options)
  if not session then return false, start_error or "Could not start the terminal." end
  return session
end

function TerminalView:adopt_session(session)
  self.session = session
  self.session_cell_width = self.native_cell_width
  self.session_cell_height = self.cell_height
  self.snapshot = session:snapshot()
  self.theme_generation = core.color_theme_generation or 0
  self.state = "running"
  self.running = true
  self.exit_code = nil
  self.reported_error = nil
  self.launch_error = nil
  self.status_revision = nil
  self.search_pending = nil
  self.search_query = nil
  self.search_state = nil
  self.key_owners = {}
  self.encoded_text_queue = {}
  self.pending_key_releases = {}
  self.composition = nil
  self.focused = nil
  self:sync_focus()
  core.redraw = true
end

function TerminalView:restart()
  if self.state ~= "exited" and self.state ~= "failed" then return false end
  local replacement, err = self:create_session()
  if not replacement then
    core.log_quiet("Terminal session %d restart failed", self.session_id)
    core.error("Could not restart terminal: %s", tostring(err))
    return false
  end
  local previous = self.session
  if self.vt_trace_path then self:stop_vt_trace() end
  self:adopt_session(replacement)
  if previous then previous:close() end
  core.log_quiet("Terminal session %d restarted", self.session_id)
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

function TerminalView:sync_geometry()
  if not self.session then return false end
  self:refresh_cell_metrics()
  local cols, rows = self:cell_geometry()
  if cols == self.cols and rows == self.rows
    and self.session_cell_width == self.native_cell_width
    and self.session_cell_height == self.cell_height
  then
    return false
  end
  if not self.session:resize(
      cols, rows, self.native_cell_width, self.cell_height
    )
  then
    return false
  end
  self.cols, self.rows = cols, rows
  self.session_cell_width = self.native_cell_width
  self.session_cell_height = self.cell_height
  core.log_quiet("Terminal session %d resized: cols=%d rows=%d",
    self.session_id, cols, rows)
  self.search_pending = nil
  self.search_state = nil
  self:clear_point_hover()
  local pane = panes.pane_for_view(self)
  local include_rows = pane ~= nil and pane.current_view == self and panes.is_visible(pane)
  self.snapshot = self.session:snapshot(self.snapshot, include_rows)
  if include_rows then core.redraw = true else self.rows_dirty = true end
  return true
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

function TerminalView:apply_status(status)
  if type(status) ~= "table" then return false end
  local revision = tonumber(status.revision)
  local kind = type(status.kind) == "string" and status.kind or self.state
  local changed = kind ~= self.state or revision ~= self.status_revision
  if not changed then return false end
  local previous = self.state
  self.state = kind
  self.status_revision = revision
  self.running = kind == "running"
  if kind == "exited" then self.exit_code = status.exit_code end
  if status.error and status.error ~= self.reported_error then
    self.reported_error = status.error
    if kind == "failed" then self.launch_error = status.error end
    core.error(status.error)
  end
  core.log_quiet("Terminal session %d state: %s -> %s",
    self.session_id, tostring(previous), tostring(kind))
  return true
end

function TerminalView:service_session(include_rows)
  if not self.session then return false end
  self:retry_pending_key_releases()
  local record_perf = include_rows and perf_is_recording()
  local update_started = record_perf and system.get_time()
  local changed, status = self.session:update()
  if record_perf then
    perf_detail("terminal_native_update_ms", (system.get_time() - update_started) * 1000)
  end
  local state_changed = self:apply_status(status)
  if changed then
    self:clear_point_hover()
    if not include_rows then self.rows_dirty = true end
  end
  local needs_snapshot = changed or state_changed or (include_rows and self.rows_dirty)
  if needs_snapshot then
    local snapshot_started = record_perf and system.get_time()
    self.snapshot = self.session:snapshot(self.snapshot, include_rows)
    self:handle_events()
    if include_rows then self.rows_dirty = nil end
    if record_perf then
      perf_detail("terminal_snapshot_ms", (system.get_time() - snapshot_started) * 1000)
      perf_detail("terminal_snapshot_calls", 1)
    end
    if include_rows then core.redraw = true end
  end
  return needs_snapshot
end

function TerminalView:sync_focus()
  if not self.session then return false end
  local pane = panes.pane_for_view(self)
  local window_focused = not system.window_has_focus or system.window_has_focus(core.window)
  local focused = pane ~= nil and pane.current_view == self and panes.is_visible(pane)
    and core.active_view == self and window_focused
  local focus_changed = focused ~= self.focused
  self.focused = focused
  if not focused then
    self.composition = nil
    for _, owned in pairs(self.key_owners or {}) do
      if type(owned) == "table" and owned.owner == "ghostty" then
        self:send_key_release(owned)
      end
    end
    self.key_owners = {}
    self.encoded_text_queue = {}
  end
  if not focus_changed then return false end
  self.session:focus(focused)
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

  self:sync_focus()

  self:sync_geometry()

  self:service_session(true)

  if self.search_pending then
    self:search(self.search_pending.query, self.search_pending.reverse)
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

local function trace_temp_directory()
  return os.getenv("TEMP") or os.getenv("TMP") or USERDIR
end

local function write_trace_model(path, text)
  local file, open_error = io.open(path, "wb")
  if not file then return false, open_error end
  local written, write_error = file:write(text)
  local closed, close_error = file:close()
  if not written then return false, write_error end
  if not closed then return false, close_error end
  return true
end

function TerminalView:start_vt_trace()
  if not self.session or not self.session.trace then return false end
  if self.vt_trace_path then
    core.error("Terminal VT trace is already active: %s", self.vt_trace_path)
    return false
  end
  local path = core.temp_filename(".terminal.vt", trace_temp_directory())
  local started, trace_error = self.session:trace(path)
  if not started then
    core.error("Could not start terminal VT trace: %s", tostring(trace_error or "unknown error"))
    return false
  end
  self.vt_trace_path = path
  core.log("Terminal VT trace started. It can contain private text: %s", path)
  return true
end

function TerminalView:stop_vt_trace()
  if not self.session or not self.session.trace or not self.vt_trace_path then return false end
  local path = self.vt_trace_path
  self.vt_trace_path = nil
  local stopped, bytes, trace_error = self.session:trace()
  local capture, capture_error = self.session:text_capture()
  local model_path = path .. ".model.txt"
  local model_written, model_error = false, capture_error
  if capture then
    model_written, model_error = write_trace_model(model_path, capture.text or "")
  end
  if not stopped then
    core.error("Terminal VT trace stopped with an error: %s", tostring(trace_error or "unknown error"))
  end
  if not model_written then
    core.error("Could not save terminal trace model: %s", tostring(model_error or "unknown error"))
  end
  if not stopped or not model_written then return false end
  core.log(
    "Terminal VT trace stopped: %d bytes\nRaw: %s\nModel: %s",
    bytes or 0, path, model_path
  )
  return true
end

function TerminalView:update_suspended()
  if not self.session then return end
  self:sync_focus()
  self:sync_geometry()
  self:service_session(false)
end

function TerminalView:prompt_clipboard_request(request)
  self.active_clipboard_request = request
  local preview = tostring(request.text or ""):gsub("[%c]", " "):sub(1, 80)
  local message = string.format(
    "A terminal program wants to replace the clipboard (%d bytes).\n\n%s",
    #tostring(request.text or ""), preview
  )
  core.nag_view:show(
    "Terminal Clipboard Request",
    message,
    {
      { text = "Allow", default_yes = false },
      { text = "Deny", default_no = true },
    },
    function(item)
      if item.text == "Allow" and self.active_clipboard_request == request then
        system.set_clipboard(request.text)
      end
      if self.active_clipboard_request == request then
        self.active_clipboard_request = nil
      end
      local queued = self.queued_clipboard_request
      self.queued_clipboard_request = nil
      if queued and self.session then self:prompt_clipboard_request(queued) end
    end
  )
end

function TerminalView:handle_events()
  for _, event in ipairs((self.snapshot and self.snapshot.events) or {}) do
    if event.type == "bell" then
      self.bell_count = (self.bell_count or 0) + (event.count or 1)
    elseif event.type == "clipboard" and event.text ~= nil then
      local request = { text = event.text, clear = event.clear == true }
      if self.active_clipboard_request then
        self.queued_clipboard_request = request
      else
        self:prompt_clipboard_request(request)
      end
    elseif event.type == "notification" then
      self.notification_count = (self.notification_count or 0) + (event.count or 1)
      core.log_quiet(
        "Terminal session %d received %d notification(s)",
        self.session_id, event.count or 1
      )
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
  self:draw_background(background)
  if not snapshot then
    if self.state == "failed" then
      local x = self.position.x + PADDING
      local y = self.position.y + PADDING
      local line_height = self.cell_height
      local shell = self.launch_options.shell ~= "" and "custom shell" or "default shell"
      renderer.draw_text(self.font, "Terminal start failed", x, y, style.text)
      renderer.draw_text(self.font, string.format("Directory: %s", self.launch_options.cwd),
        x, y + line_height, style.dim or style.text)
      renderer.draw_text(self.font, string.format("Shell: %s", shell),
        x, y + line_height * 2, style.dim or style.text)
      renderer.draw_text(self.font, tostring(self.launch_error or "Unknown terminal error"),
        x, y + line_height * 3, style.text)
    end
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

  local hover = self.hover_point
  if hover and hover.row ~= nil and hover.col ~= nil then
    renderer.draw_rect(
      origin_x + hover.col * self.cell_width,
      origin_y + hover.row * self.cell_height + self.cell_height - math.max(1, SCALE),
      math.max(self.cell_width,
        ((hover.end_col or hover.col) - hover.col + 1) * self.cell_width),
      math.max(1, SCALE), style.link or style.text
    )
  end

  phase_scope = perf_scope_begin("cursor")
  local cursor = snapshot.cursor
  local cursor_on = not (cursor and cursor.blinking) or blink_on
  if cursor and cursor.visible and cursor_on and self.running ~= false then
    local x = origin_x + (cursor.x or 0) * self.cell_width
    local y = origin_y + (cursor.y or 0) * self.cell_height
    local value = cursor.color or snapshot.foreground
    local color = rgb(self, value, style.caret)
    local cursor_style = self.focused and cursor.style or "hollow"
    if cursor_style == "bar" then
      renderer.draw_rect(x, y, math.max(1, style.caret_width or SCALE), self.cell_height, color)
    elseif cursor_style == "underline" then
      renderer.draw_rect(x, y + self.cell_height - math.max(2, 2 * SCALE), self.cell_width, math.max(2, 2 * SCALE), color)
    elseif cursor_style == "hollow" then
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
  if self.search_state and self.search_query then
    local label = self.search_state == "no_match"
      and string.format("No match: %s", self.search_query)
      or self.search_state == "searching"
        and string.format("Searching: %s", self.search_query)
        or string.format("Found: %s", self.search_query)
    renderer.draw_text(
      self.font, label,
      origin_x, self.position.y + self.size.y - self.cell_height - PADDING,
      self.search_state == "no_match" and (style.error or style.text)
        or (style.dim or style.text)
    )
  end
  self:draw_scrollbar()
  perf_scope_end(draw_scope)
end

function TerminalView:on_text_input(text)
  if not self.session or self.running == false then return false end
  self.composition = nil
  core.blink_reset()
  self.session:scroll("bottom")
  local encoded = self.encoded_text_queue and self.encoded_text_queue[1]
  if encoded and text == encoded.text then
    table.remove(self.encoded_text_queue, 1)
    return true
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
  if reason == "queue_full" then
    core.error("The terminal input queue is full. Try the paste again.")
    return false
  end
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
  if not self.session then return false end
  if not query or query == "" then
    self.search_pending = nil
    self.search_query = nil
    self.search_state = nil
    core.redraw = true
    return false
  end
  self.search_query = query
  self.search_state = "searching"
  local found, state = self.session:search(query, reverse == true)
  if state == "pending" then
    self.search_pending = { query = query, reverse = reverse == true }
    self.search_state = "searching"
    core.redraw = true
    return true
  end
  self.search_pending = nil
  self.search_state = found and "found" or "no_match"
  if found then self:refresh_snapshot() else core.redraw = true end
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

local function physical_key_id(key, event)
  if event and event.scancode ~= nil then return "scan:" .. tostring(event.scancode) end
  return "key:" .. tostring(key)
end

local function remove_encoded_key(view, key_id)
  local kept = {}
  for _, encoded in ipairs(view.encoded_text_queue or {}) do
    if encoded.key_id ~= key_id then kept[#kept + 1] = encoded end
  end
  view.encoded_text_queue = kept
end

function TerminalView:send_key_release(owned)
  local ok, reason = self.session:key(
    owned.key, owned.modifiers, "release", owned.event
  )
  if not ok and reason == "queue_full" then
    self.pending_key_releases = self.pending_key_releases or {}
    self.pending_key_releases[#self.pending_key_releases + 1] = owned
  end
  return ok == true
end

function TerminalView:retry_pending_key_releases()
  if not self.session or self.running == false or not self.pending_key_releases
      or #self.pending_key_releases == 0 then return false end
  local pending = self.pending_key_releases
  self.pending_key_releases = {}
  local sent = false
  for _, owned in ipairs(pending) do
    sent = self:send_key_release(owned) or sent
  end
  return sent
end

function TerminalView:on_key_pressed(key, event)
  if not self.session or self.running == false then return false end
  self:sync_focus()
  self:retry_pending_key_releases()
  self.key_owners = self.key_owners or {}
  self.encoded_text_queue = self.encoded_text_queue or {}
  local key_id = physical_key_id(key, event)
  if event and event.altgr and (#key == 1 or key == "space") then
    self.key_owners[key_id] = { owner = "text" }
    return false
  end
  local function scroll(kind, value)
    if not self.session:scroll(kind, value) then return false end
    self:refresh_snapshot()
    self.key_owners[key_id] = { owner = "anvil" }
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
  local encoded, reason = self.session:key(key, key_modifiers(event), action, event)
  encoded = encoded == true
  if reason == "queue_full" then
    core.log_quiet("Terminal session %d input queue is full", self.session_id)
  end
  self.key_owners[key_id] = {
    owner = encoded and "ghostty" or "text",
    key = key,
    modifiers = key_modifiers(event),
    event = event,
  }
  if encoded and event and type(event.text) == "string" and event.text ~= "" then
    self.encoded_text_queue[#self.encoded_text_queue + 1] = {
      text = event.text,
      key_id = key_id,
    }
  end
  return encoded
end

function TerminalView:on_key_released(key, event)
  if not self.session or self.running == false then return false end
  self.key_owners = self.key_owners or {}
  local key_id = physical_key_id(key, event)
  local owned = self.key_owners[key_id]
  self.key_owners[key_id] = nil
  remove_encoded_key(self, key_id)
  local owner = type(owned) == "table" and owned.owner or owned
  if key == "left ctrl" or key == "right ctrl" then self:clear_point_hover() end
  if owner ~= "ghostty" then return true end
  self:send_key_release(owned)
  return true
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
  local native_x = math.max(0, local_x) * self.native_cell_width / self.cell_width
  return col, row, native_x, math.max(0, local_y)
end

local function local_file_from_uri(uri)
  local authority, path = uri:match("^[Ff][Ii][Ll][Ee]://([^/]*)(/.*)$")
  if not path then return nil end
  path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  if authority ~= "" and authority:lower() ~= "localhost" then
    path = "\\\\" .. authority .. path:gsub("/", "\\")
  elseif path:match("^/[A-Za-z]:") then
    path = path:sub(2)
  end
  if path:find("[%z%c]") then return nil end
  local info = system.get_file_info(path)
  return info and info.type == "file" and path or nil
end

local function supported_uri_scheme(uri)
  if type(uri) ~= "string" or #uri > 32768 or uri:find("[%z%c]") then return nil end
  local scheme = uri:match("^([%a][%w+.-]*):")
  scheme = scheme and scheme:lower()
  if scheme == "http" or scheme == "https" or scheme == "mailto" or scheme == "file" then
    return scheme
  end
end

function TerminalView:activate_uri(uri)
  local scheme = supported_uri_scheme(uri)
  if scheme == "http" or scheme == "https" or scheme == "mailto" then
    return common.open_in_system(uri)
  elseif scheme == "file" then
    local path = local_file_from_uri(uri)
    if not path then return false end
    return core.open_file(path) ~= nil
  end
  return false
end

function TerminalView:point_of_interest_at(col, row)
  local uri = self.session:hyperlink(col, row)
  local scheme = supported_uri_scheme(uri)
  if scheme == "file" then
    local path = local_file_from_uri(uri)
    if path then return { kind = "terminal-location", path = path, col = col, row = row } end
  elseif scheme then
    return { kind = "uri", uri = uri, col = col, row = row }
  end
  if not self.session.row_text then return nil end
  local data = self.session:row_text(row)
  if type(data) ~= "table" or type(data.text) ~= "string" then return nil end
  local function covers(first, last)
    local columns = data.columns or {}
    local first_col = columns[first]
    local last_col = columns[math.max(first, last - 1)]
    return first_col and last_col and col >= first_col and col <= last_col,
      first_col, last_col
  end
  for _, pattern in ipairs({
    "[Hh][Tt][Tt][Pp]://[^%s<>]+",
    "[Hh][Tt][Tt][Pp][Ss]://[^%s<>]+",
    "[Mm][Aa][Ii][Ll][Tt][Oo]:[^%s<>]+",
  }) do
    for first, value, last in data.text:gmatch("()(" .. pattern .. ")()") do
      local hit, first_col, last_col = covers(first, last)
      if hit then
        return {
          kind = "uri", uri = value:gsub("[%),%.%;]+$", ""),
          col = first_col, end_col = last_col, row = row, generation = data.generation,
        }
      end
    end
  end
  for _, candidate in ipairs(text_poi_locations.extract_candidates(data.text, 128)) do
    local point = text_poi_locations.resolve_candidate(
      candidate, self:get_cwd(), "terminal-location"
    )
    if point then
      local hit, first_col, last_col = covers(candidate.col, candidate.col2)
      if hit then
        point.col, point.end_col, point.row = first_col, last_col, row
        point.generation = data.generation
        return point
      end
    end
  end
end


local function same_point(a, b)
  return a and b and a.kind == b.kind and a.uri == b.uri and a.path == b.path
    and a.target_line == b.target_line and a.target_col == b.target_col
    and a.generation == b.generation and a.col == b.col and a.row == b.row
end

function TerminalView:clear_point_hover()
  if not self.hover_point and not self.hover_cell and self.cursor == "ibeam" then return false end
  self.hover_point = nil
  self.hover_cell = nil
  self.cursor = "ibeam"
  core.redraw = true
  return true
end

function TerminalView:on_mouse_left()
  TerminalView.super.on_mouse_left(self)
  if self.uri_gesture then self.uri_gesture.cancelled = true end
  self:clear_point_hover()
end

function TerminalView:contains_terminal_cell(x, y)
  local left = self.position.x + PADDING
  local top = self.position.y + PADDING
  return x >= left and y >= top
    and x < left + self.cols * self.cell_width
    and y < top + self.rows * self.cell_height
end

function TerminalView:activate_point_of_interest(point)
  if not point then return false end
  if point.uri then return self:activate_uri(point.uri) end
  if point.path then
    return core.open_file(point.path, {
      line = point.target_line or 1,
      col = point.target_col or 1,
    }) ~= nil
  end
  return false
end

function TerminalView:refresh_snapshot()
  if not self.session then return end
  self:clear_point_hover()
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
  if button == "left" and keymap.modkeys.ctrl and self:contains_terminal_cell(x, y) then
    local point = self:point_of_interest_at(col, row)
    if point then
      self.uri_gesture = { point = point, col = col, row = row, cancelled = false }
      return true
    end
  end
  local tracking = self.snapshot and self.snapshot.mouse_tracking
  if tracking and not keymap.modkeys.shift then
    self.selection_start = nil
    self.selection_autoscroll = nil
    self.session:reset_selection_gesture()
    self.mouse_button = button
    self.session:clear_selection()
    self.session:mouse("press", button, pixel_x, pixel_y, mouse_modifiers())
  elseif button == "left" then
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
  if self.uri_gesture then
    if not self:contains_terminal_cell(x, y) then
      self.uri_gesture.cancelled = true
      return true
    end
    local col, row = self:mouse_position(x, y)
    local point = self:point_of_interest_at(col, row)
    local target = self.uri_gesture.point
    if col ~= self.uri_gesture.col or row ~= self.uri_gesture.row
        or not same_point(point, target) then
      self.uri_gesture.cancelled = true
    end
    return true
  end
  local scrollbar = self.v_scrollbar:on_mouse_moved(x, y, dx or 0, dy or 0)
  if scrollbar then
    if scrollbar ~= true then self:scroll_to_percent(scrollbar) end
    return true
  end
  local col, row, pixel_x, pixel_y = self:mouse_position(x, y)
  if keymap.modkeys.ctrl then
    local cell = string.format("%d:%d", col, row)
    if cell ~= self.hover_cell then
      self.hover_cell = cell
      self.hover_point = self:point_of_interest_at(col, row)
      self.cursor = self.hover_point and "hand" or "ibeam"
      core.redraw = true
    end
    return self.hover_point ~= nil
  elseif self.hover_point then
    self:clear_point_hover()
  end
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
  if self.uri_gesture and button == "left" then
    local gesture = self.uri_gesture
    self.uri_gesture = nil
    local inside = self:contains_terminal_cell(x, y)
    local col, row = self:mouse_position(x, y)
    local point = self:point_of_interest_at(col, row)
    local target = gesture.point
    if inside and not gesture.cancelled and col == gesture.col and row == gesture.row
        and same_point(point, target) then
      self:activate_point_of_interest(target)
    end
    return true
  end
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
    self:clear_point_hover()
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
  self.active_clipboard_request = nil
  self.queued_clipboard_request = nil
  if self.session then
    if self.vt_trace_path then self:stop_vt_trace() end
    local stats = self.session.stats and self.session:stats() or {}
    self.session:close()
    self.session = nil
    core.log_quiet(
      "Terminal session %d closed: read=%d parsed=%d queued=%d rejected=%d",
      self.session_id, stats.output_bytes_read or 0, stats.output_bytes_parsed or 0,
      stats.input_bytes_queued or 0, stats.rejected_writes or 0
    )
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
  for _, pane in ipairs(panes.ordered()) do
    for _, view in ipairs(panes.views(pane)) do
      if view.terminal_view then open[#open + 1] = view end
    end
  end
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
  ["terminal:focus_next"] = command.palette(function()
    local terminals = M.open_views()
    if #terminals == 0 then return false end
    local current = 0
    for index, view in ipairs(terminals) do
      if view == core.active_view then current = index break end
    end
    for offset = 1, #terminals do
      local view = terminals[(current + offset - 1) % #terminals + 1]
      local pane = panes.pane_for_view(view)
      if pane and panes.present(view, { pane = pane, focus = true }) then return true end
    end
    return false
  end, {
    keywords = { "terminal", "focus", "next", "session" },
    opens_view = true,
  }),
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
    if not view.session then return false end
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
  ["terminal:start_vt_trace"] = command.palette(function(view)
    return view:start_vt_trace()
  end, {
    keywords = { "terminal", "diagnostic", "record", "raw", "output" },
  }),
  ["terminal:stop_vt_trace"] = command.palette(function(view)
    return view:stop_vt_trace()
  end, {
    keywords = { "terminal", "diagnostic", "record", "raw", "output" },
  }),
  ["terminal:search"] = command.palette(function(view) return view:prompt_search() end),
  ["terminal:search_next"] = function(view) return view:search(view.search_query, false) end,
  ["terminal:search_previous"] = function(view) return view:search(view.search_query, true) end,
})

keymap.add({
  ["ctrl+shift+c"] = "terminal:copy",
  ["ctrl+shift+v"] = "terminal:paste",
  ["ctrl+shift+f"] = { "terminal:search", "fuzzy:open_grep" },
  ["f2"] = "terminal:open_text_capture",
  ["f3"] = "terminal:search_next",
  ["shift+f3"] = "terminal:search_previous",
  ["ctrl+shift+k"] = "terminal:clear",
})

return M
