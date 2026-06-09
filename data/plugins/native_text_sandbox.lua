-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local native_text = require "native_text"

local TREE_SITTER_REPARSE_DELAY = 0.25

local NativeTextSandboxView = View:extend()

local highlight_priority = {
  keyword = 100,
  string = 90,
  comment = 90,
  number = 80,
  type = 75,
  ["function"] = 70,
  property = 65,
  label = 60,
  variable = 10,
}

local function tree_sitter_language_for_filename(filename)
  if not filename then return nil end
  local ext = filename:match("%.([^%.\\/]*)$")
  if ext then ext = ext:lower() end
  if ext == "c" or ext == "h" then return "c" end
  return nil
end

function NativeTextSandboxView:__tostring() return "NativeTextSandboxView" end

NativeTextSandboxView.context = "workspace"

function NativeTextSandboxView:new(text, filename)
  NativeTextSandboxView.super.new(self)
  self.buffer = native_text.new_buffer(text or "Native text sandbox\n\nType here. This view is backed by src/text Buffer/Editor userdata.")
  if filename then
    local ok = self.buffer:load_file(filename)
    if not ok then core.error("Failed to open native Buffer: %s", filename) end
  end
  local language = tree_sitter_language_for_filename(filename)
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
  table.sort(spans, function(a, b)
    if a.start_offset ~= b.start_offset then return a.start_offset < b.start_offset end
    if a.end_offset ~= b.end_offset then return a.end_offset > b.end_offset end
    return (highlight_priority[a.capture] or 0) > (highlight_priority[b.capture] or 0)
  end)

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
      local capture = span.capture and span.capture:match("^[^%.]+") or "normal"
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
  local offset = self.buffer:line_col_to_offset(line, col)
  if offset then self.editor:set_cursor(offset) end
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

local function open_native_text_file(filename)
  if not filename or filename == "" then return end
  core.root_panel:get_active_node_default():add_view(NativeTextSandboxView(nil, filename))
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
  ["native-text-sandbox:backspace"] = with_active_native_view(function(view) view.editor:backspace() end, true),
  ["native-text-sandbox:delete"] = with_active_native_view(function(view) view.editor:delete() end, true),
  ["native-text-sandbox:left"] = with_active_native_view(function(view) view.editor:left(false) end),
  ["native-text-sandbox:right"] = with_active_native_view(function(view) view.editor:right(false) end),
  ["native-text-sandbox:up"] = with_active_native_view(function(view) view.editor:line_up(false) end),
  ["native-text-sandbox:down"] = with_active_native_view(function(view) view.editor:line_down(false) end),
  ["native-text-sandbox:select-left"] = with_active_native_view(function(view) view.editor:left(true) end),
  ["native-text-sandbox:select-right"] = with_active_native_view(function(view) view.editor:right(true) end),
  ["native-text-sandbox:select-up"] = with_active_native_view(function(view) view.editor:line_up(true) end),
  ["native-text-sandbox:select-down"] = with_active_native_view(function(view) view.editor:line_down(true) end),
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
    if not view.buffer:save_file() then core.error("Failed to save native Buffer") end
  end),
  ["native-text-sandbox:duplicate-cursor-up"] = with_active_native_view(function(view) view.editor:dup_cursor_up() end),
  ["native-text-sandbox:duplicate-cursor-down"] = with_active_native_view(function(view) view.editor:dup_cursor_down() end),
})

keymap.add {
  ["return"] = "native-text-sandbox:newline",
  ["backspace"] = "native-text-sandbox:backspace",
  ["delete"] = "native-text-sandbox:delete",
  ["left"] = "native-text-sandbox:left",
  ["right"] = "native-text-sandbox:right",
  ["up"] = "native-text-sandbox:up",
  ["down"] = "native-text-sandbox:down",
  ["shift+left"] = "native-text-sandbox:select-left",
  ["shift+right"] = "native-text-sandbox:select-right",
  ["shift+up"] = "native-text-sandbox:select-up",
  ["shift+down"] = "native-text-sandbox:select-down",
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
  ["ctrl+shift+up"] = "native-text-sandbox:duplicate-cursor-up",
  ["ctrl+shift+down"] = "native-text-sandbox:duplicate-cursor-down",
}

return NativeTextSandboxView
