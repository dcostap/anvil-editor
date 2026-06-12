-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local ime = require "core.ime"
local StatusBar = require "core.statusbar"
local View = require "core.view"
local native_text = require "native_text"

local TREE_SITTER_REPARSE_DELAY = 0.25

local plugin_config = config.plugins.native_editor or config.plugins.native_text_sandbox or {}
local save_native_view_as
local save_existing_native_view
local last_find_text
local close_native_view
local find_open_native_text_buffer

local function native_file_identity(filename)
  if type(filename) ~= "string" or filename == "" then return nil end
  local ok, absolute = pcall(system.absolute_path, filename)
  if ok and absolute then filename = absolute end
  return common.path_compare_key(filename)
end

local function open_registered_native_buffer(filename)
  local identity_key = native_file_identity(filename)
  local buffer, reused_or_error = native_text.open_file_buffer(filename, identity_key or filename)
  if not buffer then
    core.error("%s", reused_or_error or string.format("Failed to open native Buffer: %s", filename))
    return nil, identity_key, false
  end
  return buffer, identity_key, reused_or_error == true
end

local NativeEditorView = View:extend()

function NativeEditorView:__tostring() return "NativeEditorView" end

NativeEditorView.context = "workspace"
NativeEditorView.native_editor_view = true
NativeEditorView._module_name = "plugins.native_editor"

local function is_native_editor_view(view)
  return type(view) == "table"
    and view.native_editor_view == true
    and view.buffer ~= nil
    and view.editor ~= nil
end
core.is_native_editor_view = is_native_editor_view

local function active_native_editor_view()
  local view = core.active_view
  if is_native_editor_view(view) then return true, view end
  return false
end

function NativeEditorView:new(text, filename, buffer, identity_key)
  NativeEditorView.super.new(self)
  self.buffer = buffer or native_text.new_buffer(text or "Native editor\n\nType here. This view is backed by src/text Buffer/Editor userdata.")
  self.buffer_identity_key = identity_key
  if filename and not buffer then
    local ok = self.buffer:load_file(filename)
    if ok then
      self.buffer_identity_key = native_file_identity(filename)
      if self.buffer_identity_key then native_text.register_file_buffer(self.buffer_identity_key, self.buffer) end
    else
      core.error("Failed to open native Buffer: %s", filename)
    end
  end
  self.tree_sitter_enabled = false
  self:enable_tree_sitter_for_path(filename or self.buffer:path())
  self.editor = self.buffer:new_editor()
  self.file_signature = nil
  self.external_reload_prompting = false
  self:update_file_signature()
  self.tree_sitter_dirty_since = nil
  self.h_scrollable_size = 0
  self.scrollable = true
  self.cursor = "ibeam"
  self.font = "code_font"
  self.v_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.h_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.ime_selection = { from = 0, size = 0 }
  self.ime_status = false
end

function NativeEditorView:enable_tree_sitter_for_path(filename)
  local language = filename and native_text.tree_sitter_language_for_filename(filename) or nil
  self.tree_sitter_enabled = language and self.buffer:enable_tree_sitter(language) or false
  if language then
    if self.tree_sitter_enabled then
      core.log_quiet("Native editor enabled Tree-sitter language '%s' for %s", language, filename or "scratch")
    else
      core.log_quiet("Native editor failed to enable Tree-sitter language '%s' for %s", language, filename or "scratch")
    end
  end
end

local function file_signature(path)
  local info = path and system.get_file_info(path)
  if not info or info.type ~= "file" then return nil end
  return { modified = info.modified, size = info.size }
end

local function same_file_signature(a, b)
  if not a or not b then return a == b end
  return a.modified == b.modified and a.size == b.size
end

function NativeEditorView:update_file_signature()
  self.file_signature = file_signature(self.buffer:path())
end

function NativeEditorView:reload_from_disk()
  local path = self.buffer:path()
  if not path then return false end
  local buffer = self.buffer
  if not buffer:load_file(path) then
    core.error("Failed to reload native Buffer: %s", path)
    return false
  end
  local root = core.root_panel and core.root_panel.root_node
  local views = root and root:get_children() or { self }
  for _, view in ipairs(views) do
    if view:is(NativeEditorView) and view.buffer == buffer then
      view:enable_tree_sitter_for_path(path)
      view.editor:set_cursor(0)
      view:update_file_signature()
      view.external_reload_prompting = false
      view.tree_sitter_dirty_since = nil
      view.native_indent_info = nil
    end
  end
  core.log_quiet("Reloaded shared native Buffer from disk: %s", path)
  core.redraw = true
  return true
end

function NativeEditorView:check_external_file_change()
  local path = self.buffer:path()
  if not path or self.external_reload_prompting then return end
  local current = file_signature(path)
  if same_file_signature(self.file_signature, current) then return end
  if not self:is_dirty() then
    self.file_signature = current
    self:reload_from_disk()
    return
  end
  self.external_reload_prompting = true
  core.nag_view:show("Native Buffer Changed", path .. " changed on disk. Reload this file?", {
    { text = "Reload From Disk", default_yes = true },
    { text = "Ignore", default_no = true },
  }, function(item)
    if item.text == "Reload From Disk" then
      self:reload_from_disk()
    else
      self.external_reload_prompting = false
      self:update_file_signature()
    end
  end)
end

function NativeEditorView:is_dirty()
  return self.native_new_file == true or self.buffer:is_dirty()
end

function NativeEditorView:get_name()
  local path = self.buffer:path()
  local name = path and common.basename(path) or "Native Editor"
  if self:is_dirty() then name = "*" .. name end
  return name
end

function NativeEditorView:get_filename()
  local path = self.buffer:path()
  if path then
    return common.home_encode(path) .. (self:is_dirty() and "*" or "")
  end
  return self:get_name()
end

function NativeEditorView:on_close()
  if self.buffer_identity_key and not find_open_native_text_buffer(self.buffer, self) then
    native_text.release_file_buffer(self.buffer_identity_key, self.buffer)
    self.buffer_identity_key = nil
  end
end

function NativeEditorView:try_close(do_close)
  if not self:is_dirty() then
    close_native_view(self, do_close)
    return
  end

  local path = self.buffer:path()
  core.global_prompt_bar:enter("Unsaved Native Buffer; Confirm Close", {
    submit = function(_, item)
      if item.text:match("^[cC]") then
        close_native_view(self, do_close)
      elseif item.text:match("^[sS]") then
        if path then
          save_existing_native_view(self, true, do_close)
        elseif save_native_view_as then
          save_native_view_as(self, true)
        end
      end
    end,
    suggest = function(text)
      local items = {}
      if not text:find("^[^cC]") then table.insert(items, "Close Without Saving") end
      if not text:find("^[^sS]") then table.insert(items, path and "Save And Close" or "Save As And Close") end
      return items
    end
  })
end

function NativeEditorView:supports_text_input()
  return true
end

function NativeEditorView:get_state()
  local cursors = {}
  for i = 1, self.editor:cursor_count() do
    cursors[i] = self.editor:cursor(i)
  end
  return {
    filename = self.buffer:path(),
    text = self.buffer:path() and nil or self.buffer:text(),
    scroll = { x = self.scroll.x, y = self.scroll.y },
    scroll_to = { x = self.scroll.to.x, y = self.scroll.to.y },
    cursors = cursors,
  }
end

function NativeEditorView.from_state(state)
  state = state or {}
  local buffer, identity_key
  if state.filename then
    buffer, identity_key = open_registered_native_buffer(state.filename)
  end
  local view = NativeEditorView(state.text, state.filename, buffer, identity_key)
  local scroll = state.scroll or {}
  local scroll_to = state.scroll_to or scroll
  view.scroll.x = scroll.x or 0
  view.scroll.y = scroll.y or 0
  view.scroll.to.x = scroll_to.x or view.scroll.x
  view.scroll.to.y = scroll_to.y or view.scroll.y
  if type(state.cursors) == "table" and #state.cursors > 0 then
    view.editor:clear_multi_cursors()
    for i, cursor in ipairs(state.cursors) do
      if i == 1 then
        view.editor:set_cursor(cursor.cursor or 0, cursor.selection)
      else
        view.editor:add_cursor(cursor.cursor or 0, cursor.selection)
      end
    end
  end
  return view
end

function NativeEditorView:note_tree_sitter_mutation()
  self.native_indent_info = nil
  if self.tree_sitter_enabled and self.buffer:tree_sitter_is_dirty() then
    self.tree_sitter_dirty_since = system.get_time()
    core.redraw = true
  end
end

function NativeEditorView:update_tree_sitter()
  if not self.tree_sitter_enabled then return end
  if self.buffer:poll_tree_sitter_reparse() then
    core.log_quiet("Native editor applied background Tree-sitter parse")
    self.tree_sitter_dirty_since = nil
    core.redraw = true
    return
  end

  if not self.buffer:tree_sitter_is_dirty() then
    self.tree_sitter_dirty_since = nil
    return
  end

  local now = system.get_time()
  self.tree_sitter_dirty_since = self.tree_sitter_dirty_since or now
  if not self.buffer:tree_sitter_parse_pending()
    and now - self.tree_sitter_dirty_since >= TREE_SITTER_REPARSE_DELAY
  then
    if self.buffer:schedule_tree_sitter_reparse() then
      core.log_quiet("Native editor scheduled background Tree-sitter parse after idle debounce")
    else
      core.log_quiet("Native editor failed to schedule Tree-sitter parse; will retry after debounce")
      self.tree_sitter_dirty_since = now
    end
  end
  core.redraw = true
end

function NativeEditorView:cursor_signature()
  local parts = {}
  for i = 1, self.editor:cursor_count() do
    local cursor = self.editor:cursor(i)
    parts[#parts + 1] = tostring(cursor.cursor or 0) .. ":" .. tostring(cursor.selection or "")
  end
  return table.concat(parts, ";")
end

function NativeEditorView:update_blink()
  if config.disable_blink or core.active_view ~= self or self.mouse_selecting then return end
  if not system.window_has_focus(core.window) then return end
  local period = config.blink_period or 0.8
  local t0 = core.blink_start or 0
  local previous = core.blink_timer or 0
  local now = system.get_time()
  if ((now - t0) % period < period / 2) ~= ((previous - t0) % period < period / 2) then
    core.redraw = true
  end
  core.blink_timer = now
end

function NativeEditorView:update()
  NativeEditorView.super.update(self)
  self:update_tree_sitter()
  local signature = self:cursor_signature()
  if signature ~= self.last_cursor_signature then
    self.last_cursor_signature = signature
    core.blink_reset()
  end
  self:update_blink()
  self:update_ime_location()
end

local function native_indent_occurs_near(stat, idx)
  return (stat[idx - 1] and stat[idx - 1] == stat[idx])
    or (stat[idx + 1] and stat[idx + 1] == stat[idx])
end

local function native_optimal_indent_from_stat(stat)
  if #stat == 0 then return nil, 0 end
  table.sort(stat, function(a, b) return a > b end)
  local best_indent = 0
  local best_score = 0
  for x = 1, #stat do
    local indent = stat[x]
    local score = 0
    for y = 1, #stat do
      if y ~= x and stat[y] % indent == 0 then
        score = score + 1
      elseif indent > stat[y] and (native_indent_occurs_near(stat, y) or (y == #stat and stat[y] > 1)) then
        score = 0
        break
      end
    end
    if score > best_score then
      best_indent = indent
      best_score = score
    end
    if score > 0 then break end
  end
  return best_score > 0 and best_indent or nil, best_score
end

function NativeEditorView:get_indent_info()
  if self.native_indent_info then
    return self.native_indent_info.type, self.native_indent_info.size, self.native_indent_info.confirmed
  end

  local stat = {}
  local tab_count = 0
  local max_lines = math.min(math.max(1, self.buffer:line_count()), 750)
  for line = 0, max_lines - 1 do
    local text = self:get_line_text(line)
    if text:find("%S") then
      local spaces = text:match("^ +")
      if spaces then stat[#stat + 1] = #spaces end
      if text:match("^\t+") then tab_count = tab_count + 1 end
    end
  end

  local indent, score = native_optimal_indent_from_stat(stat)
  local indent_type, indent_size
  if tab_count > score then
    indent_type, indent_size, score = "hard", config.indent_size, tab_count
  else
    indent_type, indent_size = "soft", indent or config.indent_size
  end
  local confirmed = score >= 2
  if not confirmed then
    indent_type, indent_size = config.tab_type, config.indent_size
  end
  self.native_indent_info = { type = indent_type, size = indent_size, confirmed = confirmed }
  return indent_type, indent_size, confirmed
end

function NativeEditorView:get_font()
  local font = style[self.font or "code_font"] or style.code_font or style.font
  local _, indent_size = self:get_indent_info()
  if font.set_tab_size then font:set_tab_size(indent_size) end
  return font
end

function NativeEditorView:get_line_height()
  return math.floor(self:get_font():get_height() * config.line_height)
end

function NativeEditorView:with_centered_editor_geometry(fn, ...)
  local centered = core.centered_editor
  if centered and centered.with_editor_geometry and centered.should_center and centered.should_center(self) then
    return centered.with_editor_geometry(self, fn, ...)
  end
  return fn(...)
end

function NativeEditorView:get_line_text_y_offset()
  return (self:get_line_height() - self:get_font():get_height()) / 2
end

function NativeEditorView:get_line_text(line)
  return (self.buffer:line(line) or ""):gsub("\r?\n$", "")
end

function NativeEditorView:get_gutter_width()
  local padding = style.padding.x * 2
  local width = config.show_line_numbers and self:get_font():get_width(tostring(math.max(1, self.buffer:line_count()))) or 0
  -- Match the old DocView/gitdiff layout habit of reserving a tiny marker lane
  -- between line numbers and text so the content edge and future diff markers do
  -- not cause the text to shift when they appear.
  local marker_lane = style.padding.x * (style.gitdiff_width or 3) / 12
  return math.max(style.padding.x, width + padding + marker_lane), padding
end

function NativeEditorView:get_horizontal_scrollbar_height()
  local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
  return h_scroll or 0
end

function NativeEditorView:get_vertical_viewport_height()
  return math.max(0, self.size.y - self:get_horizontal_scrollbar_height())
end

local function native_normalize_scroll_context_lines()
  return math.max(0, math.floor(tonumber(config.scroll_context_lines) or 0))
end

function NativeEditorView:get_visible_scroll_context_lines()
  local lh = self:get_line_height()
  if lh <= 0 then return 0 end
  local visible_span = math.max(0, math.floor((self:get_vertical_viewport_height() - style.padding.y) / lh))
  return math.min(native_normalize_scroll_context_lines(), math.floor(visible_span / 2))
end

function NativeEditorView:get_scroll_past_end_context_lines()
  local lh = self:get_line_height()
  if lh <= 0 then return 0 end
  local max_context = math.max(0, math.floor((self:get_vertical_viewport_height() - style.padding.y - lh) / lh))
  return math.min(native_normalize_scroll_context_lines(), max_context)
end

function NativeEditorView:get_scrollable_size()
  local line_count = math.max(1, self.buffer:line_count())
  local lh = self:get_line_height()
  local text_height = line_count * lh + style.padding.y * 2
  if config.scroll_past_end then
    local pad = self:get_scroll_past_end_context_lines()
    local last_line_y = style.padding.y + lh * math.max(0, line_count - 1)
    local max_scroll = math.max(0, last_line_y - self:get_vertical_viewport_height() + lh * (pad + 1))
    return math.max(self.size.y, max_scroll + self.size.y)
  end
  if text_height <= self.size.y then return self.size.y end
  return text_height + self:get_horizontal_scrollbar_height()
end

function NativeEditorView:get_h_scrollable_size()
  return math.max(self.size.x, self.h_scrollable_size or 0)
end

function NativeEditorView:get_visible_line_range()
  local lh = self:get_line_height()
  local minline = math.max(1, math.floor((self.scroll.y - style.padding.y) / lh) + 1)
  local maxline = math.min(math.max(1, self.buffer:line_count()), math.floor((self.scroll.y + self.size.y - style.padding.y) / lh) + 1)
  return minline, maxline
end

function NativeEditorView:get_visible_cols_range(line, extra_cols)
  extra_cols = extra_cols or 100
  local text = self:get_line_text((line or 1) - 1)
  local char_width = math.max(1, self:get_font():get_width("m"))
  local first = math.max(1, math.floor(self.scroll.x / char_width) - extra_cols)
  local last = math.min(#text + 1, math.ceil((self.scroll.x + self.size.x) / char_width) + extra_cols)
  return first, last, first, last
end

function NativeEditorView:get_col_x_offset(line, col)
  local text = self:get_line_text((line or 1) - 1)
  col = common.clamp(col or 1, 1, #text + 1)
  return self:get_font():get_width(text:sub(1, col - 1))
end

local function next_utf8_byte_index(text, byte_index)
  byte_index = common.clamp(byte_index or 1, 1, #text + 1)
  local ok, next_index = pcall(utf8.offset, text, 2, byte_index)
  if ok and next_index then return next_index end
  return math.min(#text + 1, byte_index + 1)
end

local function utf8_char_count_range(text, start_col, end_col)
  start_col = common.clamp(start_col or 0, 0, #text)
  end_col = common.clamp(end_col or #text, start_col, #text)
  local count = 0
  local byte_index = start_col + 1
  while byte_index <= end_col do
    local next_index = next_utf8_byte_index(text, byte_index)
    if next_index - 1 > end_col then break end
    count = count + 1
    byte_index = next_index
  end
  return count
end

local function utf8_char_count_prefix(text, byte_count)
  return utf8_char_count_range(text, 0, byte_count or #text)
end

function NativeEditorView:get_x_offset_col(line, xoffset)
  local text = self:get_line_text((line or 1) - 1)
  xoffset = math.max(0, xoffset or 0)
  local col = 1
  local byte_index = 1
  while byte_index <= #text do
    local next_index = next_utf8_byte_index(text, byte_index)
    local prev_width = self:get_font():get_width(text:sub(1, byte_index - 1))
    local next_width = self:get_font():get_width(text:sub(1, next_index - 1))
    if xoffset < (prev_width + next_width) / 2 then break end
    col = next_index
    byte_index = next_index
  end
  return col
end

function NativeEditorView:line_col_to_screen(line, col)
  return self:with_centered_editor_geometry(function(line, col)
    local lh = self:get_line_height()
    col = common.clamp(col or 0, 0, #self:get_line_text(line))
    local x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x + self:get_col_x_offset(line + 1, col + 1)
    local y = self.position.y + style.padding.y - self.scroll.y + line * lh
    return x, y
  end, line, col)
end

-- DocView-compatible helpers use one-based line/column coordinates. They make
-- lightweight view-adjacent code easier to share without exposing native Buffer
-- internals or the old Doc API.
function NativeEditorView:get_line_screen_position(line, col)
  return self:line_col_to_screen(math.max(0, (line or 1) - 1), col and math.max(0, col - 1) or 0)
end

function NativeEditorView:cursor_line_col(cursor)
  cursor = cursor or (self.editor:cursor().cursor or 0)
  local lc = self.buffer:offset_to_line_col(cursor)
  return lc and lc.line or 0, lc and lc.col or 0
end

function NativeEditorView:screen_to_line_col(x, y)
  return self:with_centered_editor_geometry(function(x, y)
    local lh = self:get_line_height()
    local line = math.floor((y - self.position.y + self.scroll.y - style.padding.y) / lh)
    line = common.clamp(line, 0, math.max(0, self.buffer:line_count() - 1))
    local text_x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x
    local relx = math.max(0, x - text_x)
    return line, self:get_x_offset_col(line + 1, relx) - 1
  end, x, y)
end

function NativeEditorView:screen_to_offset(x, y)
  local line, col = self:screen_to_line_col(x, y)
  return self.buffer:line_col_to_offset(line, col)
end

function NativeEditorView:resolve_screen_position(x, y)
  local line, col = self:screen_to_line_col(x, y)
  return line + 1, col + 1
end

function NativeEditorView:get_caret_draw_position(caret_idx, x, y)
  if not config.animated_caret then return x, y end
  caret_idx = caret_idx or 1
  self.animated_caret_positions = self.animated_caret_positions or {}
  local pos = self.animated_caret_positions[caret_idx]
  if not pos then
    pos = { x = x, y = y }
    self.animated_caret_positions[caret_idx] = pos
    return x, y
  end

  local now = system.get_time()
  local last = pos.last_time or now
  pos.last_time = now
  local dt = math.min(now - last, 1 / 120)
  local dx = x - pos.x
  local dy = y - pos.y

  if math.abs(dy) > 0.1 then
    pos.x = x
    pos.y = y
  else
    local distance = math.abs(dx)
    local distance_min = config.animated_caret_distance_min or 4
    local distance_max = config.animated_caret_distance_max or 160
    local distance_span = math.max(1, distance_max - distance_min)
    local distance_t = math.max(0, math.min(1, (distance - distance_min) / distance_span))
    local min_speed = config.animated_caret_min_speed or 35
    local max_speed = config.animated_caret_max_speed or 100
    local speed = min_speed + (max_speed - min_speed) * distance_t
    local linear_t = 1 - math.exp(-speed * dt)
    local t = 1 - math.pow(1 - linear_t, 3)
    pos.x = pos.x + dx * t
    pos.y = y
    if math.abs(x - pos.x) > 0.1 then
      core.redraw = true
    else
      pos.x = x
    end
  end
  return pos.x, pos.y
end

function NativeEditorView:draw_caret_for_cursor(cursor, caret_idx)
  if core.active_view == self and not config.disable_blink and not self.mouse_selecting and system.window_has_focus(core.window) then
    local period = config.blink_period or 0.8
    local t0 = core.blink_start or 0
    if (system.get_time() - t0) % period >= period / 2 then return end
  end
  local cursor_line, cursor_col = self:cursor_line_col(cursor.cursor or 0)
  local caret_x, caret_y = self:line_col_to_screen(cursor_line, cursor_col)
  caret_x, caret_y = self:get_caret_draw_position(caret_idx, caret_x, caret_y)
  local color = core.active_view == self and style.caret or style.dim
  local caret_width = style.caret_width or math.max(1, SCALE)
  if self.editor.overwrite_mode and self.editor:overwrite_mode() then
    local text = self:get_line_text(cursor_line)
    local byte_index = common.clamp(cursor_col + 1, 1, #text + 1)
    local next_index = next_utf8_byte_index(text, byte_index)
    local char = text:sub(byte_index, next_index - 1)
    local width = char ~= "" and self:get_font():get_width(char) or caret_width
    renderer.draw_rect(caret_x, caret_y + self:get_line_height() - caret_width * 2, width, caret_width * 2, color)
  else
    renderer.draw_rect(caret_x, caret_y, caret_width, self:get_line_height(), color)
  end
end

local function native_whitespace_option(conf, substitution, option)
  if substitution[option] ~= nil then return substitution[option] end
  return conf[option]
end

function NativeEditorView:get_whitespace_markers(line)
  local conf = core.draw_whitespace
  if not (type(conf) == "table" and conf.enabled) then return {} end
  if conf.show_selected_only then return {} end

  local text = self:get_line_text(line)
  local substitutions = conf.substitutions or {}
  local markers = {}
  for _, substitution in ipairs(substitutions) do
    local char = substitution.char
    if char and char ~= "" then
      local offset = 1
      while offset <= #text do
        local start_col = text:find(char, offset, true)
        if not start_col then break end
        local end_col = start_col
        while text:sub(end_col + 1, end_col + #char) == char do
          end_col = end_col + #char
        end
        local run_len = math.floor((end_col - start_col + 1) / #char)
        local leading = start_col == 1
        local trailing = end_col == #text
        local draw = false
        local color = native_whitespace_option(conf, substitution, "color") or style.whitespace
        if trailing then
          draw = native_whitespace_option(conf, substitution, "show_trailing")
          color = native_whitespace_option(conf, substitution, "trailing_color") or color
        elseif leading then
          draw = native_whitespace_option(conf, substitution, "show_leading")
          color = native_whitespace_option(conf, substitution, "leading_color") or color
        else
          draw = native_whitespace_option(conf, substitution, "show_middle")
            and run_len >= (native_whitespace_option(conf, substitution, "show_middle_min") or 1)
          color = native_whitespace_option(conf, substitution, "middle_color") or color
        end
        if draw then
          for col = start_col - 1, end_col - 1, #char do
            markers[#markers + 1] = {
              col = col,
              text = substitution.sub or char,
              color = color,
              kind = char == "\t" and "tab" or "space",
            }
          end
        end
        offset = end_col + 1
      end
    end
  end
  return markers
end

function NativeEditorView:draw_whitespace_markers(line, x, y)
  local markers = self:get_whitespace_markers(line)
  if #markers == 0 then return end
  local font = self:get_font()
  for _, marker in ipairs(markers) do
    local mx = x + self:get_col_x_offset(line + 1, marker.col + 1)
    renderer.draw_text(font, marker.text, mx, y, marker.color)
  end
end

function NativeEditorView:get_selection_highlight_rects(line, row_y)
  local cursor = self.editor:cursor()
  if not self:cursor_has_selection(cursor) then return {} end
  local first = math.min(cursor.cursor, cursor.selection)
  local last = math.max(cursor.cursor, cursor.selection)
  local first_lc = self.buffer:offset_to_line_col(first)
  local last_lc = self.buffer:offset_to_line_col(last)
  if not first_lc or not last_lc or first_lc.line ~= last_lc.line then return {} end

  local selected_text = self:get_line_text(first_lc.line):sub(first_lc.col + 1, last_lc.col)
  if #selected_text <= 1 or selected_text:match("^%s+$") then return {} end

  local current_text = self:get_line_text(line)
  local search_text = selected_text:lower()
  local search_line = current_text:lower()
  local rects = {}
  local offset = 1
  while true do
    local start_col, end_col = search_line:find(search_text, offset, true)
    if not start_col then break end
    local zero_start = start_col - 1
    local zero_end = end_col
    if line ~= first_lc.line or zero_start ~= first_lc.col then
      local x1, y = self:line_col_to_screen(line, zero_start)
      local x2 = self:line_col_to_screen(line, zero_end)
      rects[#rects + 1] = {
        x = x1,
        y = row_y or y,
        w = x2 - x1,
        h = self:get_line_height(),
        color = style.selectionhighlight,
      }
    end
    offset = end_col + 1
  end
  return rects
end

function NativeEditorView:draw_selection_highlights(line, row_y)
  for _, rect in ipairs(self:get_selection_highlight_rects(line, row_y)) do
    renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, rect.color)
  end
end

function NativeEditorView:decoration_color(decoration, fallback)
  local key = decoration and decoration.style
  if key and style[key] then return style[key] end
  if key and style.syntax and style.syntax[key] then return style.syntax[key] end
  return fallback or style.accent
end

function NativeEditorView:get_range_decoration_rects(line_info, decoration, row_y)
  if not (line_info and decoration and decoration.kind == "range") then return {} end
  local line = line_info.line or 0
  local line_start = line_info.start_offset or 0
  local text = (line_info.text or ""):gsub("\r?\n$", "")
  local text_end = line_start + #text
  local line_end = line_info.end_offset or text_end
  if decoration.end_offset <= line_start or decoration.start_offset >= line_end then return {} end

  local first = math.max(decoration.start_offset or 0, line_start)
  local last = math.min(decoration.end_offset or 0, text_end)
  local start_col = common.clamp(first - line_start, 0, #text)
  local end_col = common.clamp(last - line_start, start_col, #text)
  local x1, y = self:line_col_to_screen(line, start_col)
  local x2 = self:line_col_to_screen(line, end_col)
  if (decoration.end_offset or 0) > text_end and (decoration.start_offset or 0) <= text_end then
    x2 = x2 + self:get_font():get_width(" ")
  end
  if x2 <= x1 then x2 = x1 + math.max(1, SCALE) end
  return {{
    x = x1,
    y = row_y or y,
    w = x2 - x1,
    h = self:get_line_height(),
    color = self:decoration_color(decoration, style.search_selection or style.selectionhighlight),
    decoration = decoration,
  }}
end

function NativeEditorView:draw_range_decoration_rect(rect, plane)
  local color = rect.color
  if plane == "outline" then
    local t = math.max(1, math.ceil(SCALE))
    renderer.draw_rect(rect.x - t, rect.y - t, rect.w + t, t, color)
    renderer.draw_rect(rect.x, rect.y + rect.h - t, rect.w, t, color)
    renderer.draw_rect(rect.x - t, rect.y, t, rect.h, color)
    renderer.draw_rect(rect.x + rect.w - t, rect.y, t, rect.h, color)
  elseif plane == "underline" then
    local t = math.max(1, math.ceil(SCALE))
    renderer.draw_rect(rect.x, rect.y + rect.h - t, rect.w, t, color)
  else
    renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, color)
  end
end

function NativeEditorView:draw_range_decorations(line_info, row_y, decorations, plane)
  if not decorations then return end
  for _, decoration in ipairs(decorations) do
    if decoration.kind == "range" and decoration.plane == plane then
      for _, rect in ipairs(self:get_range_decoration_rects(line_info, decoration, row_y)) do
        self:draw_range_decoration_rect(rect, plane)
      end
    end
  end
end

local native_bracket_pairs = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local native_bracket_closers = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

function NativeEditorView:find_matching_bracket_in_text(text, offset, open_ch, close_ch, direction, line_limit)
  local anchor_lc = self.buffer:offset_to_line_col(offset)
  local depth = 0
  if direction > 0 then
    for i = offset + 1, #text do
      local lc = self.buffer:offset_to_line_col(i - 1)
      if anchor_lc and lc and math.abs(lc.line - anchor_lc.line) > line_limit then break end
      local ch = text:sub(i, i)
      if ch == open_ch then
        depth = depth + 1
      elseif ch == close_ch then
        depth = depth - 1
        if depth == 0 then return i - 1 end
      end
    end
  else
    for i = offset + 1, 1, -1 do
      local lc = self.buffer:offset_to_line_col(i - 1)
      if anchor_lc and lc and math.abs(lc.line - anchor_lc.line) > line_limit then break end
      local ch = text:sub(i, i)
      if ch == close_ch then
        depth = depth + 1
      elseif ch == open_ch then
        depth = depth - 1
        if depth == 0 then return i - 1 end
      end
    end
  end
end

function NativeEditorView:compute_bracket_match_state()
  local cursor = self.editor:cursor().cursor or 0
  local text = self.buffer:text()
  local line_limit = 3000
  for _, offset in ipairs { cursor, cursor > 0 and cursor - 1 or nil } do
    if offset and offset >= 0 and offset < #text then
      local ch = text:sub(offset + 1, offset + 1)
      local close = native_bracket_pairs[ch]
      if close then
        local match = self:find_matching_bracket_in_text(text, offset, ch, close, 1, line_limit)
        if match then return { anchor = offset, match = match } end
      end
      local open = native_bracket_closers[ch]
      if open then
        local match = self:find_matching_bracket_in_text(text, offset, open, ch, -1, line_limit)
        if match then return { anchor = offset, match = match } end
      end
    end
  end
end

local native_line_comment_tokens = {
  c = "//", h = "//", cc = "//", cpp = "//", cxx = "//", hpp = "//", hh = "//", hxx = "//",
  js = "//", jsx = "//", ts = "//", tsx = "//", java = "//", cs = "//", go = "//", rs = "//",
  lua = "--", py = "#", rb = "#", sh = "#", bash = "#", zsh = "#", ps1 = "#", toml = "#", yaml = "#", yml = "#",
}

function NativeEditorView:line_comment_token()
  local path = self.buffer:path()
  local ext = path and path:match("%.([^%.%/\\]+)$")
  return ext and native_line_comment_tokens[ext:lower()] or nil
end

function NativeEditorView:selected_line_ranges()
  local ranges = {}
  for i = 1, self.editor:cursor_count() do
    local cursor = self.editor:cursor(i)
    local first = math.min(cursor.cursor or 0, cursor.selection or cursor.cursor or 0)
    local last = math.max(cursor.cursor or 0, cursor.selection or cursor.cursor or 0)
    local first_lc = self.buffer:offset_to_line_col(first)
    local last_lc = self.buffer:offset_to_line_col(last)
    if first_lc and last_lc then
      local last_line = last_lc.line
      if last > first and last_lc.col == 0 and last_line > first_lc.line then
        last_line = last_line - 1
      end
      ranges[#ranges + 1] = { first = first_lc.line, last = last_line }
    end
  end
  return ranges
end

function NativeEditorView:toggle_line_comments()
  local token = self:line_comment_token()
  if not token then
    core.error("No native line comment token for this file type")
    return false
  end

  local lines = {}
  local seen = {}
  for _, range in ipairs(self:selected_line_ranges()) do
    for line = range.first, range.last do
      if not seen[line] then
        seen[line] = true
        lines[#lines + 1] = line
      end
    end
  end
  table.sort(lines)
  if #lines == 0 then return false end

  local line_infos = {}
  local uncomment = true
  local token_with_space = token .. " "
  for _, line in ipairs(lines) do
    local text = self:get_line_text(line)
    local first_nonspace = text:find("%S")
    if first_nonspace then
      local has_comment = text:sub(first_nonspace, first_nonspace + #token_with_space - 1) == token_with_space
      line_infos[#line_infos + 1] = { line = line, col = first_nonspace - 1, text = text, commented = has_comment }
      if not has_comment then uncomment = false end
    end
  end
  if #line_infos == 0 then return false end

  self.editor:clear_multi_cursors()
  if uncomment then
    for i, info in ipairs(line_infos) do
      local start_offset = self.buffer:line_col_to_offset(info.line, info.col)
      local end_offset = self.buffer:line_col_to_offset(info.line, info.col + #token_with_space)
      if start_offset and end_offset then
        if i == 1 then self.editor:set_cursor(end_offset, start_offset) else self.editor:add_cursor(end_offset, start_offset) end
      end
    end
    self.editor:paste("")
  else
    for i, info in ipairs(line_infos) do
      local offset = self.buffer:line_col_to_offset(info.line, info.col)
      if offset then
        if i == 1 then self.editor:set_cursor(offset) else self.editor:add_cursor(offset) end
      end
    end
    self.editor:paste(token_with_space)
  end
  return true
end

function NativeEditorView:move_to_matching_bracket(select_match)
  local state = self:compute_bracket_match_state()
  if not state then return false end
  if select_match then
    if state.match > state.anchor then
      self.editor:set_cursor(state.match + 1, state.anchor)
    else
      self.editor:set_cursor(state.match, state.anchor + 1)
    end
  else
    self.editor:set_cursor(state.match)
  end
  self.bracket_match_state = state
  self:scroll_to_cursor()
  core.redraw = true
  return true
end

function NativeEditorView:get_bracket_match_rects(line)
  local state = self.bracket_match_state or self:compute_bracket_match_state()
  if not state then return {} end
  local rects = {}
  local thickness = math.ceil(SCALE)
  for _, offset in ipairs { state.anchor, state.match } do
    local lc = self.buffer:offset_to_line_col(offset)
    if lc and lc.line == line then
      local x1, y = self:line_col_to_screen(lc.line, lc.col)
      local x2 = self:line_col_to_screen(lc.line, lc.col + 1)
      rects[#rects + 1] = {
        x = x1,
        y = y,
        w = math.max(1, x2 - x1),
        h = self:get_line_height(),
        thickness = thickness,
        color = style.bracketmatch_frame_color or style.bracketmatch_color or style.accent,
        offset = offset,
      }
    end
  end
  return rects
end

function NativeEditorView:draw_bracket_matches(line)
  for _, rect in ipairs(self:get_bracket_match_rects(line)) do
    local t = rect.thickness
    local color = rect.color
    renderer.draw_rect(rect.x - t, rect.y - t, rect.w + t, t, color)
    renderer.draw_rect(rect.x, rect.y + rect.h - t, rect.w, t, color)
    renderer.draw_rect(rect.x - t, rect.y, t, rect.h, color)
    renderer.draw_rect(rect.x + rect.w - t, rect.y, t, rect.h, color)
  end
end

function NativeEditorView:draw_line_text(line_info, row_y, highlights, decorations)
  local text = (line_info.text or ""):gsub("\r?\n$", "")
  local body_y = row_y
  row_y = row_y + self:get_line_text_y_offset()
  local x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x
  local width = self:get_gutter_width() + style.padding.x * 2 + self:get_font():get_width(text)
  local line = line_info.line or 0
  if width > (self.h_scrollable_size or 0) then self.h_scrollable_size = width end
  self:draw_indent_guides(line, body_y)
  self:draw_selection_highlights(line, body_y)
  self:draw_whitespace_markers(line, x, row_y)
  if not highlights or #highlights == 0 then
    renderer.draw_text(self:get_font(), text, x, row_y, style.text)
    self:draw_range_decorations(line_info, body_y, decorations, "underline")
    self:draw_range_decorations(line_info, body_y, decorations, "outline")
    self:draw_bracket_matches(line)
    return
  end

  local line_start = line_info.start_offset or 0
  local line_end = line_info.end_offset or (line_start + #text)
  local spans = {}
  for _, span in ipairs(highlights) do
    if span.end_offset > line_start and span.start_offset < line_end then
      spans[#spans + 1] = span
    end
  end
  local col = 0
  local function draw_segment(first_col, last_col, color)
    if last_col <= first_col then return end
    local segment = text:sub(first_col + 1, last_col)
    local sx = x + self:get_font():get_width(text:sub(1, first_col))
    renderer.draw_text(self:get_font(), segment, sx, row_y, color)
  end

  for _, span in ipairs(spans) do
    local start_col = math.max(0, span.start_offset - line_start)
    local end_col = math.min(#text, span.end_offset - line_start)
    if end_col > col then
      draw_segment(col, start_col, style.text)
      local capture = span.style or (span.capture and span.capture:match("^[^%.]+")) or "normal"
      draw_segment(math.max(col, start_col), end_col, style.syntax[capture] or style.text)
      col = end_col
    end
  end
  draw_segment(col, #text, style.text)
  self:draw_range_decorations(line_info, body_y, decorations, "underline")
  self:draw_range_decorations(line_info, body_y, decorations, "outline")
  self:draw_bracket_matches(line)
end

function NativeEditorView:cursor_has_selection(cursor)
  return cursor.selection and cursor.selection ~= cursor.cursor
end

function NativeEditorView:has_selection()
  for i = 1, self.editor:cursor_count() do
    if self:cursor_has_selection(self.editor:cursor(i)) then return true end
  end
  return false
end

function NativeEditorView:update_primary_selection()
  if not (system.set_primary_selection and self:has_selection()) then return end
  local text = self.editor:copy_selection()
  if text and text ~= "" then system.set_primary_selection(text) end
end

function NativeEditorView:line_has_cursor_or_selection(line)
  for i = 1, self.editor:cursor_count() do
    local cursor = self.editor:cursor(i)
    local cursor_line = self:cursor_line_col(cursor.cursor or 0)
    if cursor_line == line then return true end
    if self:cursor_has_selection(cursor) then
      local first = math.min(cursor.cursor, cursor.selection)
      local last = math.max(cursor.cursor, cursor.selection)
      local first_lc = self.buffer:offset_to_line_col(first)
      local last_lc = self.buffer:offset_to_line_col(last)
      if first_lc and last_lc and line >= first_lc.line and line <= last_lc.line then return true end
    end
  end
  return false
end

function NativeEditorView:draw_content_left_edge()
  local edge_w = math.max(1, math.floor(SCALE))
  local edge_padding = style.padding.x * 0.25
  local x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x - edge_padding - edge_w
  renderer.draw_rect(x, self.position.y, edge_w, self.size.y, style.docview_content_left_edge or style.whitespace or style.divider)
end

function NativeEditorView:get_line_highlight_rect(x, y)
  return self.position.x, y, self.size.x, self:get_line_height()
end

function NativeEditorView:draw_line_highlight(x, y)
  local rx, ry, rw, rh = self:get_line_highlight_rect(x, y)
  renderer.draw_rect(rx, ry, rw, rh, style.line_highlight)
end

function NativeEditorView:get_column_guide_rects()
  local rects = {}
  local text_x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x
  local char_w = self:get_font():get_width("n")

  local column_guides = config.plugins.column_guides
  if type(column_guides) == "table" and column_guides.enabled ~= false and type(column_guides.columns) == "table" then
    local width = math.max(1, math.floor(SCALE))
    for _, column in ipairs(column_guides.columns) do
      column = tonumber(column)
      if column and column > 0 then
        rects[#rects + 1] = {
          x = text_x + char_w * math.floor(column) - math.floor(width / 2),
          y = self.position.y,
          w = width,
          h = self.size.y,
          color = style.whitespace,
          kind = "column-guide",
        }
      end
    end
  end

  local lineguide = config.plugins.lineguide
  if type(lineguide) == "table" and lineguide.enabled and type(lineguide.rulers) == "table" then
    local width = lineguide.width or 1
    local color = lineguide.use_custom_color and lineguide.custom_color or style.guide
    for _, ruler in ipairs(lineguide.rulers) do
      local columns = type(ruler) == "table" and ruler.columns or ruler
      columns = tonumber(columns)
      if columns and columns > 0 then
        rects[#rects + 1] = {
          x = text_x + char_w * columns,
          y = self.position.y,
          w = width,
          h = self.size.y,
          color = type(ruler) == "table" and ruler.color or color,
          kind = "lineguide",
        }
      end
    end
  end

  return rects
end

function NativeEditorView:draw_column_guides()
  local rects = self:get_column_guide_rects()
  if #rects == 0 then return end
  local gutter_w = self:get_gutter_width()
  core.push_clip_rect(self.position.x + gutter_w, self.position.y, self.size.x - gutter_w, self.size.y)
  for _, rect in ipairs(rects) do
    renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, rect.color)
  end
  core.pop_clip_rect()
end

local function native_leading_indent_cols(view, line, indent_size)
  local text = view:get_line_text(line)
  local whitespace = text:match("^[ \t]*") or ""
  local is_blank = text:find("%S") == nil
  local cols = 0
  for i = 1, #whitespace do
    local ch = whitespace:sub(i, i)
    if ch == "\t" then
      cols = cols + (indent_size - (cols % indent_size))
    else
      cols = cols + 1
    end
  end
  return cols, is_blank
end

local function native_nonblank_indent_in_direction(view, line, indent_size, direction, limit)
  local stop = direction < 0 and math.max(0, line - limit) or math.min(view.buffer:line_count() - 1, line + limit)
  local i = line + direction
  while direction < 0 and i >= stop or direction > 0 and i <= stop do
    local cols, blank = native_leading_indent_cols(view, i, indent_size)
    if not blank then return cols, i end
    i = i + direction
  end
end

local function native_effective_indent_cols(view, line, indent_size, limit)
  local cols, blank = native_leading_indent_cols(view, line, indent_size)
  if not blank then return cols end
  local prev = native_nonblank_indent_in_direction(view, line, indent_size, -1, limit)
  local nexti = native_nonblank_indent_in_direction(view, line, indent_size, 1, limit)
  return (prev and nexti) and math.max(prev, nexti) or (prev or nexti or 0)
end

local function native_is_closing_block_line(text)
  return text and text:match("^%s*[%]%)}][,;]?%s*$") ~= nil
end

function NativeEditorView:active_indent_depth(indent_size, limit)
  local line = self:cursor_line_col()
  line = common.clamp(line or 0, 0, math.max(0, self.buffer:line_count() - 1))
  local cols, blank = native_leading_indent_cols(self, line, indent_size)
  local text = self:get_line_text(line)

  if blank then
    local prev = native_nonblank_indent_in_direction(self, line, indent_size, -1, limit)
    local nexti = native_nonblank_indent_in_direction(self, line, indent_size, 1, limit)
    cols = math.max(prev or 0, nexti or 0)
  elseif native_is_closing_block_line(text) then
    local prev = native_nonblank_indent_in_direction(self, line, indent_size, -1, limit)
    if prev and prev > cols then cols = prev end
  else
    local nexti = native_nonblank_indent_in_direction(self, line, indent_size, 1, 1)
    if nexti and nexti > cols then cols = nexti end
  end

  local depth = math.floor(cols / indent_size) - 1
  return depth >= 0 and depth or nil
end

function NativeEditorView:get_indent_guide_rects(line, row_y)
  local conf = core.indent_guides
  if not (type(conf) == "table" and conf.enabled) then return {} end
  local _, indent_size = self:get_indent_info()
  indent_size = indent_size or config.indent_size or 2
  local limit = conf.blank_line_search_limit or 25
  local indent_cols = native_effective_indent_cols(self, line, indent_size, limit)
  local indent_levels = math.floor(indent_cols / indent_size)
  local active_depth = conf.highlight_active and self:active_indent_depth(indent_size, limit) or nil
  local normal_color = style.indent_guide
  local active_color = conf.highlight_active and style.indent_guide_active or normal_color
  local indent_px = self:get_font():get_width(string.rep(" ", indent_size))
  local x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x
  local rects = {}
  for depth = 1, indent_levels - 1 do
    rects[#rects + 1] = {
      x = x + depth * indent_px,
      y = row_y,
      w = conf.line_width or math.max(1, SCALE),
      h = self:get_line_height(),
      color = depth == active_depth and active_color or normal_color,
      depth = depth,
    }
  end
  return rects
end

function NativeEditorView:draw_indent_guides(line, row_y)
  for _, rect in ipairs(self:get_indent_guide_rects(line, row_y)) do
    renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, rect.color)
  end
end

function NativeEditorView:draw_current_line_highlights()
  if core.active_view == self and config.highlight_current_line ~= false then
    if config.highlight_current_line ~= "no_selection" or not self:has_selection() then
      local lh = self:get_line_height()
      local seen = {}
      for i = 1, self.editor:cursor_count() do
        local line = self:cursor_line_col(self.editor:cursor(i).cursor or 0)
        if not seen[line] then
          local y = self.position.y + style.padding.y - self.scroll.y + line * lh
          self:draw_line_highlight(self.position.x, y)
          seen[line] = true
        end
      end
      self:draw_content_left_edge()
    end
  end
  self:draw_column_guides()
end

function NativeEditorView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  if config.show_line_numbers then
    local line_index = math.max(0, (line or 1) - 1)
    local color = self:line_has_cursor_or_selection(line_index) and (style.line_number2 or style.line_number) or style.line_number
    common.draw_text(self:get_font(), color, tostring(line), "right", x + style.padding.x, y + self:get_line_text_y_offset(), width - style.padding.x * 2, lh)
  end
  return lh
end

function NativeEditorView:ime_composition_offsets(cursor)
  cursor = cursor or self.editor:cursor()
  local cursor_offset = cursor.cursor or 0
  local selection_offset = cursor.selection or cursor_offset
  return math.min(cursor_offset, selection_offset), math.max(cursor_offset, selection_offset)
end

function NativeEditorView:update_ime_location()
  if core.active_view ~= self then return end
  local first, last = self:ime_composition_offsets()
  local focus_first, focus_last = first, last
  if self.ime_status and (self.ime_selection.size or 0) > 0 then
    focus_first = first + (self.ime_selection.from or 0)
    focus_last = focus_first + (self.ime_selection.size or 0)
  end
  focus_first = common.clamp(focus_first, 0, self.buffer:len())
  focus_last = common.clamp(focus_last, 0, self.buffer:len())
  local start_lc = self.buffer:offset_to_line_col(focus_first)
  local end_lc = self.buffer:offset_to_line_col(focus_last)
  if not start_lc or not end_lc then return end
  local x1, y = self:line_col_to_screen(start_lc.line, start_lc.col)
  local x2 = self:line_col_to_screen(end_lc.line, end_lc.col)
  ime.set_location(x1, y, math.max(1, math.abs(x2 - x1)), self:get_line_height())
end

function NativeEditorView:draw_ime_decoration(cursor)
  if not self.ime_status then return false end
  local first, last = self:ime_composition_offsets(cursor)
  local start_lc = self.buffer:offset_to_line_col(first)
  local end_lc = self.buffer:offset_to_line_col(last)
  if not start_lc or not end_lc then return false end

  local line_size = math.max(1, SCALE)
  local lh = self:get_line_height()
  local x1, y = self:line_col_to_screen(start_lc.line, start_lc.col)
  local x2 = self:line_col_to_screen(end_lc.line, end_lc.col)
  renderer.draw_rect(math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.text)

  local caret_offset = common.clamp(first + (self.ime_selection.from or 0), 0, self.buffer:len())
  local caret_lc = self.buffer:offset_to_line_col(caret_offset)
  if caret_lc then
    local caret_x, caret_y = self:line_col_to_screen(caret_lc.line, caret_lc.col)
    local to_offset = common.clamp(caret_offset + (self.ime_selection.size or 0), 0, self.buffer:len())
    if to_offset ~= caret_offset then
      local to_lc = self.buffer:offset_to_line_col(to_offset)
      if to_lc then
        local to_x = self:line_col_to_screen(to_lc.line, to_lc.col)
        renderer.draw_rect(math.min(caret_x, to_x), caret_y + lh - (style.caret_width or line_size), math.abs(to_x - caret_x), style.caret_width or line_size, style.caret)
      end
    end
    renderer.draw_rect(caret_x, caret_y, style.caret_width or line_size, lh, style.caret)
  end
  return true
end

function NativeEditorView:draw_overlay()
  if core.active_view == self and self.ime_status then
    self:draw_ime_decoration(self.editor:cursor())
    return
  end
  for i = 1, self.editor:cursor_count() do
    self:draw_caret_for_cursor(self.editor:cursor(i), i)
  end
end

function NativeEditorView:draw_selection_for_cursor(cursor)
  if not self:cursor_has_selection(cursor) then return end
  local first = math.min(cursor.cursor, cursor.selection)
  local last = math.max(cursor.cursor, cursor.selection)
  local start_lc = self.buffer:offset_to_line_col(first)
  local end_lc = self.buffer:offset_to_line_col(last)
  if not start_lc or not end_lc then return end

  local lh = self:get_line_height()
  for line = start_lc.line, end_lc.line do
    local line_text = self:get_line_text(line)
    local start_col = line == start_lc.line and start_lc.col or 0
    local end_col = line == end_lc.line and end_lc.col or #line_text
    start_col = common.clamp(start_col, 0, #line_text)
    end_col = common.clamp(end_col, 0, #line_text)
    if end_col >= start_col then
      local x1, y1 = self:line_col_to_screen(line, start_col)
      local x2 = self:line_col_to_screen(line, end_col)
      local raw_line_text = self.buffer:line(line) or ""
      if end_col >= #line_text and raw_line_text:find("\n$") then
        x2 = x2 + self:get_font():get_width(" ")
      end
      if x2 == x1 then x2 = x1 + math.max(1, SCALE) end
      renderer.draw_rect(x1, y1, x2 - x1, lh, style.selection)
    end
  end
end

function NativeEditorView:scroll_to_make_visible(line, col, instant, opts)
  opts = opts or {}
  line = math.max(1, line or 1) - 1
  col = math.max(1, col or 1) - 1
  local lh = self:get_line_height()
  local y = line * lh
  if opts.vertical ~= false then
    local pad = self.mouse_selecting and math.min(self:get_visible_scroll_context_lines(), 1) or self:get_visible_scroll_context_lines()
    local below_pad = pad
    if config.scroll_past_end and not self.mouse_selecting then
      below_pad = math.max(below_pad, self:get_scroll_past_end_context_lines())
    end
    local above = math.max(0, y - style.padding.y - lh * pad)
    local below = y - self.size.y + self:get_horizontal_scrollbar_height() + lh * (below_pad + 1)
    self.scroll.to.y = math.max(0, common.clamp(self.scroll.to.y, below, above))
  end

  if opts.horizontal ~= false then
    local gutter_w = self:get_gutter_width()
    local available_w = math.max(1, self.size.x - gutter_w - style.padding.x * 2)
    local text = self:get_line_text(line)
    local x = self:get_font():get_width(text:sub(1, common.clamp(col, 0, #text)))
    local x2 = opts.x2 or x
    self.h_scrollable_size = math.max(self.h_scrollable_size or 0, gutter_w + style.padding.x * 2 + math.max(x, x2) + self:get_font():get_width(" "))
    if x < self.scroll.to.x then
      self.scroll.to.x = x
    elseif x2 > self.scroll.to.x + available_w then
      self.scroll.to.x = x2 - available_w + self:get_font():get_width(" ")
    end
  end
  self:clamp_scroll_position()
  if instant then
    self.scroll.x = self.scroll.to.x
    self.scroll.y = self.scroll.to.y
  end
end

function NativeEditorView:scroll_to_line(line, ignore_if_visible, instant)
  line = math.max(1, line or 1)
  local minline, maxline = self:get_visible_line_range()
  if ignore_if_visible and line >= minline and line <= maxline then return end
  local lh = self:get_line_height()
  self.scroll.to.y = math.max(0, (line - 1) * lh - (self.size.y - self:get_horizontal_scrollbar_height()) / 2)
  self:clamp_scroll_position()
  if instant then self.scroll.y = self.scroll.to.y end
end

function NativeEditorView:scroll_to_cursor()
  local line, col = self:cursor_line_col()
  self:scroll_to_make_visible(line + 1, col + 1)
end

function NativeEditorView:page_move(direction, update_selection)
  local lines = math.max(1, math.floor(self.size.y / self:get_line_height()) - 1)
  local move = direction < 0 and self.editor.line_up or self.editor.line_down
  for _ = 1, lines do move(self.editor, update_selection) end
end

function NativeEditorView:line_bounds(line)
  line = common.clamp(line or 0, 0, math.max(0, self.buffer:line_count() - 1))
  local start_offset = self.buffer:line_col_to_offset(line, 0) or 0
  local next_offset = self.buffer:line_col_to_offset(line + 1, 0)
  local end_offset = next_offset or (start_offset + #self:get_line_text(line))
  return start_offset, end_offset
end

local function native_word_char(char)
  if not char or char == "" then return false end
  local non_word = config.non_word_chars or " \t\n/\\()\"':,.;<>~!@#$%^&*|+=[]{}`?-"
  return not non_word:find(char, 1, true)
end

function NativeEditorView:word_bounds_at_offset(offset)
  local lc = self.buffer:offset_to_line_col(offset or 0)
  if not lc then return offset or 0, offset or 0 end
  local text = self:get_line_text(lc.line)
  local col = common.clamp(lc.col or 0, 0, #text)
  if col == #text and col > 0 then col = col - 1 end
  local char = text:sub(col + 1, col + 1)
  if not native_word_char(char) then
    return self.buffer:line_col_to_offset(lc.line, lc.col) or offset, self.buffer:line_col_to_offset(lc.line, lc.col) or offset
  end
  local start_col = col
  while start_col > 0 and native_word_char(text:sub(start_col, start_col)) do
    start_col = start_col - 1
  end
  local end_col = col + 1
  while end_col < #text and native_word_char(text:sub(end_col + 1, end_col + 1)) do
    end_col = end_col + 1
  end
  return self.buffer:line_col_to_offset(lc.line, start_col) or offset,
         self.buffer:line_col_to_offset(lc.line, end_col) or offset
end

function NativeEditorView:selection_bounds_for_mouse(anchor, offset, snap_type)
  if snap_type == "word" then
    local a1, a2 = self:word_bounds_at_offset(anchor)
    local b1, b2 = self:word_bounds_at_offset(offset)
    if offset < anchor then return b1, a2 end
    return a1, b2
  elseif snap_type == "lines" then
    local anchor_lc = self.buffer:offset_to_line_col(anchor)
    local offset_lc = self.buffer:offset_to_line_col(offset)
    local line1 = math.min(anchor_lc and anchor_lc.line or 0, offset_lc and offset_lc.line or 0)
    local line2 = math.max(anchor_lc and anchor_lc.line or 0, offset_lc and offset_lc.line or 0)
    local first = self:line_bounds(line1)
    local _, last = self:line_bounds(line2)
    return first, last
  end
  return anchor, offset
end

function NativeEditorView:set_mouse_selection(anchor, offset, snap_type)
  local first, last = self:selection_bounds_for_mouse(anchor, offset, snap_type)
  if offset < anchor then
    self.editor:set_cursor(first, last)
  else
    self.editor:set_cursor(last, first)
  end
  self:update_primary_selection()
end

function NativeEditorView:on_ime_text_editing(text, start, length)
  text = text or ""
  start = math.max(0, start or 0)
  length = math.max(0, length or 0)
  local overwrite = self.editor.overwrite_mode and self.editor:overwrite_mode()
  if overwrite then self.editor:set_overwrite_mode(false) end
  self.editor:paste(text)
  if overwrite then self.editor:set_overwrite_mode(true) end
  local cursor = self.editor:cursor()
  local cursor_offset = cursor.cursor or 0
  local composition_start = common.clamp(cursor_offset - #text, 0, self.buffer:len())
  self.ime_status = text ~= ""
  self.ime_selection.from = start
  self.ime_selection.size = length
  if self.ime_status then
    self.editor:set_cursor(cursor_offset, composition_start)
  else
    self.editor:set_cursor(composition_start)
  end
  self:note_tree_sitter_mutation()
  self:update_ime_location()
  local line, col = self:cursor_line_col(composition_start)
  self:scroll_to_make_visible(line + 1, col + start + 1)
  core.redraw = true
  return true
end

function NativeEditorView:on_text_input(text)
  if text and text ~= "" then
    self.ime_status = false
    self.ime_selection.from = 0
    self.ime_selection.size = 0
    self.editor:insert(text)
    self:note_tree_sitter_mutation()
    if core.record_native_edit_location then core.record_native_edit_location(self) end
    self:scroll_to_cursor()
    core.redraw = true
  end
  return true
end

function NativeEditorView:on_mouse_pressed(button, x, y, clicks)
  return self:with_centered_editor_geometry(function(button, x, y, clicks)
  if NativeEditorView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" and button ~= "middle" then return false end

  local line, col = self:screen_to_line_col(x, y)
  local offset = self.buffer:line_col_to_offset(line, col)
  if not offset then return true end

  if button == "middle" then
    self.editor:set_cursor(offset)
    local text = system.get_primary_selection and system.get_primary_selection() or ""
    if text and text ~= "" then
      self.editor:paste(text)
      self:note_tree_sitter_mutation()
      if core.record_native_edit_location then core.record_native_edit_location(self) end
      self:scroll_to_cursor()
    end
    self.mouse_selecting = nil
    core.redraw = true
    return true
  end

  local gutter_w = self:get_gutter_width()
  local in_gutter = x >= self.position.x and x <= self.position.x + gutter_w
  if in_gutter then
    local line_start, line_end = self:line_bounds(line)
    if keymap.modkeys["shift"] then
      local cursor = self.editor:cursor()
      local anchor = cursor.selection or cursor.cursor or line_start
      self:set_mouse_selection(anchor, line_end, "lines")
      self.mouse_selecting = { anchor = anchor, snap_type = "lines" }
    elseif clicks and clicks >= 2 then
      self.editor:set_cursor(line_end, line_start)
      self:update_primary_selection()
      self.mouse_selecting = { anchor = line_start, snap_type = "lines" }
    else
      self.editor:set_cursor(line_start)
      self.mouse_selecting = { anchor = line_start, snap_type = "lines" }
    end
    core.redraw = true
    return true
  end

  local snap_type
  if clicks == 2 then snap_type = "word" elseif clicks and clicks >= 3 then snap_type = "lines" end
  if keymap.modkeys["ctrl"] and not keymap.modkeys["shift"] then
    self.editor:add_cursor(offset)
    self.mouse_selecting = { anchor = offset }
  elseif keymap.modkeys["shift"] then
    local cursor = self.editor:cursor()
    local anchor = cursor.selection or cursor.cursor or offset
    self:set_mouse_selection(anchor, offset, snap_type)
    self.mouse_selecting = { anchor = anchor, snap_type = snap_type }
  elseif snap_type then
    self:set_mouse_selection(offset, offset, snap_type)
    self.mouse_selecting = { anchor = offset, snap_type = snap_type }
  else
    self.editor:set_cursor(offset)
    self.mouse_selecting = { anchor = offset }
  end
  core.redraw = true
  return true
  end, button, x, y, clicks)
end

function NativeEditorView:on_mouse_moved(x, y, ...)
  local args = { ... }
  return self:with_centered_editor_geometry(function(x, y)
  NativeEditorView.super.on_mouse_moved(self, x, y, table.unpack(args))
  local gutter_w = self:get_gutter_width()
  if self:scrollbar_hovering() or self:scrollbar_dragging()
      or (x >= self.position.x and x <= self.position.x + gutter_w) then
    self.cursor = "arrow"
  else
    self.cursor = "ibeam"
  end
  if self.mouse_selecting then
    local offset = self:screen_to_offset(x, y)
    if offset then
      self:set_mouse_selection(self.mouse_selecting.anchor, offset, self.mouse_selecting.snap_type)
      self:scroll_to_cursor()
      core.redraw = true
    end
    return true
  end
  end, x, y)
end

function NativeEditorView:on_mouse_released(button, x, y)
  NativeEditorView.super.on_mouse_released(self, button, x, y)
  if button == "left" then self.mouse_selecting = nil end
end

function NativeEditorView:on_mouse_left()
  NativeEditorView.super.on_mouse_left(self)
  if not self.mouse_selecting then self.cursor = "ibeam" end
end

function NativeEditorView:update_search_decorations(text, active_start, active_end)
  self.buffer:clear_decorations("search.results")
  self.buffer:clear_decorations("search.active")
  if not text or text == "" then return end

  local items = {}
  local options = { case_sensitive = config.find_case_sensitive == true }
  local start_offset = 0
  while start_offset <= self.buffer:len() do
    local start_match, end_match = self.buffer:find_literal(text, start_offset, options)
    if not start_match then break end
    items[#items + 1] = {
      kind = "range",
      start_offset = start_match,
      end_offset = end_match,
      plane = "background",
      style = "search_selection",
      priority = 100,
    }
    start_offset = math.max(end_match, start_match + 1)
  end
  self.buffer:set_decorations("search.results", items, { clear_on_edit = true })
  if active_start and active_end and active_end > active_start then
    self.buffer:set_decorations("search.active", {{
      kind = "range",
      start_offset = active_start,
      end_offset = active_end,
      plane = "outline",
      style = "search_selection_outline",
      priority = 200,
    }}, { clear_on_edit = true })
  end
end

function NativeEditorView:find_literal(text, backwards)
  if not text or text == "" then return false end
  local cursor = self.editor:cursor()
  local cursor_offset = cursor.cursor or 0
  local selection_offset = cursor.selection or cursor_offset
  local first = math.min(cursor_offset, selection_offset)
  local last = math.max(cursor_offset, selection_offset)
  local start_offset = backwards and math.max(0, first > 0 and first - 1 or 0) or last
  local options = { backwards = backwards, case_sensitive = config.find_case_sensitive == true }
  local start_match, end_match = self.buffer:find_literal(text, start_offset, options)
  if not start_match then
    start_offset = backwards and self.buffer:len() or 0
    start_match, end_match = self.buffer:find_literal(text, start_offset, options)
  end
  if not start_match then return false end
  self:update_search_decorations(text, start_match, end_match)
  self.editor:set_cursor(end_match, start_match)
  self:scroll_to_cursor()
  core.redraw = true
  return true
end

function NativeEditorView:draw_editor_contents()
  self:update()

  local x = self.position.x
  local y = self.position.y
  local w = self.size.x
  local h = self.size.y
  self.h_scrollable_size = self.size.x
  local lh = self:get_line_height()
  local gutter_w = self:get_gutter_width()
  local line_count = self.buffer:line_count()
  local first_line = math.max(0, math.floor(self.scroll.y / lh))
  local last_line = math.min(line_count - 1, first_line + math.ceil(h / lh) + 1)

  self.bracket_match_state = self:compute_bracket_match_state()
  local visible_lines = self.buffer:visible_lines(first_line, last_line)
  local highlights = nil
  local decorations = nil
  if #visible_lines > 0 then
    local visible_start = visible_lines[1].start_offset or 0
    local visible_end = visible_lines[#visible_lines].end_offset or self.buffer:len()
    if self.tree_sitter_enabled then
      highlights = self.buffer:tree_sitter_highlights(visible_start, visible_end)
    end
    decorations = self.buffer:decorations(visible_start, visible_end)
  end

  core.push_clip_rect(x, y, w, h)
  -- Match DocView: the whole editor uses style.background; the gutter does not
  -- get a separate scrollbar-track/background fill. Current-line highlights and
  -- line numbers draw over the shared editor background.
  self:draw_current_line_highlights()

  for _, line_info in ipairs(visible_lines) do
    local line = line_info.line
    local row_y = y + style.padding.y - self.scroll.y + line * lh
    self:draw_range_decorations(line_info, row_y, decorations, "background")
  end

  for i = 1, self.editor:cursor_count() do
    self:draw_selection_for_cursor(self.editor:cursor(i))
  end

  for _, line_info in ipairs(visible_lines) do
    local line = line_info.line
    local row_y = y + style.padding.y - self.scroll.y + line * lh
    self:draw_line_gutter(line + 1, x, row_y, gutter_w)
    self:draw_line_text(line_info, row_y, highlights, decorations)
  end

  self:draw_overlay()

  core.pop_clip_rect()
  self:draw_scrollbar()
end

function NativeEditorView:draw()
  self:draw_background(style.background)
  return self:with_centered_editor_geometry(function()
    return self:draw_editor_contents()
  end)
end

local function with_active_native_view(fn, affects_text)
  return function(view)
    view = view or core.active_view
    if is_native_editor_view(view) then
      fn(view)
      if view.has_selection and view:has_selection() then view:update_primary_selection() end
      if affects_text then
        view:note_tree_sitter_mutation()
        if core.record_native_edit_location then core.record_native_edit_location(view) end
      end
      view:scroll_to_cursor()
      core.redraw = true
    end
  end
end

local function native_line_ending_text(view)
  return view.buffer:line_ending_mode() == "crlf" and "\r\n" or "\n"
end

local function native_current_lines_text(view)
  local lines = {}
  local seen = {}
  for i = 1, view.editor:cursor_count() do
    local line = view:cursor_line_col(view.editor:cursor(i).cursor or 0)
    if not seen[line] then
      seen[line] = true
      lines[#lines + 1] = line
    end
  end
  table.sort(lines)

  local parts = {}
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  for idx, line in ipairs(lines) do
    local text = view.buffer:line(line) or ""
    text = text:gsub("\r?\n$", "")
    parts[#parts + 1] = text
    core.cursor_clipboard[idx] = text
    core.cursor_clipboard_whole_line[idx] = true
  end
  local full = table.concat(parts, native_line_ending_text(view))
  if full ~= "" then full = full .. native_line_ending_text(view) end
  core.cursor_clipboard["full"] = full
  return full
end

local function native_whole_line_clipboard_payload(text)
  if not (text and text ~= "" and core.cursor_clipboard) then return nil end
  local full = core.cursor_clipboard["full"]
  if not (full and full ~= "") then return nil end
  local found = false
  for idx, whole_line in pairs(core.cursor_clipboard_whole_line or {}) do
    if type(idx) == "number" then
      found = true
      if not whole_line then return nil end
    end
  end
  if not found then return nil end
  if full == text then return text end
  -- SDL/OS clipboard round-trips may normalize CRLF to LF in tests or on some
  -- platforms. Preserve Anvil's internal whole-line payload when the clipboard
  -- text is otherwise equivalent so CRLF Buffers keep their line-ending policy.
  if tostring(full):gsub("\r\n", "\n") == tostring(text):gsub("\r\n", "\n") then return full end
  return nil
end

local function native_newline_count(text)
  local count = 0
  for _ in tostring(text or ""):gmatch("\n") do count = count + 1 end
  return count
end

local function paste_native_whole_lines(view, text)
  local cursors = {}
  local seen_lines = {}
  for i = 1, view.editor:cursor_count() do
    local cursor = view.editor:cursor(i)
    local line, col = view:cursor_line_col(cursor.cursor or 0)
    if not seen_lines[line] then
      seen_lines[line] = true
      cursors[#cursors + 1] = { line = line, col = col }
    end
  end
  table.sort(cursors, function(a, b) return a.line < b.line end)
  if #cursors == 0 then return false end

  view.editor:clear_multi_cursors()
  for i, cursor in ipairs(cursors) do
    local offset = view.buffer:line_col_to_offset(cursor.line, 0)
    if offset then
      if i == 1 then view.editor:set_cursor(offset) else view.editor:add_cursor(offset) end
    end
  end
  view.editor:paste(text)

  local line_delta = native_newline_count(text)
  view.editor:clear_multi_cursors()
  local cumulative = 0
  for i, cursor in ipairs(cursors) do
    local target_line = cursor.line + cumulative + line_delta
    local offset = view.buffer:line_col_to_offset(target_line, cursor.col)
      or view.buffer:line_col_to_offset(target_line, 0)
      or view.buffer:len()
    if i == 1 then view.editor:set_cursor(offset) else view.editor:add_cursor(offset) end
    cumulative = cumulative + line_delta
  end
  return true
end

local function copy_native_selection(view)
  local text = view.editor:copy_selection()
  if not text or text == "" then text = native_current_lines_text(view) end
  if text and text ~= "" then system.set_clipboard(text) end
end

local function find_native_text(view, backwards)
  local selected = view.editor:copy_selection()
  core.global_prompt_bar:enter(backwards and "Native Find Previous" or "Native Find", {
    text = (selected and selected ~= "" and selected) or last_find_text or "",
    select_text = true,
    show_suggestions = false,
    submit = function(text)
      last_find_text = text
      if not view:find_literal(text, backwards) then
        core.error("Couldn't find %q", text)
      end
    end,
    suggest = function()
      return {}
    end,
  })
end

local function repeat_native_find(view, backwards)
  if not last_find_text or last_find_text == "" then
    find_native_text(view, backwards)
    return
  end
  if not view:find_literal(last_find_text, backwards) then
    core.error("Couldn't find %q", last_find_text)
  end
end

local function go_to_native_line(view)
  local current_line = view:cursor_line_col() + 1
  core.global_prompt_bar:enter("Native Go To Line", {
    text = tostring(current_line),
    select_text = true,
    show_suggestions = false,
    submit = function(text)
      local line = tonumber(text)
      if not line then return end
      line = common.clamp(math.floor(line), 1, math.max(1, view.buffer:line_count()))
      local offset = view.buffer:line_col_to_offset(line - 1, 0)
      if offset then
        view.editor:set_cursor(offset)
        view:scroll_to_cursor()
        core.redraw = true
      end
    end,
    suggest = function() return {} end,
  })
end

local function native_text_matches(a, b)
  if config.find_case_sensitive == true then return a == b end
  return tostring(a or ""):lower() == tostring(b or ""):lower()
end

local function replace_one_native_text(view)
  local selected = view.editor:copy_selection()
  core.global_prompt_bar:enter("Native Replace Text", {
    text = (selected and selected ~= "" and selected) or last_find_text or "",
    select_text = true,
    show_suggestions = false,
    submit = function(find_text)
      if not find_text or find_text == "" then return end
      core.global_prompt_bar:enter("Native Replace With", {
        text = "",
        show_suggestions = false,
        submit = function(replacement)
          replacement = replacement or ""
          local current = view.editor:copy_selection()
          if not (current and current ~= "" and native_text_matches(current, find_text)) then
            if not view:find_literal(find_text, false) then
              core.error("Couldn't find %q", find_text)
              return
            end
          end
          view.editor:paste(replacement)
          last_find_text = find_text
          view:note_tree_sitter_mutation()
          view:scroll_to_cursor()
          core.redraw = true
        end,
        suggest = function() return {} end,
      })
    end,
    suggest = function() return {} end,
  })
end

local function replace_all_native_text(view)
  local selected = view.editor:copy_selection()
  core.global_prompt_bar:enter("Native Replace All Text", {
    text = (selected and selected ~= "" and selected) or last_find_text or "",
    select_text = true,
    show_suggestions = false,
    submit = function(find_text)
      if not find_text or find_text == "" then return end
      core.global_prompt_bar:enter("Native Replace With", {
        text = "",
        show_suggestions = false,
        submit = function(replacement)
          local count = view.buffer:replace_all_literal(find_text, replacement or "", {
            case_sensitive = config.find_case_sensitive == true,
          })
          last_find_text = find_text
          if count and count > 0 then
            view:note_tree_sitter_mutation()
            view:scroll_to_cursor()
            core.log("Replaced %d occurrence%s", count, count == 1 and "" or "s")
          else
            core.error("Couldn't find %q", find_text)
          end
        end,
        suggest = function() return {} end,
      })
    end,
    suggest = function() return {} end,
  })
end

local function for_each_native_buffer_view(buffer, fn)
  local root = core.root_panel and core.root_panel.root_node
  if not root then return end
  for _, view in ipairs(root:get_children()) do
    if view:is(NativeEditorView) and view.buffer == buffer then
      fn(view)
    end
  end
end

local function update_shared_buffer_identity(buffer, identity_key)
  for_each_native_buffer_view(buffer, function(view)
    view.buffer_identity_key = identity_key
  end)
end

function core.rename_native_editor_buffer_path(old_abs, new_abs, entry_type)
  local root = core.root_panel and core.root_panel.root_node
  if not (root and old_abs and new_abs) then return 0 end
  local updated = 0
  local seen = {}
  for _, view in ipairs(root:get_children()) do
    if is_native_editor_view(view) and not seen[view.buffer] then
      local path = view.buffer:path()
      local mapped
      if path and common.path_equals(path, old_abs) then
        mapped = new_abs
      elseif entry_type == "dir" and path and common.path_belongs_to(path, old_abs) then
        mapped = new_abs .. path:sub(#old_abs + 1)
      end
      if mapped then
        seen[view.buffer] = true
        local old_key = view.buffer_identity_key or native_file_identity(path)
        local new_key = native_file_identity(mapped)
        if old_key then native_text.release_file_buffer(old_key, view.buffer) end
        if view.buffer.set_path and view.buffer:set_path(mapped) then
          if new_key then native_text.register_file_buffer(new_key, view.buffer) end
          update_shared_buffer_identity(view.buffer, new_key)
          for_each_native_buffer_view(view.buffer, function(shared_view)
            shared_view:enable_tree_sitter_for_path(mapped)
            shared_view:update_file_signature()
          end)
          updated = updated + 1
        elseif old_key then
          native_text.register_file_buffer(old_key, view.buffer)
        end
      end
    end
  end
  if updated > 0 then core.log_quiet("Updated %d native editor Buffer path(s) after rename", updated) end
  return updated
end

local function register_saved_native_buffer(view, filename)
  local old_key = view.buffer_identity_key
  local new_key = native_file_identity(filename)
  if old_key and old_key ~= new_key then
    native_text.release_file_buffer(old_key, view.buffer)
  end
  if new_key then native_text.register_file_buffer(new_key, view.buffer) end
  update_shared_buffer_identity(view.buffer, new_key)
end

local function finish_native_save(view, close_after_save, close_fn)
  for_each_native_buffer_view(view.buffer, function(shared_view)
    shared_view.native_new_file = false
    shared_view:update_file_signature()
    shared_view.external_reload_prompting = false
  end)
  view:update_file_signature()
  if close_after_save then
    if close_fn then
      close_native_view(view, close_fn)
    else
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then close_native_view(view, function() node:close_view(core.root_panel.root_node, view) end) end
    end
  end
  core.redraw = true
end

local function save_native_buffer_now(view, close_after_save, close_fn)
  local path = view.buffer:path()
  if view.buffer:save_file() then
    finish_native_save(view, close_after_save, close_fn)
    return true
  end
  core.error("Failed to save native Buffer%s", path and ": " .. path or "")
  return false
end

function save_existing_native_view(view, close_after_save, close_fn)
  local path = view.buffer:path()
  if not path then
    return save_native_view_as(view, close_after_save)
  end

  local current = file_signature(path)
  if not same_file_signature(view.file_signature, current) then
    core.log_quiet("Native Buffer save conflict detected for %s", path)
    view.external_reload_prompting = true
    local action = close_after_save and "Overwrite and close" or "Overwrite disk"
    core.nag_view:show("Native Buffer Save Conflict", path .. " changed on disk since this Buffer was loaded or saved.", {
      { text = action, default_yes = true },
      { text = "Cancel", default_no = true },
    }, function(item)
      view.external_reload_prompting = false
      if item.text == action then
        save_native_buffer_now(view, close_after_save, close_fn)
      end
    end)
    return false
  end

  return save_native_buffer_now(view, close_after_save, close_fn)
end

function core.save_native_editor_view(view, close_after_save, close_fn)
  if not is_native_editor_view(view) then return false end
  return save_existing_native_view(view, close_after_save, close_fn)
end

function save_native_view_as(view, close_after_save)
  core.save_file_dialog(core.window, function(status, result)
    if status == "accept" then
      local filename = type(result) == "table" and result[1] or result
      if filename and filename ~= "" then
        if view.buffer:save_file(filename) then
          register_saved_native_buffer(view, filename)
          for_each_native_buffer_view(view.buffer, function(shared_view)
            shared_view.native_new_file = false
            shared_view:update_file_signature()
          end)
          if close_after_save then
            local node = core.root_panel.root_node:get_node_for_view(view)
            if node then close_native_view(view, function() node:close_view(core.root_panel.root_node, view) end) end
          end
          core.redraw = true
        else
          core.error("Failed to save native Buffer as: %s", filename)
        end
      end
    elseif status == "error" then
      core.error("Error while saving native text dialog: %s", result or "")
    end
  end, { filename = view.buffer:path() })
end

local function find_open_native_text_file(filename)
  local root = core.root_panel and core.root_panel.root_node
  if not root or not filename then return nil end
  for _, view in ipairs(root:get_children()) do
    if view:is(NativeEditorView) then
      local path = view.buffer:path()
      if path and common.path_equals(path, filename) then return view end
    end
  end
end

function find_open_native_text_buffer(buffer, excluded_view)
  local root = core.root_panel and core.root_panel.root_node
  if not root or not buffer then return nil end
  for _, view in ipairs(root:get_children()) do
    if view ~= excluded_view and is_native_editor_view(view) and view.buffer == buffer then
      return view
    end
  end
end

function close_native_view(view, do_close)
  local should_release = view.buffer_identity_key and not find_open_native_text_buffer(view.buffer, view)
  local identity_key = view.buffer_identity_key
  local buffer = view.buffer
  do_close()
  if should_release then
    native_text.release_file_buffer(identity_key, buffer)
  end
end

local function open_native_text_file(filename)
  if not filename or filename == "" then return end
  local existing = find_open_native_text_file(filename)
  if existing then
    local node = core.root_panel.root_node:get_node_for_view(existing)
    if node then node:set_active_view(existing) end
    core.log_quiet("Focused already-open native Buffer: %s", filename)
    return existing
  end
  local file_info = system.get_file_info(filename)
  local buffer, identity_key, reused
  local native_new_file = false
  if file_info then
    if file_info.type ~= "file" then return end
    buffer, identity_key, reused = open_registered_native_buffer(filename)
    if not buffer then return end
  else
    buffer = native_text.new_buffer("")
    identity_key = native_file_identity(filename)
    if not buffer:set_path(filename) then return end
    if identity_key then native_text.register_file_buffer(identity_key, buffer) end
    native_new_file = true
  end
  local view = NativeEditorView(nil, filename, buffer, identity_key)
  view.native_new_file = native_new_file
  core.root_panel:get_active_node_default():add_view(view)
  if core.set_visited then core.set_visited(filename) end
  core.log_quiet("Opened native Buffer%s: %s", reused and " from registry" or (native_new_file and " for new file" or ""), filename)
  return view
end

function core.open_native_editor_file(filename)
  return open_native_text_file(filename)
end

function core.open_native_editor_scratch(text)
  local view = NativeEditorView(text or "")
  core.root_panel:get_active_node_default():add_view(view)
  core.log_quiet("Opened native scratch Buffer")
  return view
end

local core_open_file = core.__native_editor_original_open_file or core.open_file
core.__native_editor_original_open_file = core_open_file
function core.open_file(filename)
  local native_config = config.plugins.native_editor or {}
  if native_config.default_open then
    local image_view = core.open_image(filename)
    if image_view then return image_view end
    return core.open_native_editor_file(filename) or core_open_file(filename)
  end
  return core_open_file(filename)
end
if plugin_config.default_open then
  core.log_quiet("Native editor default-open experiment is enabled")
end

local function add_native_editor_legacy_aliases(map)
  for name in pairs(map) do
    local legacy_name = name:gsub("^native%-editor:", "native-text-sandbox:")
    if legacy_name ~= name then command.add_alias(legacy_name, name) end
  end
end

local native_editor_global_commands = {
  ["native-editor:open"] = function()
    core.root_panel:get_active_node_default():add_view(NativeEditorView())
  end,
  ["native-editor:open-file"] = function()
    core.open_file_dialog(core.window, function(status, result)
      if status == "accept" then
        for _, filename in ipairs(result) do core.open_file(filename) end
      elseif status == "error" then
        core.error("Error while opening native text dialog: %s", result or "")
      end
    end, { allow_many = true })
  end,
}
command.add(nil, native_editor_global_commands)
add_native_editor_legacy_aliases(native_editor_global_commands)

local function statusbar_font()
  return style.get_small_font(style.font)
end

local function plural_suffix(count)
  return count == 1 and "" or "s"
end

local function draw_reserved_status_text(text, reserved_text, x, y, h, calc_only)
  local font = statusbar_font()
  local w = font:get_width(reserved_text)
  if not calc_only and text ~= "" then
    renderer.draw_text(font, text, x, y + math.floor((h - font:get_height()) / 2), style.text)
  end
  return w
end

local function draw_reserved_count_label(count, label, reserved_label, x, y, h, calc_only)
  local font = statusbar_font()
  local number_width = font:get_width("9999")
  local w = number_width + font:get_width(reserved_label)
  if not calc_only then
    local ty = y + math.floor((h - font:get_height()) / 2)
    local number = tostring(count)
    renderer.draw_text(font, number, x + number_width - font:get_width(number), ty, style.text)
    renderer.draw_text(font, label, x + number_width, ty, style.text)
  end
  return w
end

local function native_selection_counts(view)
  local carets = view.editor:cursor_count()
  local chars = 0
  local selected_lines = 0
  local seen_lines = {}
  for i = 1, carets do
    local cursor = view.editor:cursor(i)
    if view:cursor_has_selection(cursor) then
      local first = math.min(cursor.cursor, cursor.selection)
      local last = math.max(cursor.cursor, cursor.selection)
      local first_lc = view.buffer:offset_to_line_col(first)
      local last_lc = view.buffer:offset_to_line_col(last)
      if first_lc and last_lc then
        if first_lc.line == last_lc.line then
          chars = chars + utf8_char_count_range(view:get_line_text(first_lc.line), first_lc.col, last_lc.col)
        else
          local first_line_text = view:get_line_text(first_lc.line)
          chars = chars + utf8_char_count_range(first_line_text, first_lc.col, #first_line_text)
          for line = first_lc.line + 1, last_lc.line - 1 do
            chars = chars + utf8_char_count_prefix(view:get_line_text(line))
          end
          chars = chars + utf8_char_count_prefix(view:get_line_text(last_lc.line), last_lc.col)
        end
        for line = first_lc.line, last_lc.line do
          if not seen_lines[line] then
            seen_lines[line] = true
            selected_lines = selected_lines + 1
          end
        end
      end
    end
  end
  return carets, chars, selected_lines
end

local function register_statusbar_items()
  if not core.status_bar then return end
  for _, name in ipairs { "native-text:file", "native-text:position", "native-text:line-ending" } do
    if core.status_bar:get_item(name) then core.status_bar:remove_item(name) end
  end

  if core.status_bar:get_item("native:file") then return end

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:file",
    alignment = StatusBar.Item.LEFT,
    get_item = function()
      local view = core.active_view
      local path = view.buffer:path()
      local filename
      if #core.projects > 1 and path then
        local project, is_open, belongs = core.current_project(path)
        if project and is_open and belongs then
          filename = {
            style.accent,
            common.basename(project.path),
            style.text,
            PATHSEP .. common.relative_path(project.path, path)
          }
        end
      end
      if not filename then
        filename = { path and style.text or style.dim, path and common.home_encode(path) or "Native Editor" }
      end
      return { table.unpack(filename) }
    end
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:position",
    alignment = StatusBar.Item.LEFT,
    get_item = {},
    on_draw = function(x, y, h, _, calc_only)
      local view = core.active_view
      local line, col = view:cursor_line_col()
      local line_text = view:get_line_text(line)
      line, col = line + 1, utf8_char_count_prefix(line_text, col) + 1
      local font = statusbar_font()
      local line_width = font:get_width("9999")
      local colon_width = font:get_width(":")
      local col_width = font:get_width("9999")
      local w = line_width + colon_width + col_width
      if not calc_only then
        local ty = y + math.floor((h - font:get_height()) / 2)
        local line_text = tostring(line)
        local col_text = tostring(col)
        renderer.draw_text(font, line_text, x + line_width - font:get_width(line_text), ty, style.text)
        renderer.draw_text(font, ":", x + line_width, ty, style.text)
        renderer.draw_text(font, col_text, x + line_width + colon_width, ty, col > config.line_limit and style.accent or style.text)
      end
      return w
    end,
    command = "native-editor:go-to-line",
    tooltip = "line : column"
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:carets",
    alignment = StatusBar.Item.LEFT,
    position = 3,
    get_item = {},
    on_draw = function(x, y, h, _, calc_only)
      local carets = native_selection_counts(core.active_view)
      local label = string.format(" caret%s", plural_suffix(carets))
      return draw_reserved_count_label(carets, label, " carets", x, y, h, calc_only)
    end
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:selected-chars",
    alignment = StatusBar.Item.LEFT,
    position = 4,
    get_item = {},
    on_draw = function(x, y, h, _, calc_only)
      local _, chars = native_selection_counts(core.active_view)
      if chars <= 0 then return draw_reserved_status_text("", "9999 chars selected", x, y, h, calc_only) end
      local label = string.format(" char%s selected", plural_suffix(chars))
      return draw_reserved_count_label(chars, label, " chars selected", x, y, h, calc_only)
    end
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:selected-lines",
    alignment = StatusBar.Item.LEFT,
    position = 5,
    get_item = {},
    on_draw = function(x, y, h, _, calc_only)
      local _, _, selected_lines = native_selection_counts(core.active_view)
      if selected_lines <= 0 then return draw_reserved_status_text("", "9999 lines selected", x, y, h, calc_only) end
      local label = string.format(" line%s selected", plural_suffix(selected_lines))
      return draw_reserved_count_label(selected_lines, label, " lines selected", x, y, h, calc_only)
    end
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:position-percent",
    alignment = StatusBar.Item.LEFT,
    get_item = function()
      local view = core.active_view
      local line = view:cursor_line_col() + 1
      return { string.format("%.f%%", line / math.max(1, view.buffer:line_count()) * 100) }
    end,
    tooltip = "caret position"
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:indentation",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      local indent_type, indent_size = core.active_view:get_indent_info()
      local indent_label = (indent_type == "hard") and "tabs: " or "spaces: "
      return { style.text, indent_label, indent_size }
    end,
    separator = core.status_bar.separator2
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:lines",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      return { style.text, core.active_view.buffer:line_count(), " lines" }
    end,
    separator = core.status_bar.separator2
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:encoding",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      return { style.text, "UTF-8" }
    end,
    tooltip = "encoding"
  })

  core.status_bar:add_item({
    predicate = NativeEditorView,
    name = "native:line-ending",
    alignment = StatusBar.Item.RIGHT,
    get_item = function()
      return { style.text, core.active_view.buffer:line_ending_mode():upper() }
    end,
    command = "native-editor:toggle-line-ending"
  })
end

register_statusbar_items()

local native_editor_commands = {
  ["native-editor:newline"] = with_active_native_view(function(view) view.editor:newline_auto_indent() end, true),
  ["native-editor:newline-below"] = with_active_native_view(function(view) view.editor:open_line_below() end, true),
  ["native-editor:newline-above"] = with_active_native_view(function(view) view.editor:open_line_above() end, true),
  ["native-editor:backspace"] = with_active_native_view(function(view) view.editor:backspace() end, true),
  ["native-editor:delete"] = with_active_native_view(function(view) view.editor:delete() end, true),
  ["native-editor:backspace-word"] = with_active_native_view(function(view) view.editor:backspace_word() end, true),
  ["native-editor:delete-word"] = with_active_native_view(function(view) view.editor:delete_word() end, true),
  ["native-editor:delete-line"] = with_active_native_view(function(view) view.editor:delete_line() end, true),
  ["native-editor:duplicate-line"] = with_active_native_view(function(view) view.editor:duplicate_line() end, true),
  ["native-editor:move-line-up"] = with_active_native_view(function(view) view.editor:move_line_up() end, true),
  ["native-editor:move-line-down"] = with_active_native_view(function(view) view.editor:move_line_down() end, true),
  ["native-editor:join-line"] = with_active_native_view(function(view) view.editor:join_line_below() end, true),
  ["native-editor:tab"] = with_active_native_view(function(view) view.editor:tab() end, true),
  ["native-editor:untab"] = with_active_native_view(function(view) view.editor:untab() end, true),
  ["native-editor:select-all"] = with_active_native_view(function(view) view.editor:select_all() end),
  ["native-editor:select-none"] = with_active_native_view(function(view)
    local cursor = view.editor:cursor()
    view.editor:set_cursor(cursor.cursor or 0)
  end),
  ["native-editor:select-word"] = with_active_native_view(function(view) view.editor:select_word() end),
  ["native-editor:select-line"] = with_active_native_view(function(view) view.editor:select_line() end),
  ["native-editor:go-to-line"] = with_active_native_view(function(view) go_to_native_line(view) end),
  ["native-editor:copy"] = with_active_native_view(function(view) copy_native_selection(view) end),
  ["native-editor:cut"] = with_active_native_view(function(view)
    local text = view.editor:cut_selection()
    if text and text ~= "" then
      system.set_clipboard(text)
    else
      text = native_current_lines_text(view)
      if text and text ~= "" then system.set_clipboard(text) end
      view.editor:delete_line()
    end
  end, true),
  ["native-editor:paste"] = with_active_native_view(function(view)
    local text = system.get_clipboard()
    if text and text ~= "" then
      local whole_line_text = native_whole_line_clipboard_payload(text)
      if whole_line_text then
        paste_native_whole_lines(view, whole_line_text)
      else
        view.editor:paste(text)
      end
    end
  end, true),
  ["native-editor:left"] = with_active_native_view(function(view) view.editor:left(false) end),
  ["native-editor:right"] = with_active_native_view(function(view) view.editor:right(false) end),
  ["native-editor:up"] = with_active_native_view(function(view) view.editor:line_up(false) end),
  ["native-editor:down"] = with_active_native_view(function(view) view.editor:line_down(false) end),
  ["native-editor:select-left"] = with_active_native_view(function(view) view.editor:left(true) end),
  ["native-editor:select-right"] = with_active_native_view(function(view) view.editor:right(true) end),
  ["native-editor:select-up"] = with_active_native_view(function(view) view.editor:line_up(true) end),
  ["native-editor:select-down"] = with_active_native_view(function(view) view.editor:line_down(true) end),
  ["native-editor:page-up"] = with_active_native_view(function(view) view:page_move(-1, false) end),
  ["native-editor:page-down"] = with_active_native_view(function(view) view:page_move(1, false) end),
  ["native-editor:select-page-up"] = with_active_native_view(function(view) view:page_move(-1, true) end),
  ["native-editor:select-page-down"] = with_active_native_view(function(view) view:page_move(1, true) end),
  ["native-editor:find"] = with_active_native_view(function(view) find_native_text(view, false) end),
  ["native-editor:find-next"] = with_active_native_view(function(view) repeat_native_find(view, false) end),
  ["native-editor:find-previous"] = with_active_native_view(function(view) repeat_native_find(view, true) end),
  ["native-editor:replace"] = with_active_native_view(function(view) replace_one_native_text(view) end),
  ["native-editor:replace-all"] = with_active_native_view(function(view) replace_all_native_text(view) end),
  ["native-editor:toggle-line-comment"] = with_active_native_view(function(view) view:toggle_line_comments() end, true),
  ["native-editor:move-to-matching-bracket"] = with_active_native_view(function(view) view:move_to_matching_bracket(false) end),
  ["native-editor:select-to-matching-bracket"] = with_active_native_view(function(view) view:move_to_matching_bracket(true) end),
  ["native-editor:word-left"] = with_active_native_view(function(view) view.editor:word_left(false) end),
  ["native-editor:word-right"] = with_active_native_view(function(view) view.editor:word_right(false) end),
  ["native-editor:select-word-left"] = with_active_native_view(function(view) view.editor:word_left(true) end),
  ["native-editor:select-word-right"] = with_active_native_view(function(view) view.editor:word_right(true) end),
  ["native-editor:home"] = with_active_native_view(function(view) view.editor:home_toggle_of_line(false) end),
  ["native-editor:end"] = with_active_native_view(function(view) view.editor:end_of_line(false) end),
  ["native-editor:select-home"] = with_active_native_view(function(view) view.editor:home_toggle_of_line(true) end),
  ["native-editor:select-end"] = with_active_native_view(function(view) view.editor:end_of_line(true) end),
  ["native-editor:start-of-buffer"] = with_active_native_view(function(view) view.editor:start_of_buffer(false) end),
  ["native-editor:end-of-buffer"] = with_active_native_view(function(view) view.editor:end_of_buffer(false) end),
  ["native-editor:select-start-of-buffer"] = with_active_native_view(function(view) view.editor:start_of_buffer(true) end),
  ["native-editor:select-end-of-buffer"] = with_active_native_view(function(view) view.editor:end_of_buffer(true) end),
  ["native-editor:undo"] = with_active_native_view(function(view) view.editor:undo() end, true),
  ["native-editor:redo"] = with_active_native_view(function(view) view.editor:redo() end, true),
  ["native-editor:save"] = with_active_native_view(function(view)
    save_existing_native_view(view)
  end),
  ["native-editor:save-as"] = with_active_native_view(function(view) save_native_view_as(view) end),
  ["native-editor:toggle-line-ending"] = with_active_native_view(function(view)
    local mode = view.buffer:line_ending_mode() == "crlf" and "lf" or "crlf"
    if view.buffer:set_line_ending_mode(mode) then
      core.log_quiet("Native Buffer line ending mode changed to %s", mode:upper())
      core.redraw = true
    end
  end),
  ["native-editor:toggle-overwrite"] = with_active_native_view(function(view)
    local overwrite = view.editor:toggle_overwrite_mode()
    core.log_quiet("Native editor overwrite mode %s", overwrite and "enabled" or "disabled")
    core.blink_reset()
  end),
  ["native-editor:duplicate-cursor-up"] = with_active_native_view(function(view) view.editor:dup_cursor_up() end),
  ["native-editor:duplicate-cursor-down"] = with_active_native_view(function(view) view.editor:dup_cursor_down() end),
}
command.add(active_native_editor_view, native_editor_commands)
add_native_editor_legacy_aliases(native_editor_commands)

keymap.add {
  ["return"] = "native-editor:newline",
  ["ctrl+return"] = "native-editor:newline-below",
  ["ctrl+shift+return"] = "native-editor:newline-above",
  ["backspace"] = "native-editor:backspace",
  ["delete"] = "native-editor:delete",
  ["ctrl+backspace"] = "native-editor:backspace-word",
  ["ctrl+delete"] = "native-editor:delete-word",
  ["ctrl+shift+k"] = "native-editor:delete-line",
  ["ctrl+d"] = "native-editor:duplicate-line",
  ["ctrl+up"] = "native-editor:move-line-up",
  ["ctrl+down"] = "native-editor:move-line-down",
  ["ctrl+j"] = "native-editor:join-line",
  ["tab"] = "native-editor:tab",
  ["shift+tab"] = "native-editor:untab",
  ["ctrl+a"] = "native-editor:select-all",
  ["escape"] = "native-editor:select-none",
  ["ctrl+l"] = "native-editor:select-line",
  ["ctrl+g"] = "native-editor:go-to-line",
  ["ctrl+c"] = "native-editor:copy",
  ["ctrl+x"] = "native-editor:cut",
  ["ctrl+v"] = "native-editor:paste",
  ["ctrl+insert"] = "native-editor:copy",
  ["shift+insert"] = "native-editor:paste",
  ["insert"] = "native-editor:toggle-overwrite",
  ["left"] = "native-editor:left",
  ["right"] = "native-editor:right",
  ["up"] = "native-editor:up",
  ["down"] = "native-editor:down",
  ["shift+left"] = "native-editor:select-left",
  ["shift+right"] = "native-editor:select-right",
  ["shift+up"] = "native-editor:select-up",
  ["shift+down"] = "native-editor:select-down",
  ["pageup"] = "native-editor:page-up",
  ["pagedown"] = "native-editor:page-down",
  ["shift+pageup"] = "native-editor:select-page-up",
  ["shift+pagedown"] = "native-editor:select-page-down",
  ["ctrl+f"] = "native-editor:find",
  ["ctrl+r"] = "native-editor:replace",
  ["ctrl+shift+r"] = "native-editor:replace-all",
  ["ctrl+/"] = "native-editor:toggle-line-comment",
  ["f3"] = "native-editor:find-next",
  ["shift+f3"] = "native-editor:find-previous",
  ["ctrl+shift+m"] = "native-editor:select-to-matching-bracket",
  ["ctrl+left"] = "native-editor:word-left",
  ["ctrl+right"] = "native-editor:word-right",
  ["ctrl+shift+left"] = "native-editor:select-word-left",
  ["ctrl+shift+right"] = "native-editor:select-word-right",
  ["home"] = "native-editor:home",
  ["end"] = "native-editor:end",
  ["shift+home"] = "native-editor:select-home",
  ["shift+end"] = "native-editor:select-end",
  ["ctrl+home"] = "native-editor:start-of-buffer",
  ["ctrl+end"] = "native-editor:end-of-buffer",
  ["ctrl+shift+home"] = "native-editor:select-start-of-buffer",
  ["ctrl+shift+end"] = "native-editor:select-end-of-buffer",
  ["ctrl+z"] = "native-editor:undo",
  ["ctrl+y"] = "native-editor:redo",
  ["ctrl+s"] = "native-editor:save",
  ["ctrl+shift+s"] = "native-editor:save-as",
  ["ctrl+shift+up"] = "native-editor:duplicate-cursor-up",
  ["ctrl+shift+down"] = "native-editor:duplicate-cursor-down",
}

local core_exit = core.__native_editor_original_exit or core.exit
core.__native_editor_original_exit = core_exit
local function dirty_native_views()
  local dirty = {}
  local root = core.root_panel and core.root_panel.root_node
  if not root then return dirty end
  for _, view in ipairs(root:get_children()) do
    if view:is(NativeEditorView) and view:is_dirty() then
      dirty[#dirty + 1] = view
    end
  end
  return dirty
end

core.add_thread(function()
  while true do
    local root = core.root_panel and core.root_panel.root_node
    if root then
      for _, view in ipairs(root:get_children()) do
        if view:is(NativeEditorView) then view:check_external_file_change() end
      end
    end
    coroutine.yield(1)
  end
end)

function core.exit(quit_fn, force)
  if force then return core_exit(quit_fn, force) end
  local dirty = dirty_native_views()
  if #dirty == 0 then return core_exit(quit_fn, force) end

  local text
  if #dirty == 1 then
    text = string.format("\"%s\" has unsaved native Buffer changes. Quit anyway?", dirty[1]:get_name():gsub("^%*", ""))
  else
    text = string.format("%d native Buffers have unsaved changes. Quit anyway?", #dirty)
  end
  core.nag_view:show("Unsaved Native Buffers", text, {
    { text = "Yes", default_yes = true },
    { text = "No", default_no = true },
  }, function(item)
    if item.text == "Yes" then core_exit(quit_fn, force) end
  end)
end

return NativeEditorView
