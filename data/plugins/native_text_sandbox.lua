-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local StatusBar = require "core.statusbar"
local View = require "core.view"
local native_text = require "native_text"

local TREE_SITTER_REPARSE_DELAY = 0.25

local plugin_config = config.plugins.native_editor or config.plugins.native_text_sandbox or {}
local save_native_view_as
local save_existing_native_view
local last_find_text
local close_native_view

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

local NativeTextSandboxView = View:extend()

function NativeTextSandboxView:__tostring() return "NativeTextSandboxView" end

NativeTextSandboxView.context = "workspace"
NativeTextSandboxView.native_editor_view = true
NativeTextSandboxView._module_name = "plugins.native_editor"

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

function NativeTextSandboxView:new(text, filename, buffer, identity_key)
  NativeTextSandboxView.super.new(self)
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
end

function NativeTextSandboxView:enable_tree_sitter_for_path(filename)
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

function NativeTextSandboxView:update_file_signature()
  self.file_signature = file_signature(self.buffer:path())
end

function NativeTextSandboxView:reload_from_disk()
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
    if view:is(NativeTextSandboxView) and view.buffer == buffer then
      view:enable_tree_sitter_for_path(path)
      view.editor:set_cursor(0)
      view:update_file_signature()
      view.external_reload_prompting = false
      view.tree_sitter_dirty_since = nil
    end
  end
  core.log_quiet("Reloaded shared native Buffer from disk: %s", path)
  core.redraw = true
  return true
end

function NativeTextSandboxView:check_external_file_change()
  local path = self.buffer:path()
  if not path or self.external_reload_prompting then return end
  local current = file_signature(path)
  if same_file_signature(self.file_signature, current) then return end
  if not self.buffer:is_dirty() then
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

function NativeTextSandboxView:get_name()
  local path = self.buffer:path()
  local name = path and common.basename(path) or "Native Editor"
  if self.buffer:is_dirty() then name = "*" .. name end
  return name
end

function NativeTextSandboxView:get_filename()
  local path = self.buffer:path()
  if path then
    return common.home_encode(path) .. (self.buffer:is_dirty() and "*" or "")
  end
  return self:get_name()
end

function NativeTextSandboxView:try_close(do_close)
  if not self.buffer:is_dirty() then
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

function NativeTextSandboxView:supports_text_input()
  return true
end

function NativeTextSandboxView:get_state()
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

function NativeTextSandboxView.from_state(state)
  state = state or {}
  local buffer, identity_key
  if state.filename then
    buffer, identity_key = open_registered_native_buffer(state.filename)
  end
  local view = NativeTextSandboxView(state.text, state.filename, buffer, identity_key)
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

function NativeTextSandboxView:note_tree_sitter_mutation()
  if self.tree_sitter_enabled and self.buffer:tree_sitter_is_dirty() then
    self.tree_sitter_dirty_since = system.get_time()
    core.redraw = true
  end
end

function NativeTextSandboxView:update_tree_sitter()
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

function NativeTextSandboxView:update()
  NativeTextSandboxView.super.update(self)
  self:update_tree_sitter()
end

function NativeTextSandboxView:get_line_height()
  return style.font:get_height() + math.floor(style.padding.y / 2)
end

function NativeTextSandboxView:get_gutter_width()
  return style.font:get_width(tostring(math.max(1, self.buffer:line_count()))) + style.padding.x * 2
end

function NativeTextSandboxView:get_scrollable_size()
  return math.max(self.size.y, self.buffer:line_count() * self:get_line_height() + style.padding.y * 2)
end

function NativeTextSandboxView:get_h_scrollable_size()
  return math.max(self.size.x, self.h_scrollable_size or 0)
end

function NativeTextSandboxView:line_col_to_screen(line, col)
  local lh = self:get_line_height()
  local x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x + style.font:get_width(string.rep(" ", col))
  local y = self.position.y + style.padding.y - self.scroll.y + line * lh
  return x, y
end

function NativeTextSandboxView:cursor_line_col(cursor)
  cursor = cursor or (self.editor:cursor().cursor or 0)
  local lc = self.buffer:offset_to_line_col(cursor)
  return lc and lc.line or 0, lc and lc.col or 0
end

function NativeTextSandboxView:screen_to_offset(x, y)
  local lh = self:get_line_height()
  local line = math.floor((y - self.position.y + self.scroll.y - style.padding.y) / lh)
  line = common.clamp(line, 0, math.max(0, self.buffer:line_count() - 1))
  local text = self.buffer:line(line) or ""
  local text_x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x
  local col = 0
  local relx = math.max(0, x - text_x)
  for i = 1, #text do
    local next_width = style.font:get_width(text:sub(1, i))
    if next_width > relx then break end
    col = i
  end
  return self.buffer:line_col_to_offset(line, col)
end

function NativeTextSandboxView:draw_caret_for_cursor(cursor)
  local cursor_line, cursor_col = self:cursor_line_col(cursor.cursor or 0)
  local caret_x, caret_y = self:line_col_to_screen(cursor_line, cursor_col)
  renderer.draw_rect(caret_x, caret_y, math.max(1, SCALE), style.font:get_height(), style.caret)
end

function NativeTextSandboxView:draw_line_text(line_info, row_y, highlights)
  local text = line_info.text or ""
  local x = self.position.x + self:get_gutter_width() + style.padding.x - self.scroll.x
  local width = self:get_gutter_width() + style.padding.x * 2 + style.font:get_width(text)
  if width > (self.h_scrollable_size or 0) then self.h_scrollable_size = width end
  if not highlights or #highlights == 0 then
    renderer.draw_text(style.font, text, x, row_y, style.text)
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
    local sx = x + style.font:get_width(text:sub(1, first_col))
    renderer.draw_text(style.font, segment, sx, row_y, color)
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
end

function NativeTextSandboxView:cursor_has_selection(cursor)
  return cursor.selection and cursor.selection ~= cursor.cursor
end

function NativeTextSandboxView:has_selection()
  for i = 1, self.editor:cursor_count() do
    if self:cursor_has_selection(self.editor:cursor(i)) then return true end
  end
  return false
end

function NativeTextSandboxView:draw_current_line_highlights()
  if core.active_view ~= self or config.highlight_current_line == false then return end
  if config.highlight_current_line == "no_selection" and self:has_selection() then return end
  local lh = self:get_line_height()
  local seen = {}
  for i = 1, self.editor:cursor_count() do
    local line = self:cursor_line_col(self.editor:cursor(i).cursor or 0)
    if not seen[line] then
      local y = self.position.y + style.padding.y - self.scroll.y + line * lh
      renderer.draw_rect(self.position.x, y, self.size.x, lh, style.line_highlight)
      seen[line] = true
    end
  end
end

function NativeTextSandboxView:draw_selection_for_cursor(cursor)
  if not self:cursor_has_selection(cursor) then return end
  local first = math.min(cursor.cursor, cursor.selection)
  local last = math.max(cursor.cursor, cursor.selection)
  local start_lc = self.buffer:offset_to_line_col(first)
  local end_lc = self.buffer:offset_to_line_col(last)
  if not start_lc or not end_lc then return end

  local lh = self:get_line_height()
  for line = start_lc.line, end_lc.line do
    local line_text = self.buffer:line(line) or ""
    local start_col = line == start_lc.line and start_lc.col or 0
    local end_col = line == end_lc.line and end_lc.col or #line_text
    if end_col >= start_col then
      local x1, y1 = self:line_col_to_screen(line, start_col)
      local x2 = self:line_col_to_screen(line, end_col)
      if x2 == x1 then x2 = x1 + math.max(1, SCALE) end
      renderer.draw_rect(x1, y1, x2 - x1, lh, style.selection)
    end
  end
end

function NativeTextSandboxView:scroll_to_cursor()
  local line, col = self:cursor_line_col()
  local lh = self:get_line_height()
  local y = line * lh
  if y < self.scroll.to.y then
    self.scroll.to.y = y
  elseif y + lh > self.scroll.to.y + self.size.y then
    self.scroll.to.y = y + lh - self.size.y + style.padding.y * 2
  end

  local gutter_w = self:get_gutter_width()
  local available_w = math.max(1, self.size.x - gutter_w - style.padding.x * 2)
  local x = style.font:get_width(string.rep(" ", col))
  self.h_scrollable_size = math.max(self.h_scrollable_size or 0, gutter_w + style.padding.x * 2 + x + style.font:get_width(" "))
  if x < self.scroll.to.x then
    self.scroll.to.x = x
  elseif x > self.scroll.to.x + available_w then
    self.scroll.to.x = x - available_w + style.font:get_width(" ")
  end
  self:clamp_scroll_position()
end

function NativeTextSandboxView:page_move(direction, update_selection)
  local lines = math.max(1, math.floor(self.size.y / self:get_line_height()) - 1)
  local move = direction < 0 and self.editor.line_up or self.editor.line_down
  for _ = 1, lines do move(self.editor, update_selection) end
end

function NativeTextSandboxView:on_text_input(text)
  if text and text ~= "" then
    self.editor:insert(text)
    self:note_tree_sitter_mutation()
    self:scroll_to_cursor()
    core.redraw = true
  end
  return true
end

function NativeTextSandboxView:on_mouse_pressed(button, x, y, clicks)
  if NativeTextSandboxView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return false end

  local offset = self:screen_to_offset(x, y)
  if offset then
    local anchor
    if keymap.modkeys["shift"] then
      local cursor = self.editor:cursor()
      anchor = cursor.selection or cursor.cursor
      self.editor:set_cursor(offset, anchor)
    else
      self.editor:set_cursor(offset)
      anchor = offset
    end
    self.mouse_selecting = { anchor = anchor }
    if clicks == 2 then
      self.editor:select_word()
      self.mouse_selecting = nil
    elseif clicks and clicks >= 3 then
      self.editor:select_line()
      self.mouse_selecting = nil
    end
  end
  core.redraw = true
  return true
end

function NativeTextSandboxView:on_mouse_moved(x, y, ...)
  NativeTextSandboxView.super.on_mouse_moved(self, x, y, ...)
  self.cursor = "ibeam"
  if self.mouse_selecting then
    local offset = self:screen_to_offset(x, y)
    if offset then
      self.editor:set_cursor(offset, self.mouse_selecting.anchor)
      self:scroll_to_cursor()
      core.redraw = true
    end
    return true
  end
end

function NativeTextSandboxView:on_mouse_released(button, x, y)
  NativeTextSandboxView.super.on_mouse_released(self, button, x, y)
  if button == "left" then self.mouse_selecting = nil end
end

function NativeTextSandboxView:find_literal(text, backwards)
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
  self.editor:set_cursor(end_match, start_match)
  self:scroll_to_cursor()
  core.redraw = true
  return true
end

function NativeTextSandboxView:draw()
  self:draw_background(style.background)
  self:update()

  local x = self.position.x
  local y = self.position.y
  local w = self.size.x
  local h = self.size.y
  local lh = self:get_line_height()
  local gutter_w = self:get_gutter_width()
  local line_count = self.buffer:line_count()
  local first_line = math.max(0, math.floor(self.scroll.y / lh))
  local last_line = math.min(line_count - 1, first_line + math.ceil(h / lh) + 1)

  core.push_clip_rect(x, y, w, h)
  renderer.draw_rect(x, y, gutter_w, h, style.line_number_background or style.background2)
  self:draw_current_line_highlights()

  for i = 1, self.editor:cursor_count() do
    self:draw_selection_for_cursor(self.editor:cursor(i))
  end

  local visible_lines = self.buffer:visible_lines(first_line, last_line)
  local highlights = nil
  if self.tree_sitter_enabled and #visible_lines > 0 then
    local visible_start = visible_lines[1].start_offset or 0
    local visible_end = visible_lines[#visible_lines].end_offset or self.buffer:len()
    highlights = self.buffer:tree_sitter_highlights(visible_start, visible_end)
  end

  for _, line_info in ipairs(visible_lines) do
    local line = line_info.line
    local row_y = y + style.padding.y - self.scroll.y + line * lh
    local line_number = tostring(line + 1)
    common.draw_text(style.font, style.dim, line_number, "right", x, row_y, gutter_w - style.padding.x, lh)
    self:draw_line_text(line_info, row_y, highlights)
  end

  for i = 1, self.editor:cursor_count() do
    self:draw_caret_for_cursor(self.editor:cursor(i))
  end

  core.pop_clip_rect()
  self:draw_scrollbar()
end

local function with_active_native_view(fn, affects_text)
  return function(view)
    view = view or core.active_view
    if is_native_editor_view(view) then
      fn(view)
      if affects_text then view:note_tree_sitter_mutation() end
      view:scroll_to_cursor()
      core.redraw = true
    end
  end
end

local function copy_native_selection(view)
  local text = view.editor:copy_selection()
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
    if view:is(NativeTextSandboxView) and view.buffer == buffer then
      fn(view)
    end
  end
end

local function update_shared_buffer_identity(buffer, identity_key)
  for_each_native_buffer_view(buffer, function(view)
    view.buffer_identity_key = identity_key
  end)
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

function save_native_view_as(view, close_after_save)
  core.save_file_dialog(core.window, function(status, result)
    if status == "accept" then
      local filename = type(result) == "table" and result[1] or result
      if filename and filename ~= "" then
        if view.buffer:save_file(filename) then
          register_saved_native_buffer(view, filename)
          view:update_file_signature()
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
    if view:is(NativeTextSandboxView) then
      local path = view.buffer:path()
      if path and common.path_equals(path, filename) then return view end
    end
  end
end

local function find_open_native_text_buffer(buffer, excluded_view)
  local root = core.root_panel and core.root_panel.root_node
  if not root or not buffer then return nil end
  for _, view in ipairs(root:get_children()) do
    if view ~= excluded_view and view:is(NativeTextSandboxView) and view.buffer == buffer then
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
  local buffer, identity_key, reused = open_registered_native_buffer(filename)
  if not buffer then return end
  local view = NativeTextSandboxView(nil, filename, buffer, identity_key)
  core.root_panel:get_active_node_default():add_view(view)
  if core.set_visited then core.set_visited(filename) end
  core.log_quiet("Opened native Buffer%s: %s", reused and " from registry" or "", filename)
  return view
end

function core.open_native_editor_file(filename)
  return open_native_text_file(filename)
end

if plugin_config.default_open then
  local core_open_file = core.open_file
  function core.open_file(filename)
    local image_view = core.open_image(filename)
    if image_view then return image_view end
    return core.open_native_editor_file(filename) or core_open_file(filename)
  end
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
    core.root_panel:get_active_node_default():add_view(NativeTextSandboxView())
  end,
  ["native-editor:open-file"] = function()
    core.open_file_dialog(core.window, function(status, result)
      if status == "accept" then
        for _, filename in ipairs(result) do core.open_native_editor_file(filename) end
      elseif status == "error" then
        core.error("Error while opening native text dialog: %s", result or "")
      end
    end, { allow_many = true })
  end,
}
command.add(nil, native_editor_global_commands)
add_native_editor_legacy_aliases(native_editor_global_commands)

local function register_statusbar_items()
  if not core.status_bar then return end
  if not core.status_bar:get_item("native-text:file") then
    core.status_bar:add_item({
      predicate = NativeTextSandboxView,
      name = "native-text:file",
      alignment = StatusBar.Item.LEFT,
      get_item = function()
        local view = core.active_view
        local path = view.buffer:path()
        return { path and style.text or style.dim, path and common.home_encode(path) or "Native Editor" }
      end,
    })
  end
  if not core.status_bar:get_item("native-text:position") then
    core.status_bar:add_item({
      predicate = NativeTextSandboxView,
      name = "native-text:position",
      alignment = StatusBar.Item.LEFT,
      get_item = function()
        local view = core.active_view
        local line, col = view:cursor_line_col()
        return { style.text, string.format("%d:%d", line + 1, col + 1) }
      end,
    })
  end
  if not core.status_bar:get_item("native-text:line-ending") then
    core.status_bar:add_item({
      predicate = NativeTextSandboxView,
      name = "native-text:line-ending",
      alignment = StatusBar.Item.RIGHT,
      get_item = function()
        local view = core.active_view
        return { style.text, view.buffer:line_ending_mode():upper() }
      end,
    })
  end
end

register_statusbar_items()

local native_editor_commands = {
  ["native-editor:newline"] = with_active_native_view(function(view) view.editor:newline() end, true),
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
  ["native-editor:select-line"] = with_active_native_view(function(view) view.editor:select_line() end),
  ["native-editor:go-to-line"] = with_active_native_view(function(view) go_to_native_line(view) end),
  ["native-editor:copy"] = with_active_native_view(function(view) copy_native_selection(view) end),
  ["native-editor:cut"] = with_active_native_view(function(view)
    local text = view.editor:cut_selection()
    if text and text ~= "" then system.set_clipboard(text) end
  end, true),
  ["native-editor:paste"] = with_active_native_view(function(view)
    local text = system.get_clipboard()
    if text and text ~= "" then view.editor:paste(text) end
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
  ["ctrl+l"] = "native-editor:select-line",
  ["ctrl+g"] = "native-editor:go-to-line",
  ["ctrl+c"] = "native-editor:copy",
  ["ctrl+x"] = "native-editor:cut",
  ["ctrl+v"] = "native-editor:paste",
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
  ["f3"] = "native-editor:find-next",
  ["shift+f3"] = "native-editor:find-previous",
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

local core_exit = core.__native_text_sandbox_original_exit or core.exit
core.__native_text_sandbox_original_exit = core_exit
local function dirty_native_views()
  local dirty = {}
  local root = core.root_panel and core.root_panel.root_node
  if not root then return dirty end
  for _, view in ipairs(root:get_children()) do
    if view:is(NativeTextSandboxView) and view.buffer:is_dirty() then
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
        if view:is(NativeTextSandboxView) then view:check_external_file_change() end
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

return NativeTextSandboxView
