-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local native_text = require "native_text"

local TREE_SITTER_REPARSE_DELAY = 0.25

local plugin_config = config.plugins.native_text_sandbox
local save_native_view_as
local last_find_text

local NativeTextSandboxView = View:extend()

function NativeTextSandboxView:__tostring() return "NativeTextSandboxView" end

NativeTextSandboxView.context = "workspace"

function NativeTextSandboxView:new(text, filename)
  NativeTextSandboxView.super.new(self)
  self.buffer = native_text.new_buffer(text or "Native text sandbox\n\nType here. This view is backed by src/text Buffer/Editor userdata.")
  if filename then
    local ok = self.buffer:load_file(filename)
    if not ok then core.error("Failed to open native Buffer: %s", filename) end
  end
  local language = filename and native_text.tree_sitter_language_for_filename(filename) or nil
  self.tree_sitter_enabled = language and self.buffer:enable_tree_sitter(language) or false
  if language then
    if self.tree_sitter_enabled then
      core.log_quiet("Native text sandbox enabled Tree-sitter language '%s' for %s", language, filename or "scratch")
    else
      core.log_quiet("Native text sandbox failed to enable Tree-sitter language '%s' for %s", language, filename or "scratch")
    end
  end
  self.editor = self.buffer:new_editor()
  self.tree_sitter_dirty_since = nil
  self.scrollable = true
  self.cursor = "ibeam"
end

function NativeTextSandboxView:get_name()
  local path = self.buffer:path()
  local name = path and common.basename(path) or "Native Text Sandbox"
  if self.buffer:is_dirty() then name = "*" .. name end
  return name
end

function NativeTextSandboxView:try_close(do_close)
  if not self.buffer:is_dirty() then
    do_close()
    return
  end

  local path = self.buffer:path()
  core.global_prompt_bar:enter("Unsaved Native Buffer; Confirm Close", {
    submit = function(_, item)
      if item.text:match("^[cC]") then
        do_close()
      elseif item.text:match("^[sS]") then
        if path then
          if self.buffer:save_file() then
            do_close()
          else
            core.error("Failed to save native Buffer: %s", path)
          end
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

function NativeTextSandboxView:note_tree_sitter_mutation()
  if self.tree_sitter_enabled and self.buffer:tree_sitter_is_dirty() then
    self.tree_sitter_dirty_since = system.get_time()
    core.redraw = true
  end
end

function NativeTextSandboxView:update_tree_sitter()
  if not self.tree_sitter_enabled then return end
  if self.buffer:poll_tree_sitter_reparse() then
    core.log_quiet("Native text sandbox applied background Tree-sitter parse")
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
      core.log_quiet("Native text sandbox scheduled background Tree-sitter parse after idle debounce")
    else
      core.log_quiet("Native text sandbox failed to schedule Tree-sitter parse; will retry after debounce")
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

function NativeTextSandboxView:draw_selection_for_cursor(cursor)
  if not cursor.selection or cursor.selection == cursor.cursor then return end
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
  local line = self:cursor_line_col()
  local lh = self:get_line_height()
  local y = line * lh
  if y < self.scroll.to.y then
    self.scroll.to.y = y
  elseif y + lh > self.scroll.to.y + self.size.y then
    self.scroll.to.y = y + lh - self.size.y + style.padding.y * 2
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
    if view and view:is(NativeTextSandboxView) then
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

local function replace_all_native_text(view)
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

function save_native_view_as(view, close_after_save)
  core.save_file_dialog(core.window, function(status, result)
    if status == "accept" then
      local filename = type(result) == "table" and result[1] or result
      if filename and filename ~= "" then
        if view.buffer:save_file(filename) then
          if close_after_save then
            local node = core.root_panel.root_node:get_node_for_view(view)
            if node then node:close_view(core.root_panel.root_node, view) end
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

local function open_native_text_file(filename)
  if not filename or filename == "" then return end
  local existing = find_open_native_text_file(filename)
  if existing then
    local node = core.root_panel.root_node:get_node_for_view(existing)
    if node then node:set_active_view(existing) end
    core.log_quiet("Focused already-open native Buffer: %s", filename)
    return existing
  end
  local view = NativeTextSandboxView(nil, filename)
  core.root_panel:get_active_node_default():add_view(view)
  return view
end

if plugin_config.default_open then
  local core_open_file = core.open_file
  function core.open_file(filename)
    local image_view = core.open_image(filename)
    if image_view then return image_view end
    return open_native_text_file(filename) or core_open_file(filename)
  end
  core.log_quiet("Native text sandbox default-open experiment is enabled")
end

command.add(nil, {
  ["native-text-sandbox:open"] = function()
    core.root_panel:get_active_node_default():add_view(NativeTextSandboxView())
  end,
  ["native-text-sandbox:open-file"] = function()
    core.open_file_dialog(core.window, function(status, result)
      if status == "accept" then
        for _, filename in ipairs(result) do open_native_text_file(filename) end
      elseif status == "error" then
        core.error("Error while opening native text dialog: %s", result or "")
      end
    end, { allow_many = true })
  end,
})

command.add(NativeTextSandboxView, {
  ["native-text-sandbox:newline"] = with_active_native_view(function(view) view.editor:newline() end, true),
  ["native-text-sandbox:newline-below"] = with_active_native_view(function(view) view.editor:open_line_below() end, true),
  ["native-text-sandbox:newline-above"] = with_active_native_view(function(view) view.editor:open_line_above() end, true),
  ["native-text-sandbox:backspace"] = with_active_native_view(function(view) view.editor:backspace() end, true),
  ["native-text-sandbox:delete"] = with_active_native_view(function(view) view.editor:delete() end, true),
  ["native-text-sandbox:backspace-word"] = with_active_native_view(function(view) view.editor:backspace_word() end, true),
  ["native-text-sandbox:delete-word"] = with_active_native_view(function(view) view.editor:delete_word() end, true),
  ["native-text-sandbox:delete-line"] = with_active_native_view(function(view) view.editor:delete_line() end, true),
  ["native-text-sandbox:move-line-up"] = with_active_native_view(function(view) view.editor:move_line_up() end, true),
  ["native-text-sandbox:move-line-down"] = with_active_native_view(function(view) view.editor:move_line_down() end, true),
  ["native-text-sandbox:join-line"] = with_active_native_view(function(view) view.editor:join_line_below() end, true),
  ["native-text-sandbox:tab"] = with_active_native_view(function(view) view.editor:tab() end, true),
  ["native-text-sandbox:untab"] = with_active_native_view(function(view) view.editor:untab() end, true),
  ["native-text-sandbox:select-all"] = with_active_native_view(function(view) view.editor:select_all() end),
  ["native-text-sandbox:copy"] = with_active_native_view(function(view) copy_native_selection(view) end),
  ["native-text-sandbox:cut"] = with_active_native_view(function(view)
    local text = view.editor:cut_selection()
    if text and text ~= "" then system.set_clipboard(text) end
  end, true),
  ["native-text-sandbox:paste"] = with_active_native_view(function(view)
    local text = system.get_clipboard()
    if text and text ~= "" then view.editor:paste(text) end
  end, true),
  ["native-text-sandbox:left"] = with_active_native_view(function(view) view.editor:left(false) end),
  ["native-text-sandbox:right"] = with_active_native_view(function(view) view.editor:right(false) end),
  ["native-text-sandbox:up"] = with_active_native_view(function(view) view.editor:line_up(false) end),
  ["native-text-sandbox:down"] = with_active_native_view(function(view) view.editor:line_down(false) end),
  ["native-text-sandbox:select-left"] = with_active_native_view(function(view) view.editor:left(true) end),
  ["native-text-sandbox:select-right"] = with_active_native_view(function(view) view.editor:right(true) end),
  ["native-text-sandbox:select-up"] = with_active_native_view(function(view) view.editor:line_up(true) end),
  ["native-text-sandbox:select-down"] = with_active_native_view(function(view) view.editor:line_down(true) end),
  ["native-text-sandbox:page-up"] = with_active_native_view(function(view) view:page_move(-1, false) end),
  ["native-text-sandbox:page-down"] = with_active_native_view(function(view) view:page_move(1, false) end),
  ["native-text-sandbox:select-page-up"] = with_active_native_view(function(view) view:page_move(-1, true) end),
  ["native-text-sandbox:select-page-down"] = with_active_native_view(function(view) view:page_move(1, true) end),
  ["native-text-sandbox:find"] = with_active_native_view(function(view) find_native_text(view, false) end),
  ["native-text-sandbox:find-next"] = with_active_native_view(function(view) repeat_native_find(view, false) end),
  ["native-text-sandbox:find-previous"] = with_active_native_view(function(view) repeat_native_find(view, true) end),
  ["native-text-sandbox:replace-all"] = with_active_native_view(function(view) replace_all_native_text(view) end),
  ["native-text-sandbox:word-left"] = with_active_native_view(function(view) view.editor:word_left(false) end),
  ["native-text-sandbox:word-right"] = with_active_native_view(function(view) view.editor:word_right(false) end),
  ["native-text-sandbox:select-word-left"] = with_active_native_view(function(view) view.editor:word_left(true) end),
  ["native-text-sandbox:select-word-right"] = with_active_native_view(function(view) view.editor:word_right(true) end),
  ["native-text-sandbox:home"] = with_active_native_view(function(view) view.editor:home_toggle_of_line(false) end),
  ["native-text-sandbox:end"] = with_active_native_view(function(view) view.editor:end_of_line(false) end),
  ["native-text-sandbox:select-home"] = with_active_native_view(function(view) view.editor:home_toggle_of_line(true) end),
  ["native-text-sandbox:select-end"] = with_active_native_view(function(view) view.editor:end_of_line(true) end),
  ["native-text-sandbox:start-of-buffer"] = with_active_native_view(function(view) view.editor:start_of_buffer(false) end),
  ["native-text-sandbox:end-of-buffer"] = with_active_native_view(function(view) view.editor:end_of_buffer(false) end),
  ["native-text-sandbox:select-start-of-buffer"] = with_active_native_view(function(view) view.editor:start_of_buffer(true) end),
  ["native-text-sandbox:select-end-of-buffer"] = with_active_native_view(function(view) view.editor:end_of_buffer(true) end),
  ["native-text-sandbox:undo"] = with_active_native_view(function(view) view.editor:undo() end, true),
  ["native-text-sandbox:redo"] = with_active_native_view(function(view) view.editor:redo() end, true),
  ["native-text-sandbox:save"] = with_active_native_view(function(view)
    if view.buffer:path() then
      if not view.buffer:save_file() then core.error("Failed to save native Buffer") end
    else
      save_native_view_as(view)
    end
  end),
  ["native-text-sandbox:save-as"] = with_active_native_view(function(view) save_native_view_as(view) end),
  ["native-text-sandbox:duplicate-cursor-up"] = with_active_native_view(function(view) view.editor:dup_cursor_up() end),
  ["native-text-sandbox:duplicate-cursor-down"] = with_active_native_view(function(view) view.editor:dup_cursor_down() end),
})

keymap.add {
  ["return"] = "native-text-sandbox:newline",
  ["ctrl+return"] = "native-text-sandbox:newline-below",
  ["ctrl+shift+return"] = "native-text-sandbox:newline-above",
  ["backspace"] = "native-text-sandbox:backspace",
  ["delete"] = "native-text-sandbox:delete",
  ["ctrl+backspace"] = "native-text-sandbox:backspace-word",
  ["ctrl+delete"] = "native-text-sandbox:delete-word",
  ["ctrl+shift+k"] = "native-text-sandbox:delete-line",
  ["ctrl+up"] = "native-text-sandbox:move-line-up",
  ["ctrl+down"] = "native-text-sandbox:move-line-down",
  ["ctrl+j"] = "native-text-sandbox:join-line",
  ["tab"] = "native-text-sandbox:tab",
  ["shift+tab"] = "native-text-sandbox:untab",
  ["ctrl+a"] = "native-text-sandbox:select-all",
  ["ctrl+c"] = "native-text-sandbox:copy",
  ["ctrl+x"] = "native-text-sandbox:cut",
  ["ctrl+v"] = "native-text-sandbox:paste",
  ["left"] = "native-text-sandbox:left",
  ["right"] = "native-text-sandbox:right",
  ["up"] = "native-text-sandbox:up",
  ["down"] = "native-text-sandbox:down",
  ["shift+left"] = "native-text-sandbox:select-left",
  ["shift+right"] = "native-text-sandbox:select-right",
  ["shift+up"] = "native-text-sandbox:select-up",
  ["shift+down"] = "native-text-sandbox:select-down",
  ["pageup"] = "native-text-sandbox:page-up",
  ["pagedown"] = "native-text-sandbox:page-down",
  ["shift+pageup"] = "native-text-sandbox:select-page-up",
  ["shift+pagedown"] = "native-text-sandbox:select-page-down",
  ["ctrl+f"] = "native-text-sandbox:find",
  ["ctrl+r"] = "native-text-sandbox:replace-all",
  ["f3"] = "native-text-sandbox:find-next",
  ["shift+f3"] = "native-text-sandbox:find-previous",
  ["ctrl+left"] = "native-text-sandbox:word-left",
  ["ctrl+right"] = "native-text-sandbox:word-right",
  ["ctrl+shift+left"] = "native-text-sandbox:select-word-left",
  ["ctrl+shift+right"] = "native-text-sandbox:select-word-right",
  ["home"] = "native-text-sandbox:home",
  ["end"] = "native-text-sandbox:end",
  ["shift+home"] = "native-text-sandbox:select-home",
  ["shift+end"] = "native-text-sandbox:select-end",
  ["ctrl+home"] = "native-text-sandbox:start-of-buffer",
  ["ctrl+end"] = "native-text-sandbox:end-of-buffer",
  ["ctrl+shift+home"] = "native-text-sandbox:select-start-of-buffer",
  ["ctrl+shift+end"] = "native-text-sandbox:select-end-of-buffer",
  ["ctrl+z"] = "native-text-sandbox:undo",
  ["ctrl+y"] = "native-text-sandbox:redo",
  ["ctrl+s"] = "native-text-sandbox:save",
  ["ctrl+shift+s"] = "native-text-sandbox:save-as",
  ["ctrl+shift+up"] = "native-text-sandbox:duplicate-cursor-up",
  ["ctrl+shift+down"] = "native-text-sandbox:duplicate-cursor-down",
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
