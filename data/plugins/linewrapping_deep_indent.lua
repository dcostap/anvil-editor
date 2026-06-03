-- mod-version:3 priority:201
-- VSCode-like deepIndent continuation indentation for Anvil's linewrapping plugin.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"
local LineWrapping = require "plugins.linewrapping"

config.plugins.linewrapping = config.plugins.linewrapping or {}
config.plugins.linewrapping.wrapping_indent = config.plugins.linewrapping.wrapping_indent or "deepIndent"

local function get_tokens(doc, line)
  if config.plugins.linewrapping.require_tokenization then
    return doc.highlighter:each_token(line)
  end
  return function(d, l)
    if l < math.huge then return math.huge, "normal", d:get_utf8_line(l) end
  end, doc, line
end

local function continuation_indent_width(font, text)
  local mode = config.plugins.linewrapping.wrapping_indent
  if mode == "none" or config.plugins.linewrapping.indent == false then
    return 0
  end

  local width = 0
  local _, indent_end = text:find("^%s+")
  if indent_end then
    width = font:get_width(text:sub(1, indent_end))
  end

  local numeric_spaces = tonumber(mode)
  if numeric_spaces and numeric_spaces > 0 then
    width = width + font:get_width(string.rep(" ", numeric_spaces))
  elseif mode == "indent" or mode == "deepIndent" then
    local levels = mode == "deepIndent" and 2 or 1
    width = width + font:get_width(string.rep(" ", (config.indent_size or 4) * levels))
  end

  return width
end

function LineWrapping.compute_line_breaks(doc, default_font, line, width, mode)
  local xoffset, i, last_space, last_width, begin_width = 0, 1, nil, 0, 0
  local splits = { 1 }
  for idx, type, text in get_tokens(doc, line) do
    local font = style.syntax_fonts[type] or default_font
    if idx == 1 or idx == math.huge then
      begin_width = continuation_indent_width(font, text)
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
        elseif char == " " then
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

local function get_idx_line_col(docview, idx)
  local doc = docview.doc
  if idx < 1 then return 1, 1 end
  local offset = (idx - 1) * 2 + 1
  if offset > #docview.wrapped_lines then return #doc.lines, #doc.lines[#doc.lines] + 1 end
  return docview.wrapped_lines[offset], docview.wrapped_lines[offset + 1]
end

function LineWrapping.get_wrapped_line_count(docview, line)
  if not docview.wrapped_settings then return 1 end
  local total = #docview.wrapped_lines / 2
  local first = docview.wrapped_line_to_idx[line] or total
  local next_first = docview.wrapped_line_to_idx[line + 1] or (total + 1)
  return math.max(1, next_first - first)
end

-- Some gutter extensions wrap DocView:draw_line_gutter after linewrapping and
-- accidentally return a single line height. Preserve whatever the current
-- gutter chain draws, but force the returned height to cover all visual rows
-- for the wrapped logical line.
if not DocView.__linewrapping_deep_indent_gutter_height then
  DocView.__linewrapping_deep_indent_gutter_height = DocView.draw_line_gutter
end
local old_draw_line_gutter = DocView.__linewrapping_deep_indent_gutter_height
function DocView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  local height = old_draw_line_gutter(self, line, x, y, width) or lh
  if self.wrapped_settings then
    local wrapped_height = lh * LineWrapping.get_wrapped_line_count(self, line)
    if height < wrapped_height then
      return wrapped_height
    end
  end
  return height
end

local function draw_wrapped_docview(self)
  self:draw_background(style.background)
  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local lh = self:get_line_height()
  local _, y1, _, y2 = self:get_content_bounds()
  local total = #self.wrapped_lines / 2
  local minidx = math.max(1, math.floor((y1 - style.padding.y) / lh) + 1)
  local maxidx = math.min(total, math.floor((y2 - style.padding.y) / lh) + 1)
  if maxidx < minidx then
    self:draw_scrollbar()
    return
  end

  local x, base_y = self:get_content_offset()
  local gw, gpad = self:get_gutter_width()
  local gutter_w = gpad and gw - gpad or gw
  local first_line = get_idx_line_col(self, minidx)
  local last_line = get_idx_line_col(self, maxidx)

  self:prepare_line_body_draw_cache(first_line, last_line)
  self.__current_line_highlights_drawn_before_content = true

  -- Draw the gutter once per logical line, at that line's first visual row.
  -- Continuation rows are intentionally blank, matching VSCode-style wrapping.
  for line = first_line, last_line do
    local first_idx = self.wrapped_line_to_idx[line]
    if first_idx then
      local y = base_y + (first_idx - 1) * lh + style.padding.y
      self:draw_line_gutter(line, self.position.x, y, gutter_w)
    end
  end

  core.push_clip_rect(self.position.x + gw, self.position.y, math.max(0, self.size.x - gw), self.size.y)
  for line = first_line, last_line do
    local first_idx = self.wrapped_line_to_idx[line]
    if first_idx then
      local y = base_y + (first_idx - 1) * lh + style.padding.y
      self:draw_line_body(line, x + gw, y)
    end
  end
  self:draw_overlay()
  core.pop_clip_rect()

  self.__current_line_highlights_drawn_before_content = nil
  self.__line_body_highlight_cache = nil
  self.__line_body_selection_cache = nil
  self.__line_body_search_match_cache = nil
  self.__line_gutter_selection_cache = nil
  self.__visible_caret_cache = nil

  self:draw_scrollbar()
  LineWrapping.draw_guide(self)
end

if not DocView.__linewrapping_deep_indent_draw then
  DocView.__linewrapping_deep_indent_draw = DocView.draw
end
local old_draw = DocView.__linewrapping_deep_indent_draw
function DocView:draw(...)
  if not self.wrapped_settings then
    return old_draw(self, ...)
  end

  local centered = core.centered_editor
  if centered and centered.should_center and centered.should_center(self)
  and not self.__centered_editor_in_lane_geometry then
    self:draw_background(style.background)
    return centered.with_lane_geometry(self, function()
      return draw_wrapped_docview(self)
    end)
  end

  return draw_wrapped_docview(self)
end

return LineWrapping
