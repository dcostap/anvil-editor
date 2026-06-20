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


---Configuration options for `linewrapping` plugin.
---@class config.plugins.linewrapping
---The type of wrapping to perform. Can be "letter" or "word".
---@field mode "letter" | "word"
---If nil, uses the DocView's size, otherwise, uses this exact width. Can be a function.
---@field width_override? number | function():number
---Whether or not to draw a guide
---@field guide boolean
---Color used for the wrapping guide. Defaults to the whitespace indicator color.
---@field guide_color? renderer.color
---Whether or not we should indent ourselves like the first line of a wrapped block.
---@field indent boolean
---Extra visual spaces added before wrapped continuation lines.
---@field wrapping_indent integer
---Whether or not to enable wrapping by default when opening files.
---@field enable_by_default boolean
---Requires tokenization
---@field require_tokenization boolean
config.plugins.linewrapping.config_spec = {
    name = "Line Wrapping",
    {
      label = "Mode",
      description = "The type of wrapping to perform.",
      path = "mode",
      type = "selection",
      default = "letter",
      values = {
        {"Letters", "letter"},
        {"Words", "word"}
      }
    },
    {
      label = "Guide",
      description = "Whether or not to draw a guide.",
      path = "guide",
      type = "toggle",
      default = true
    },
    {
      label = "Indent",
      description = "Whether or not to follow the indentation of wrapped line.",
      path = "indent",
      type = "toggle",
      default = true
    },
    {
      label = "Wrapping Indent",
      description = "Extra visual spaces added before wrapped continuation lines.",
      path = "wrapping_indent",
      type = "number",
      default = 0
    },
    {
      label = "Enable by Default",
      description = "Whether or not to enable wrapping by default when opening files.",
      path = "enable_by_default",
      type = "toggle",
      default = false
    },
    {
      label = "Require Tokenization",
      description = "Use tokenization when applying wrapping.",
      path = "require_tokenization",
      type = "toggle",
      default = false
    }
  }

---@class plugins.linewrapping
local LineWrapping = {}

-- Optimzation function. The tokenizer is relatively slow (at present), and
-- so if we don't need to run it, should be run sparingly.
local function spew_tokens(doc, line) if line < math.huge then return math.huge, "normal", doc:get_utf8_line(line) end end

local function get_extra_wrapping_indent_width(default_font)
  local spaces = tonumber(config.plugins.linewrapping.wrapping_indent) or 0
  if spaces <= 0 then return 0 end
  return default_font:get_width(string.rep(" ", spaces))
end

local function get_tokens(doc, line)
  if config.plugins.linewrapping.require_tokenization then
    return doc.highlighter:each_token(line)
  end
  return spew_tokens, doc, line
end

-- Computes the breaks for a given line, width and mode. Returns a list of columns
-- at which the line should be broken.
function LineWrapping.compute_line_breaks(doc, default_font, line, width, mode)
  local xoffset, last_i, i, last_space, last_width, begin_width = 0, 1, 1, nil, 0, 0
  local splits = { 1 }
  for idx, type, text in get_tokens(doc, line) do
    local font = style.syntax_fonts[type] or default_font
    if idx == 1 or idx == math.huge and config.plugins.linewrapping.indent then
      local _, indent_end = text:find("^%s+")
      if indent_end then begin_width = font:get_width(text:sub(1, indent_end)) end
      begin_width = begin_width + get_extra_wrapping_indent_width(default_font)
    end
    local w = font:get_width(text)
    if xoffset + w > width then
      for char in common.utf8_chars(text) do
        w = font:get_width(char)
        xoffset = xoffset + w
        if xoffset > width then
          if mode == "word" and last_space then
            table.insert(splits, last_space + 1)
            xoffset = w + begin_width + (xoffset - last_width)
          else
            table.insert(splits, i)
            xoffset = w + begin_width
          end
          last_space = nil
        elseif char == ' ' then
          last_space = i
          last_width = xoffset
        end
        i = i + #char
      end
    else
      xoffset = xoffset + w
      i = i + #text
    end
  end
  return splits, begin_width
end

-- breaks are held in a single table that contains n*2 elements, where n is the amount of line breaks.
-- each element represents line and column of the break. line_offset will check from the specified line
-- if the first line has not changed breaks, it will stop there.
function LineWrapping.reconstruct_breaks(docview, default_font, width, line_offset)
  if width ~= math.huge then
    local doc = docview.doc
    -- two elements per wrapped line; first maps to original line number, second to column number.
    docview.wrapped_lines = { }
    -- one element per actual line; maps to the first index of in wrapped_lines for this line
    docview.wrapped_line_to_idx = { }
    -- one element per actual line; gives the indent width for the acutal line
    docview.wrapped_line_offsets = { }
    docview.wrapped_settings = { ["width"] = width, ["font"] = default_font }
    for i = line_offset or 1, #doc.lines do
      local breaks, offset = LineWrapping.compute_line_breaks(doc, default_font, i, width, config.plugins.linewrapping.mode)
      table.insert(docview.wrapped_line_offsets, offset)
      for k, col in ipairs(breaks) do
        table.insert(docview.wrapped_lines, i)
        table.insert(docview.wrapped_lines, col)
      end
    end
    -- list of indices for wrapped_lines, that are based on original line number
    -- holds the index to the first in the wrapped_lines list.
    local last_wrap = nil
    for i = 1, #docview.wrapped_lines, 2 do
      if not last_wrap or last_wrap ~= docview.wrapped_lines[i] then
        table.insert(docview.wrapped_line_to_idx, (i + 1) / 2)
        last_wrap = docview.wrapped_lines[i]
      end
    end
  else
    docview.wrapped_lines = nil
    docview.wrapped_line_to_idx = nil
    docview.wrapped_line_offsets = nil
    docview.wrapped_settings = nil
  end
end

-- When we have an insertion or deletion, we have four sections of text.
-- 1. The unaffected section, located prior to the cursor. This is completely ignored.
-- 2. The beginning of the affected line prior to the insertion or deletion. Begins on column 1 of the selection.
-- 3. The removed/pasted lines.
-- 4. Every line after the modification, begins one line after the selection in the initial document.
function LineWrapping.update_breaks(docview, old_line1, old_line2, net_lines)
  -- Step 1: Determine the index for the line for #2.
  local old_idx1 = docview.wrapped_line_to_idx[old_line1] or 1
  -- Step 2: Determine the index of the line for #4.
  local old_idx2 = (docview.wrapped_line_to_idx[old_line2 + 1] or ((#docview.wrapped_lines / 2) + 1)) - 1
  -- Step 3: Remove all old breaks for the old lines from the table, and all old widths from wrapped_line_offsets.
  local offset = (old_idx1  - 1) * 2 + 1
  for i = old_idx1, old_idx2 do
    table.remove(docview.wrapped_lines, offset)
    table.remove(docview.wrapped_lines, offset)
  end
  for i = old_line1, old_line2 do
    table.remove(docview.wrapped_line_offsets, old_line1)
  end
  -- Step 4: Shift the line number of wrapped_lines past #4 by the amount of inserted/deleted lines.
  if net_lines ~= 0 then
    for i = offset, #docview.wrapped_lines, 2 do
      docview.wrapped_lines[i] = docview.wrapped_lines[i] + net_lines
    end
  end
  -- Step 5: Compute the breaks and offsets for the lines for #2 and #3. Insert them into the table.
  local new_line1 = old_line1
  local new_line2 = old_line2 + net_lines
  for line = new_line1, new_line2 do
    local breaks, begin_width = LineWrapping.compute_line_breaks(docview.doc, docview.wrapped_settings.font, line, docview.wrapped_settings.width, config.plugins.linewrapping.mode)
    table.insert(docview.wrapped_line_offsets, line, begin_width)
    for i,b in ipairs(breaks) do
      table.insert(docview.wrapped_lines, offset, b)
      table.insert(docview.wrapped_lines, offset, line)
      offset = offset + 2
    end
  end
  -- Step 6: Recompute the wrapped_line_to_idx cache from #2.
  local line = old_line1
  offset = (old_idx1  - 1) * 2 + 1
  while offset < #docview.wrapped_lines do
    if docview.wrapped_lines[offset + 1] == 1 then
      docview.wrapped_line_to_idx[line] = ((offset - 1) / 2) + 1
      line = line + 1
    end
    offset = offset + 2
  end
  while line <= #docview.wrapped_line_to_idx do
    table.remove(docview.wrapped_line_to_idx)
  end
end

local function guide_color()
  return config.plugins.linewrapping.guide_color or style.line_wrapping_guide
end

-- Draws a guide if applicable to show where wrapping is occurring.
function LineWrapping.draw_guide(docview)
  if config.plugins.linewrapping.guide and docview.wrapped_settings.width ~= math.huge then
    local x = docview:get_content_offset()
    local gw = docview:get_gutter_width()
    renderer.draw_rect(
      x + gw + docview.wrapped_settings.width,
      docview.position.y,
      math.max(1, math.floor(SCALE)),
      docview.size.y,
      guide_color()
    )
  end
end

function LineWrapping.update_docview_breaks(docview)
  local scrollbar_width = docview.v_scrollbar.expanded_size or style.expanded_scrollbar_size
  local width = (type(config.plugins.linewrapping.width_override) == "function" and config.plugins.linewrapping.width_override(docview))
    or config.plugins.linewrapping.width_override or (docview.size.x - docview:get_gutter_width() - scrollbar_width)
  if (not docview.wrapped_settings or docview.wrapped_settings.width == nil or width ~= docview.wrapped_settings.width) then
    docview.scroll.to.x = 0
    LineWrapping.reconstruct_breaks(docview, docview:get_font(), width)
  end
end

local function get_idx_line_col(docview, idx)
  local doc = docview.doc
  if not docview.wrapped_settings then
    if idx > #doc.lines then return #doc.lines, #doc.lines[#doc.lines] + 1 end
    return idx, 1
  end
  if idx < 1 then return 1, 1 end
  local offset = (idx - 1) * 2 + 1
  if offset > #docview.wrapped_lines then return #doc.lines, #doc.lines[#doc.lines] + 1 end
  return docview.wrapped_lines[offset], docview.wrapped_lines[offset + 1]
end

local function get_idx_line_length(docview, idx)
  local doc = docview.doc
  if not docview.wrapped_settings then
    if idx > #doc.lines then return #doc.lines[#doc.lines] + 1 end
    return #doc.lines[idx]
  end
  local offset = (idx - 1) * 2 + 1
  local start = docview.wrapped_lines[offset + 1]
  if docview.wrapped_lines[offset + 2] and docview.wrapped_lines[offset + 2] == docview.wrapped_lines[offset] then
    return docview.wrapped_lines[offset + 3] - docview.wrapped_lines[offset + 1]
  else
    return #doc.lines[docview.wrapped_lines[offset]] - docview.wrapped_lines[offset + 1] + 1
  end
end

local function get_total_wrapped_lines(docview)
  if not docview.wrapped_settings then return docview.doc and #docview.doc.lines end
  return #docview.wrapped_lines / 2
end

-- If line end, gives the end of an index line, rather than the first character of the next line.
local function get_line_idx_col_count(docview, line, col, line_end, ndoc)
  local doc = docview.doc
  if not docview.wrapped_settings then return common.clamp(line, 1, #doc.lines), col, 1, 1 end
  if line > #doc.lines then return get_line_idx_col_count(docview, #doc.lines, #doc.lines[#doc.lines] + 1) end
  line = math.max(line, 1)
  local idx = docview.wrapped_line_to_idx[line] or 1
  local ncol, scol = 1, 1
  if col then
    local i = idx + 1
    while line == docview.wrapped_lines[(i - 1) * 2 + 1] and col >= docview.wrapped_lines[(i - 1) * 2 + 2] do
      local nscol = docview.wrapped_lines[(i - 1) * 2 + 2]
      if line_end and col == nscol then
        break
      end
      scol = nscol
      i = i + 1
      idx = idx + 1
    end
    ncol = (col - scol) + 1
  end
  local count = (docview.wrapped_line_to_idx[line + 1] or (get_total_wrapped_lines(docview) + 1)) - (docview.wrapped_line_to_idx[line] or get_total_wrapped_lines(docview))
  return idx, ncol, count, scol
end

local function get_line_col_from_index_and_x(docview, idx, x)
  local doc = docview.doc
  local line, col = get_idx_line_col(docview, idx)
  if idx < 1 then return 1, 1 end
  local xoffset, last_i, i = (col ~= 1 and docview.wrapped_line_offsets[line] or 0), col, 1
  if x < xoffset then return line, col end
  local default_font = docview:get_font()
  for _, type, text in doc.highlighter:each_token(line) do
    local font, w = style.syntax_fonts[type] or default_font, 0
    for char in common.utf8_chars(text) do
      if i >= col then
        if xoffset >= x then
          return line, (xoffset - x > (w / 2) and last_i or i)
        end
        w = font:get_width(char)
        xoffset = xoffset + w
      end
      last_i = i
      i = i + #char
    end
  end
  return line, #doc.lines[line]
end


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
  if self.wrapped_settings and self.size.x > 0 then
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

local old_scroll_to_line = DocView.scroll_to_line
function DocView:scroll_to_line(...)
  if self.wrapping_enabled then LineWrapping.update_docview_breaks(self) end
  old_scroll_to_line(self, ...)
end

local old_scroll_to_make_visible = DocView.scroll_to_make_visible
function DocView:scroll_to_make_visible(line, col, ...)
  if self.wrapping_enabled then LineWrapping.update_docview_breaks(self) end
  old_scroll_to_make_visible(self, line, col, ...)
  if self.wrapped_settings then self.scroll.to.x = 0 end
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
  return get_line_col_from_index_and_x(self, idx, x)
end

-- If line end is true, returns the end of the previous line, in a multi-line break.
local old_get_col_x_offset = DocView.get_col_x_offset
function DocView:get_col_x_offset(line, col, line_end)
  if not self.wrapped_settings then return old_get_col_x_offset(self, line, col) end
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
function DocView:get_line_screen_position(line, col)
  if not self.wrapped_settings then return old_get_line_screen_position(self, line, col) end
  local idx, ncol, count = get_line_idx_col_count(self, line, col)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  return x + gw + (col and self:get_col_x_offset(line, col) or 0), y + (idx-1) * lh + style.padding.y
end

local old_resolve_screen_position = DocView.resolve_screen_position
function DocView:resolve_screen_position(x, y)
  if not self.wrapped_settings then return old_resolve_screen_position(self, x, y) end
  local ox, oy = self:get_line_screen_position(1)
  local idx = common.clamp(math.floor((y - oy) / self:get_line_height()) + 1, 1, get_total_wrapped_lines(self))
  return get_line_col_from_index_and_x(self, idx, x - ox)
end

local old_draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(line, x, y)
  if not self.wrapped_settings then return old_draw_line_text(self, line, x, y) end
  local default_font = self:get_font()
  local tx, ty, begin_width = x, y + self:get_line_text_y_offset(), self.wrapped_line_offsets[line]
  local lh = self:get_line_height()
  local idx, _, count = get_line_idx_col_count(self, line)
  local total_offset = 1
  for _, type, text in self.doc.highlighter:each_token(line) do
    local color = style.syntax[type] or style.syntax["normal"]
    local font = style.syntax_fonts[type] or default_font
    local token_offset = 1
    -- Split tokens if we're at the end of the document.
    while text ~= nil and token_offset <= #text do
      local next_line, next_line_start_col = get_idx_line_col(self, idx + 1)
      if next_line ~= line then
        next_line_start_col = #self.doc.lines[line]
      end
      local max_length = next_line_start_col - total_offset
      local rendered_text = text:sub(token_offset, token_offset + max_length - 1)
      tx = renderer.draw_text(font, rendered_text, tx, ty, color)
      total_offset = total_offset + #rendered_text
      if total_offset ~= next_line_start_col or max_length == 0 then break end
      token_offset = token_offset + #rendered_text
      idx = idx + 1
      tx, ty = x + begin_width, ty + lh
    end
  end
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
  local x1 = idx == idx1 and view:get_col_x_offset(line, col1) or view:get_col_x_offset(line, row_start_col)
  local x2 = idx == idx2 and view:get_col_x_offset(line, col2) or view:get_col_x_offset(line, row_end_col, true)
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
      local idx = get_line_idx_col_count(self, line1, col1)
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
        local idx = get_line_idx_col_count(self, line, col1)
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

  self:draw_line_hint(line, x, y + lh * (count - 1))

  return line_height
end

local old_draw = DocView.draw
function DocView:draw()
  old_draw(self)
  if self.wrapped_settings then
    LineWrapping.draw_guide(self)
  end
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
function translate.end_of_line(doc, line, col)
  if not wrapping_active_for_doc(doc) then return old_translate_end_of_line(doc, line, col) end
  local idx, ncol = get_line_idx_col_count(core.active_view, line, col)
  local nline, ncol2 = get_idx_line_col(core.active_view, idx + 1)
  if nline ~= line then return old_translate_end_of_line(doc, line, col) end
  local wrapped_end_col = ncol2 - 1
  if col == wrapped_end_col then return old_translate_end_of_line(doc, line, col) end
  return line, wrapped_end_col
end

local old_translate_start_of_line = translate.start_of_line
function translate.start_of_line(doc, line, col)
  if not wrapping_active_for_doc(doc) then return old_translate_start_of_line(doc, line, col) end
  local _, _, _, scol = get_line_idx_col_count(core.active_view, line, col)
  if col == scol then return old_translate_start_of_line(doc, line, col) end
  return line, scol
end

local old_translate_start_of_indentation = translate.start_of_indentation
function translate.start_of_indentation(doc, line, col)
  if not wrapping_active_for_doc(doc) then return old_translate_start_of_indentation(doc, line, col) end
  local _, _, _, scol = get_line_idx_col_count(core.active_view, line, col)
  if col == scol then return old_translate_start_of_indentation(doc, line, col) end
  if scol ~= 1 then return line, scol end
  return old_translate_start_of_indentation(doc, line, col)
end

local old_previous_line = DocView.translate.previous_line
function DocView.translate.previous_line(doc, line, col, dv)
  if not dv.wrapped_settings then return old_previous_line(doc, line, col, dv) end
  local idx, ncol = get_line_idx_col_count(dv, line, col)
  return get_line_col_from_index_and_x(dv, idx - 1, dv:get_col_x_offset(line, col))
end

local old_next_line = DocView.translate.next_line
function DocView.translate.next_line(doc, line, col, dv)
  if not dv.wrapped_settings then return old_next_line(doc, line, col, dv) end
  local idx, ncol = get_line_idx_col_count(dv, line, col)
  return get_line_col_from_index_and_x(dv, idx + 1, dv:get_col_x_offset(line, col))
end

local old_navigation_commands = {}
for _, name in ipairs({
  "doc:move-to-previous-line",
  "doc:move-to-next-line",
  "doc:select-to-previous-line",
  "doc:select-to-next-line",
  "doc:move-to-start-of-indentation",
  "doc:move-to-end-of-line",
}) do
  old_navigation_commands[name] = command.map[name]
end

local function perform_old_navigation(name, dv)
  local old = old_navigation_commands[name]
  if old and old.perform then return old.perform(dv) end
end

local function set_primary_selection(doc)
  -- Doesn't work on Windows, so avoid spending time getting the text.
  if PLATFORM ~= "Windows" then
    system.set_primary_selection(doc:get_selection_text())
  end
end

local function wrapped_move_to(dv, name, move_fn, ...)
  if not dv.wrapped_settings then return perform_old_navigation(name, dv) end
  dv.doc:move_to(move_fn, ...)
end

local function wrapped_select_to(dv, name, move_fn, ...)
  if not dv.wrapped_settings then return perform_old_navigation(name, dv) end
  dv.doc:select_to(move_fn, ...)
  set_primary_selection(dv.doc)
end

command.add("core.docview", {
  ["doc:move-to-previous-line"] = function(dv)
    return wrapped_move_to(dv, "doc:move-to-previous-line", DocView.translate.previous_line, dv)
  end,
  ["doc:move-to-next-line"] = function(dv)
    return wrapped_move_to(dv, "doc:move-to-next-line", DocView.translate.next_line, dv)
  end,
  ["doc:select-to-previous-line"] = function(dv)
    return wrapped_select_to(dv, "doc:select-to-previous-line", DocView.translate.previous_line, dv)
  end,
  ["doc:select-to-next-line"] = function(dv)
    return wrapped_select_to(dv, "doc:select-to-next-line", DocView.translate.next_line, dv)
  end,
  ["doc:move-to-start-of-indentation"] = function(dv)
    return wrapped_move_to(dv, "doc:move-to-start-of-indentation", translate.start_of_indentation)
  end,
  ["doc:move-to-end-of-line"] = function(dv)
    return wrapped_move_to(dv, "doc:move-to-end-of-line", translate.end_of_line)
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
