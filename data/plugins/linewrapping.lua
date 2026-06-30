-- mod-version:3 --priority:10
local core = require "core"
local common = require "core.common"
local DocView = require "core.docview"
local Doc = require "core.doc"
local style = require "core.style"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local diagnostic_underlines = select(2, pcall(require, "core.lsp.diagnostic_underlines"))

local function perf_frame_add(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.frame_add then perf.frame_add(key, amount or 1) end
end

local function perf_elapsed(key, start_time)
  if start_time then perf_frame_add(key, (system.get_time() - start_time) * 1000) end
end


-- Core-owned wrapping model/config; this plugin still installs legacy wrappers
-- during the migration to first-class DocView soft wrapping.
local LineWrapping = require "core.linewrapping"

---@class plugins.linewrapping

-- Pure wrapping model helpers now live in core.linewrapping; keep local
-- aliases while this legacy plugin still owns Doc/DocView integration during
-- the core migration.
local get_idx_line_col = LineWrapping.get_idx_line_col
local get_total_wrapped_lines = LineWrapping.get_total_wrapped_lines
local position_key = LineWrapping.position_key
local clear_wrapped_line_end_affinity = LineWrapping.clear_wrapped_line_end_affinity
local set_wrapped_line_end_affinity = LineWrapping.set_wrapped_line_end_affinity
local has_wrapped_line_end_affinity = LineWrapping.has_wrapped_line_end_affinity
local get_idx_visual_end_col = LineWrapping.get_idx_visual_end_col
local get_line_idx_col_count = LineWrapping.get_line_idx_col_count
local get_line_col_from_index_and_x = LineWrapping.get_line_col_from_index_and_x


local open_files = setmetatable({ }, { __mode = "k" })

local old_doc_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo_stack, time)
  local old_lines = #self.lines
  old_doc_insert(self, line, col, text, undo_stack, time)
  if open_files[self] then
    for i,docview in ipairs(open_files[self]) do
      if docview.wrapped_settings then
        local lines = #self.lines - old_lines
        LineWrapping.update_breaks(docview, line, line, lines)
      end
    end
  end
end

local old_doc_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  local old_lines = #self.lines
  old_doc_remove(self, line1, col1, line2, col2, undo_stack, time)
  if open_files[self] then
    for i,docview in ipairs(open_files[self]) do
      if docview.wrapped_settings then
        local lines = #self.lines - old_lines
        LineWrapping.update_breaks(docview, line1, line2, lines)
      end
    end
  end
end

local collect_soft_wrap_row_start_affinity = LineWrapping.collect_soft_wrap_row_start_affinity
local copy_selection_list = LineWrapping.copy_selection_list
local collect_forward_endpoint_affinity = LineWrapping.collect_forward_endpoint_affinity


local old_doc_text_input_by_selection = Doc.text_input_by_selection
function Doc:text_input_by_selection(...)
  local result = old_doc_text_input_by_selection(self, ...)
  if result and result.changed and open_files[self] then
    for _, docview in ipairs(open_files[self]) do
      if docview.wrapped_settings then
        set_wrapped_line_end_affinity(docview, collect_soft_wrap_row_start_affinity(docview))
      end
    end
  end
  return result
end

local old_doc_on_text_transaction = Doc.on_text_transaction
function Doc:on_text_transaction(transaction)
  local result = old_doc_on_text_transaction(self, transaction)
  local ranges = transaction and transaction.changed_ranges
  if ranges and open_files[self] then
    for _, docview in ipairs(open_files[self]) do
      if docview.wrapped_settings then
        if #ranges == 1 then
          local range = ranges[1]
          LineWrapping.update_breaks(docview, range.old_line1, range.old_line2, range.line_delta or 0)
        else
          LineWrapping.reconstruct_breaks(docview, docview.wrapped_settings.font, docview.wrapped_settings.width)
        end
      end
    end
  end
  return result
end

local old_doc_on_close = Doc.on_close
function Doc:on_close()
  old_doc_on_close(self)
  if open_files[self] then open_files[self] = nil end
end

local old_doc_update = DocView.update
function DocView:update()
  old_doc_update(self)
  if self.wrapping_enabled and self.size.x > 0 then
    LineWrapping.update_docview_breaks(self)
  end
end

local old_get_scrollable_line_count = DocView.get_scrollable_line_count
function DocView:get_scrollable_line_count()
  if not self.wrapped_settings then return old_get_scrollable_line_count(self) end
  return get_total_wrapped_lines(self)
end

function DocView:get_scrollable_size()
  return self:get_scrollable_size_for_line_count(self:get_scrollable_line_count())
end

local old_get_h_scrollable_size = DocView.get_h_scrollable_size
function DocView:get_h_scrollable_size(...)
  if self.wrapping_enabled then return 0 end
  return old_get_h_scrollable_size(self, ...)
end

local old_new = DocView.new
function DocView:new(doc)
  old_new(self, doc)
  if not open_files[doc] then open_files[doc] = {} end
  table.insert(open_files[doc], self)
  if config.plugins.linewrapping.enable_by_default then
    self.wrapping_enabled = true
    LineWrapping.update_docview_breaks(self)
  else
    self.wrapping_enabled = false
  end
end

local function with_wrapped_caret_affinity(docview, fn, ...)
  local old = docview.__use_wrapped_caret_affinity
  docview.__use_wrapped_caret_affinity = true
  local results = { pcall(fn, docview, ...) }
  docview.__use_wrapped_caret_affinity = old
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2)
end

local old_scroll_to_line = DocView.scroll_to_line
function DocView:scroll_to_line(...)
  if self.wrapping_enabled then LineWrapping.update_docview_breaks(self) end
  old_scroll_to_line(self, ...)
end

local old_scroll_to_make_visible = DocView.scroll_to_make_visible
function DocView:scroll_to_make_visible(line, col, ...)
  if self.wrapping_enabled then LineWrapping.update_docview_breaks(self) end
  if self.wrapped_settings then
    with_wrapped_caret_affinity(self, old_scroll_to_make_visible, line, col, ...)
    self.scroll.to.x = 0
  else
    old_scroll_to_make_visible(self, line, col, ...)
  end
end

local old_get_visible_line_range = DocView.get_visible_line_range
function DocView:get_visible_line_range()
  if not self.wrapped_settings then return old_get_visible_line_range(self) end
  local x, y, x2, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local minline = get_idx_line_col(self, math.max(1, math.floor(y / lh)))
  local maxline = get_idx_line_col(self, math.min(get_total_wrapped_lines(self), math.floor(y2 / lh) + 1))
  return minline, maxline
end

local old_get_x_offset_col = DocView.get_x_offset_col
function DocView:get_x_offset_col(line, x)
  if not self.wrapped_settings then return old_get_x_offset_col(self, line, x) end
  local idx = get_line_idx_col_count(self, line)
  local target_line, target_col = get_line_col_from_index_and_x(self, idx, x)
  return target_line, target_col
end

-- If line end is true, returns the end of the previous line, in a multi-line break.
local old_get_col_x_offset = DocView.get_col_x_offset
function DocView:get_col_x_offset(line, col, line_end)
  if not self.wrapped_settings then return old_get_col_x_offset(self, line, col) end
  if line_end == nil and self.__use_wrapped_caret_affinity then
    line_end = has_wrapped_line_end_affinity(self, line, col)
  end
  local idx, ncol, count, scol = get_line_idx_col_count(self, line, col, line_end)
  local xoffset, i = (scol ~= 1 and self.wrapped_line_offsets[line] or 0), 1
  local default_font = self:get_font()
  for _, type, text in self.doc.highlighter:each_token(line) do
    if i + #text >= scol then
      if i < scol then
        text = text:sub(scol - i + 1)
        i = scol
      end
      local font = style.syntax_fonts[type] or default_font
      for char in common.utf8_chars(text) do
        if i >= col then
          return xoffset
        end
        xoffset = xoffset + font:get_width(char)
        i = i + #char
      end
    else
     i = i + #text
    end
  end
  return xoffset
end

local old_get_line_screen_position = DocView.get_line_screen_position
function DocView:get_line_screen_position(line, col, line_end)
  if not self.wrapped_settings then return old_get_line_screen_position(self, line, col) end
  if line_end == nil and self.__use_wrapped_caret_affinity then
    line_end = has_wrapped_line_end_affinity(self, line, col)
  end
  local idx, ncol, count = get_line_idx_col_count(self, line, col, line_end)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  return x + gw + (col and self:get_col_x_offset(line, col, line_end) or 0), y + (idx-1) * lh + style.padding.y
end

local old_resolve_screen_position = DocView.resolve_screen_position
function DocView:resolve_screen_position(x, y)
  if not self.wrapped_settings then return old_resolve_screen_position(self, x, y) end
  local ox, oy = self:get_line_screen_position(1)
  local idx = common.clamp(math.floor((y - oy) / self:get_line_height()) + 1, 1, get_total_wrapped_lines(self))
  local line, col, line_end = get_line_col_from_index_and_x(self, idx, x - ox)
  self.wrapped_last_resolved_line_end = line_end and { line, col } or nil
  return line, col
end

local function apply_resolved_line_end_affinity(docview)
  local resolved = docview.wrapped_last_resolved_line_end
  docview.wrapped_last_resolved_line_end = nil
  if not resolved or not docview.wrapped_settings then
    clear_wrapped_line_end_affinity(docview)
    return
  end
  local positions = {}
  for _, line1, col1 in docview.doc:get_selections(false) do
    if line1 == resolved[1] and col1 == resolved[2] then
      positions[position_key(line1, col1)] = true
    end
  end
  set_wrapped_line_end_affinity(docview, positions)
end

local old_on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, ...)
  local result = old_on_mouse_pressed(self, button, ...)
  if self.wrapped_settings and button == "left" then
    apply_resolved_line_end_affinity(self)
  end
  return result
end

local old_on_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(...)
  local selecting = self.mouse_selecting ~= nil
  local result = old_on_mouse_moved(self, ...)
  if self.wrapped_settings and selecting then
    apply_resolved_line_end_affinity(self)
  end
  return result
end

local old_draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(line, x, y)
  if not self.wrapped_settings then return old_draw_line_text(self, line, x, y) end
  local perf_active = core.perf_frame_stats ~= nil
  local perf_start = perf_active and system.get_time()
  local perf_segments, perf_bytes, perf_known_bounds_segments = 0, 0, 0
  local default_font = self:get_font()
  local default_font_height = default_font:get_height()
  local default_ascii_cell_width = default_font:get_width(" ")
  local tx, ty, begin_width = x, y + self:get_line_text_y_offset(), self.wrapped_line_offsets[line]
  local lh = self:get_line_height()
  local idx, _, count = get_line_idx_col_count(self, line)
  local total_offset = 1
  local can_use_known_bounds = renderer.draw_text_known_bounds ~= nil

  local function draw_segment(font, text, sx, sy, color, uses_default_font)
    if text == "" then return sx end
    perf_segments = perf_segments + 1
    perf_bytes = perf_bytes + #text
    if can_use_known_bounds and uses_default_font and not text:find("[\t\128-\255]") then
      perf_known_bounds_segments = perf_known_bounds_segments + 1
      local width = #text * default_ascii_cell_width
      return renderer.draw_text_known_bounds(
        font,
        text,
        sx,
        sy,
        math.floor(sx),
        math.floor(sy),
        math.max(1, math.ceil(width)),
        math.max(1, math.ceil(default_font_height)),
        color
      )
    end
    return renderer.draw_text(font, text, sx, sy, color)
  end

  for _, type, text in self.doc.highlighter:each_token(line) do
    local color = style.syntax[type] or style.syntax["normal"]
    local syntax_font = style.syntax_fonts[type]
    local font = syntax_font or default_font
    local token_offset = 1
    -- Split tokens if we're at the end of the document.
    while text ~= nil and token_offset <= #text do
      local next_line, next_line_start_col = get_idx_line_col(self, idx + 1)
      if next_line ~= line then
        next_line_start_col = #self.doc.lines[line]
      end
      local max_length = next_line_start_col - total_offset
      local rendered_text = text:sub(token_offset, token_offset + max_length - 1)
      tx = draw_segment(font, rendered_text, tx, ty, color, syntax_font == nil)
      total_offset = total_offset + #rendered_text
      if total_offset ~= next_line_start_col or max_length == 0 then break end
      token_offset = token_offset + #rendered_text
      idx = idx + 1
      tx, ty = x + begin_width, ty + lh
    end
  end
  perf_frame_add("linewrapping_draw_line_text_calls", 1)
  perf_frame_add("linewrapping_draw_line_text_rows", count)
  perf_frame_add("linewrapping_draw_line_text_segments", perf_segments)
  perf_frame_add("linewrapping_draw_line_text_bytes", perf_bytes)
  perf_frame_add("linewrapping_draw_line_text_known_bounds_segments", perf_known_bounds_segments)
  perf_elapsed("linewrapping_draw_line_text_ms", perf_start)
  return lh * count
end

local function draw_wrapped_search_match_segment(view, x1, y, x2, h, primary, outline)
  if x2 <= x1 then return end
  local bg, border = view:search_match_style(primary)
  if not outline then
    renderer.draw_rect(x1, y, x2 - x1, h, bg)
    return
  end
  local t = math.max(1, SCALE)
  renderer.draw_rect(x1, y, x2 - x1, t, border)
  renderer.draw_rect(x1, y + h - t, x2 - x1, t, border)
  renderer.draw_rect(x1, y, t, h, border)
  renderer.draw_rect(x2 - t, y, t, h, border)
end

local function get_wrapped_segment_bounds(view, line, col1, col2, idx1, idx2, idx)
  local row_line, row_start_col = get_idx_line_col(view, idx)
  if row_line ~= line then return nil, nil end
  local next_line, next_start_col = get_idx_line_col(view, idx + 1)
  local row_end_col = next_line == line and next_start_col or (#view.doc.lines[line] + 1)
  local x1 = idx == idx1 and view:get_col_x_offset(line, col1, false) or view:get_col_x_offset(line, row_start_col, false)
  local x2 = idx == idx2 and view:get_col_x_offset(line, col2, false) or view:get_col_x_offset(line, row_end_col, true)
  return x1, x2
end

local function draw_wrapped_search_match(view, line, col1, col2, x, y, idx0, lh, primary, outline)
  local idx1 = get_line_idx_col_count(view, line, col1)
  local idx2 = get_line_idx_col_count(view, line, col2)
  for i = idx1, idx2 do
    local x1, x2 = get_wrapped_segment_bounds(view, line, col1, col2, idx1, idx2, i)
    if x1 and x2 then
      draw_wrapped_search_match_segment(view, x + x1, y + (i - idx0) * lh, x + x2, lh, primary, outline)
    end
  end
end

local old_draw_current_line_highlights = DocView.draw_current_line_highlights
function DocView:draw_current_line_highlights(minline, maxline)
  if not self.wrapped_settings then return old_draw_current_line_highlights(self, minline, maxline) end
  if core.active_view ~= self or config.highlight_current_line == false then return end
  local lh = self:get_line_height()
  local hcl = config.highlight_current_line
  for _, line1, col1, line2, col2 in self.doc:get_selections(false) do
    if line1 > maxline then break end
    if line1 >= minline and (hcl ~= "no_selection" or (line1 == line2 and col1 == col2)) then
      local line_end = has_wrapped_line_end_affinity(self, line1, col1)
      local idx = get_line_idx_col_count(self, line1, col1, line_end)
      local _, y = self:get_line_screen_position(line1)
      local first_idx = get_line_idx_col_count(self, line1)
      self:draw_line_highlight(self.position.x, y + lh * (idx - first_idx))
    end
  end
  self:draw_content_left_edge()
end

local old_draw_line_body = DocView.draw_line_body
function DocView:draw_line_body(line, x, y)
  if not self.wrapped_settings then return old_draw_line_body(self, line, x, y) end
  local lh = self:get_line_height()
  local idx0, _, count = get_line_idx_col_count(self, line)
  local highlight_rows
  local hcl = config.highlight_current_line
  if not self.__current_line_highlights_drawn_before_content
  and hcl ~= false and core.active_view == self then
    for lidx, line1, col1, line2, col2 in self.doc:get_selections(false) do
      -- Draw the Current Line Highlight only on the wrapped visual row that
      -- contains the caret, not on every visual row belonging to the same
      -- Document line.
      if line1 == line and (hcl ~= "no_selection" or (line1 == line2 and col1 == col2)) then
        local line_end = has_wrapped_line_end_affinity(self, line, col1)
        local idx = get_line_idx_col_count(self, line, col1, line_end)
        if idx >= idx0 and idx < idx0 + count then
          highlight_rows = highlight_rows or {}
          highlight_rows[idx] = true
        end
      end
    end
  end
  if highlight_rows then
    for i = idx0, idx0 + count - 1 do
      if highlight_rows[i] then
        self:draw_line_highlight(x + self.scroll.x, y + lh * (i - idx0))
      end
    end
  end

  local search_matches
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if line >= line1 and line <= line2 then
      if line1 ~= line then col1 = 1 end
      if line2 ~= line then col2 = #self.doc.lines[line] + 1 end
      if col1 ~= col2 then
        if self.doc:is_search_selection(line1, col1, line, col2) then
          search_matches = search_matches or {}
          search_matches[#search_matches + 1] = { col1, col2, true }
        else
          local idx1 = get_line_idx_col_count(self, line, col1)
          local idx2 = get_line_idx_col_count(self, line, col2)
          for i = idx1, idx2 do
            local x1, x2 = get_wrapped_segment_bounds(self, line, col1, col2, idx1, idx2, i)
            if x1 and x2 and x2 > x1 then
              renderer.draw_rect(x + x1, y + (i - idx0) * lh, x2 - x1, lh, style.selection)
            end
          end
        end
      end
    end
  end
  for _, match in ipairs(search_matches or {}) do
    draw_wrapped_search_match(self, line, match[1], match[2], x, y, idx0, lh, match[3], false)
  end

  -- draw line's text
  local line_height = self:draw_line_text(line, x, y)

  for _, match in ipairs(search_matches or {}) do
    draw_wrapped_search_match(self, line, match[1], match[2], x, y, idx0, lh, match[3], true)
  end

  local underline_module = DocView.__lsp_diagnostic_underlines_module or diagnostic_underlines
  if underline_module and underline_module.draw_line then
    underline_module.draw_line(self, line, x, y)
  end
  self:draw_line_hint(line, x, y + lh * (count - 1))

  return line_height
end

local old_draw_overlay = DocView.draw_overlay
function DocView:draw_overlay(...)
  if not self.wrapped_settings then return old_draw_overlay(self, ...) end
  LineWrapping.draw_guide(self)
  return with_wrapped_caret_affinity(self, old_draw_overlay, ...)
end

local old_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  local _, _, count = get_line_idx_col_count(self, line)
  return (old_draw_line_gutter(self, line, x, y, width) or lh) * count
end

local function wrapping_active_for_doc(doc)
  return core.active_view and core.active_view.doc == doc and core.active_view.wrapped_settings
end

local old_translate_end_of_line = translate.end_of_line

local function wrapped_end_of_line_position(docview, doc, line, col)
  local line_end = has_wrapped_line_end_affinity(docview, line, col)
  local idx = get_line_idx_col_count(docview, line, col, line_end)
  local nline, ncol = get_idx_line_col(docview, idx + 1)
  if nline ~= line then
    local end_line, end_col = old_translate_end_of_line(doc, line, col)
    end_line, end_col = doc:sanitize_position(end_line, end_col)
    return end_line, end_col, false
  end
  if line_end and col == ncol then
    local end_line, end_col = old_translate_end_of_line(doc, line, col)
    end_line, end_col = doc:sanitize_position(end_line, end_col)
    return end_line, end_col, false
  end
  return line, ncol, true
end

function translate.end_of_line(doc, line, col)
  if not wrapping_active_for_doc(doc) then return old_translate_end_of_line(doc, line, col) end
  local nline, ncol = wrapped_end_of_line_position(core.active_view, doc, line, col)
  return nline, ncol
end

local old_translate_start_of_line = translate.start_of_line
function translate.start_of_line(doc, line, col)
  if not wrapping_active_for_doc(doc) then return old_translate_start_of_line(doc, line, col) end
  local line_end = has_wrapped_line_end_affinity(core.active_view, line, col)
  local _, _, _, scol = get_line_idx_col_count(core.active_view, line, col, line_end)
  if col == scol then return old_translate_start_of_line(doc, line, col) end
  return line, scol
end

local old_translate_start_of_indentation = translate.start_of_indentation
function translate.start_of_indentation(doc, line, col)
  if not wrapping_active_for_doc(doc) then return old_translate_start_of_indentation(doc, line, col) end
  local line_end = has_wrapped_line_end_affinity(core.active_view, line, col)
  local _, _, _, scol = get_line_idx_col_count(core.active_view, line, col, line_end)
  if col == scol then return old_translate_start_of_indentation(doc, line, col) end
  if scol ~= 1 then return line, scol end
  return old_translate_start_of_indentation(doc, line, col)
end

local function wrapped_visual_line_position(dv, line, col, idx_delta)
  local line_end = has_wrapped_line_end_affinity(dv, line, col)
  local idx = get_line_idx_col_count(dv, line, col, line_end)
  return get_line_col_from_index_and_x(dv, idx + idx_delta, dv:get_col_x_offset(line, col, line_end))
end

local old_previous_line = DocView.translate.previous_line
function DocView.translate.previous_line(doc, line, col, dv)
  if not dv.wrapped_settings then return old_previous_line(doc, line, col, dv) end
  local nline, ncol = wrapped_visual_line_position(dv, line, col, -1)
  return nline, ncol
end

local old_next_line = DocView.translate.next_line
function DocView.translate.next_line(doc, line, col, dv)
  if not dv.wrapped_settings then return old_next_line(doc, line, col, dv) end
  local nline, ncol = wrapped_visual_line_position(dv, line, col, 1)
  return nline, ncol
end

local old_navigation_commands = {}
for _, name in ipairs({
  "doc:move-to-previous-line",
  "doc:move-to-next-line",
  "doc:select-to-previous-line",
  "doc:select-to-next-line",
  "doc:move-to-next-char",
  "doc:select-to-next-char",
  "doc:move-to-next-word-end",
  "doc:select-to-next-word-end",
  "doc:move-to-end-of-word",
  "doc:select-to-end-of-word",
  "doc:move-to-next-block-end",
  "doc:select-to-next-block-end",
  "doc:move-to-end-of-doc",
  "doc:select-to-end-of-doc",
  "doc:move-to-start-of-indentation",
  "doc:select-to-start-of-indentation",
  "doc:move-to-end-of-line",
  "doc:select-to-end-of-line",
  "doc:set-cursor",
  "doc:set-cursor-word",
  "doc:set-cursor-line",
}) do
  old_navigation_commands[name] = command.map[name]
end

local function perform_old_navigation(name, dv, ...)
  local old = old_navigation_commands[name]
  if old and old.perform then return old.perform(dv, ...) end
end

local function set_primary_selection(doc)
  -- Doesn't work on Windows, so avoid spending time getting the text.
  if PLATFORM ~= "Windows" then
    system.set_primary_selection(doc:get_selection_text())
  end
end

local function add_line_end_affinity(positions, line, col, line_end)
  if line_end then positions[position_key(line, col)] = true end
end

local function wrapped_move_to(dv, name, move_fn, ...)
  if not dv.wrapped_settings then return perform_old_navigation(name, dv) end
  local doc = dv.doc
  local selections = {}
  local affinity_positions = {}
  for _, line1, col1 in doc:get_selections(false) do
    local line, col, line_end = move_fn(doc, line1, col1, ...)
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    add_line_end_affinity(affinity_positions, line, col, line_end)
  end
  doc:set_selection_list(selections, doc.last_selection, { merge_cursors = true })
  set_wrapped_line_end_affinity(dv, affinity_positions)
end

local function wrapped_select_to(dv, name, move_fn, ...)
  if not dv.wrapped_settings then return perform_old_navigation(name, dv) end
  local doc = dv.doc
  local selections = {}
  local affinity_positions = {}
  for _, line1, col1, line2, col2 in doc:get_selections(false) do
    local line, col, line_end = move_fn(doc, line1, col1, ...)
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = line2
    selections[#selections + 1] = col2
    add_line_end_affinity(affinity_positions, line, col, line_end)
  end
  doc:set_selection_list(selections, doc.last_selection, { merge_cursors = true })
  set_wrapped_line_end_affinity(dv, affinity_positions)
  set_primary_selection(doc)
end

local function wrapped_forward_endpoint_command(dv, name, ...)
  if not dv.wrapped_settings then return perform_old_navigation(name, dv, ...) end
  local old_selections = copy_selection_list(dv.doc.selections)
  local result = perform_old_navigation(name, dv, ...)
  set_wrapped_line_end_affinity(dv, collect_forward_endpoint_affinity(dv, old_selections))
  return result
end

local function move_to_wrapped_end_of_line(doc, line, col, dv)
  return wrapped_end_of_line_position(dv, doc, line, col)
end

local function move_to_wrapped_previous_line(doc, line, col, dv)
  return wrapped_visual_line_position(dv, line, col, -1)
end

local function move_to_wrapped_next_line(doc, line, col, dv)
  return wrapped_visual_line_position(dv, line, col, 1)
end

command.add("core.docview", {
  ["doc:move-to-previous-line"] = function(dv)
    return wrapped_move_to(dv, "doc:move-to-previous-line", move_to_wrapped_previous_line, dv)
  end,
  ["doc:move-to-next-line"] = function(dv)
    return wrapped_move_to(dv, "doc:move-to-next-line", move_to_wrapped_next_line, dv)
  end,
  ["doc:select-to-previous-line"] = function(dv)
    return wrapped_select_to(dv, "doc:select-to-previous-line", move_to_wrapped_previous_line, dv)
  end,
  ["doc:select-to-next-line"] = function(dv)
    return wrapped_select_to(dv, "doc:select-to-next-line", move_to_wrapped_next_line, dv)
  end,
  ["doc:move-to-next-char"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:move-to-next-char")
  end,
  ["doc:select-to-next-char"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:select-to-next-char")
  end,
  ["doc:move-to-next-word-end"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:move-to-next-word-end")
  end,
  ["doc:select-to-next-word-end"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:select-to-next-word-end")
  end,
  ["doc:move-to-end-of-word"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:move-to-end-of-word")
  end,
  ["doc:select-to-end-of-word"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:select-to-end-of-word")
  end,
  ["doc:move-to-next-block-end"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:move-to-next-block-end")
  end,
  ["doc:select-to-next-block-end"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:select-to-next-block-end")
  end,
  ["doc:move-to-end-of-doc"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:move-to-end-of-doc")
  end,
  ["doc:select-to-end-of-doc"] = function(dv)
    return wrapped_forward_endpoint_command(dv, "doc:select-to-end-of-doc")
  end,
  ["doc:move-to-start-of-indentation"] = function(dv)
    return wrapped_move_to(dv, "doc:move-to-start-of-indentation", translate.start_of_indentation)
  end,
  ["doc:select-to-start-of-indentation"] = function(dv)
    return wrapped_select_to(dv, "doc:select-to-start-of-indentation", translate.start_of_indentation)
  end,
  ["doc:move-to-end-of-line"] = function(dv)
    return wrapped_move_to(dv, "doc:move-to-end-of-line", move_to_wrapped_end_of_line, dv)
  end,
  ["doc:select-to-end-of-line"] = function(dv)
    return wrapped_select_to(dv, "doc:select-to-end-of-line", move_to_wrapped_end_of_line, dv)
  end,
  ["doc:set-cursor"] = function(dv, x, y)
    local result = perform_old_navigation("doc:set-cursor", dv, x, y)
    if dv.wrapped_settings then apply_resolved_line_end_affinity(dv) end
    return result
  end,
  ["doc:set-cursor-word"] = function(dv, x, y)
    local result = perform_old_navigation("doc:set-cursor-word", dv, x, y)
    if dv.wrapped_settings then apply_resolved_line_end_affinity(dv) end
    return result
  end,
  ["doc:set-cursor-line"] = function(dv, x, y, clicks)
    local result = perform_old_navigation("doc:set-cursor-line", dv, x, y, clicks)
    if dv.wrapped_settings then apply_resolved_line_end_affinity(dv) end
    return result
  end,
})

command.add(nil, {
  ["line-wrapping:toggle"] = function()
    if core.active_view and core.active_view.doc then
      if core.active_view.wrapped_settings then
        core.active_view.wrapping_enabled = false
        LineWrapping.reconstruct_breaks(core.active_view, core.active_view:get_font(), math.huge)
      else
        core.active_view.wrapping_enabled = true
        LineWrapping.update_docview_breaks(core.active_view)
      end
    end
  end
})

keymap.add {
  ["f10"] = "line-wrapping:toggle",
}

return LineWrapping
