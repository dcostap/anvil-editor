-- mod-version:3
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

local indent_guides = {
  enabled = true,
  line_width = math.max(1, SCALE),
  highlight_active = false,
  blank_line_search_limit = 25,
}

local function guide_color(active)
  if active then
    return style.indent_guide_active or { common.color "rgba(255, 255, 255, 0.24)" }
  end
  return style.indent_guide or { common.color "rgba(255, 255, 255, 0.10)" }
end

local function leading_indent_cols(doc, line, indent_size)
  local text = doc.lines[line]
  if not text then return 0, true end

  -- doc.lines entries commonly include their trailing newline. Do not let that
  -- newline count as indentation, and treat newline-only lines as blank.
  text = text:gsub("[\r\n]+$", "")

  local whitespace = text:match("^[ \t]*") or ""
  local is_blank = text:match("^[ \t]*$") ~= nil
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

local function previous_nonblank_indent(doc, line, indent_size, limit)
  local start = math.max(1, line - limit)
  for i = line - 1, start, -1 do
    local cols, blank = leading_indent_cols(doc, i, indent_size)
    if not blank then return cols, i end
  end
end

local function next_nonblank_indent(doc, line, indent_size, limit)
  local stop = math.min(#doc.lines, line + limit)
  for i = line + 1, stop do
    local cols, blank = leading_indent_cols(doc, i, indent_size)
    if not blank then return cols, i end
  end
end

local function effective_indent_cols(doc, line, indent_size)
  local conf = indent_guides
  local cols, blank = leading_indent_cols(doc, line, indent_size)
  if not blank then return cols end

  local limit = conf.blank_line_search_limit or 25
  local prev = previous_nonblank_indent(doc, line, indent_size, limit)
  local nexti = next_nonblank_indent(doc, line, indent_size, limit)
  if prev and nexti then return math.max(prev, nexti) end
  return prev or nexti or 0
end

local function is_closing_block_line(text)
  return text and text:match("^%s*[%]%)}][,;]?%s*$") ~= nil
end

local function active_indent_depth(dv, indent_size)
  local line = dv.doc:get_selection()
  line = common.clamp(line or 1, 1, #dv.doc.lines)

  local cols, blank = leading_indent_cols(dv.doc, line, indent_size)
  local text = dv.doc.lines[line]
  local limit = indent_guides.blank_line_search_limit or 25

  if blank then
    local prev = previous_nonblank_indent(dv.doc, line, indent_size, limit)
    local nexti = next_nonblank_indent(dv.doc, line, indent_size, limit)
    cols = math.max(prev or 0, nexti or 0)
  elseif is_closing_block_line(text) then
    local prev = previous_nonblank_indent(dv.doc, line, indent_size, limit)
    if prev and prev > cols then
      cols = prev
    end
  else
    local nexti = next_nonblank_indent(dv.doc, line, indent_size, 1)
    if nexti and nexti > cols then
      -- Caret is on a block-opening line; highlight the block being opened.
      cols = nexti
    end
  end

  local depth = math.floor(cols / indent_size) - 1
  return depth >= 0 and depth or nil
end

local old_draw_line_body = DocView.draw_line_body
function DocView:draw_line_body(line, x, y)
  local line_height = old_draw_line_body(self, line, x, y)

  local conf = indent_guides
  if conf.enabled then
    local _, indent_size = self.doc:get_indent_info()
    indent_size = indent_size or config.indent_size or 2
    local indent_cols = effective_indent_cols(self.doc, line, indent_size)
    local indent_levels = math.floor(indent_cols / indent_size)
    local indent_px = self:get_font():get_width(string.rep(" ", indent_size))
    local lh = self:get_line_height()
    local lw = conf.line_width or math.max(1, SCALE)
    local active_depth = conf.highlight_active and active_indent_depth(self, indent_size) or nil
    local normal_color = guide_color(false)
    local active_color = conf.highlight_active and guide_color(true) or normal_color

    -- Draw after the normal line body so blank-line backgrounds/highlights do
    -- not erase guide segments. Guides sit in indentation whitespace, so text
    -- overlap is normally not an issue.
    for depth = 1, indent_levels - 1 do
      local gx = x + depth * indent_px
      renderer.draw_rect(gx, y, lw, lh, depth == active_depth and active_color or normal_color)
    end
  end

  return line_height
end
