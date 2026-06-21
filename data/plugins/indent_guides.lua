-- mod-version:3
local core = require "core"
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

local indent_cache_by_doc = setmetatable({}, { __mode = "k" })

local function guide_color(active)
  return active and style.indent_guide_active or style.indent_guide
end

local function indent_cache(doc, indent_size)
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  local limit = indent_guides.blank_line_search_limit or 25
  local cache = indent_cache_by_doc[doc]
  if
    not cache
    or cache.change_id ~= change_id
    or cache.indent_size ~= indent_size
    or cache.blank_line_search_limit ~= limit
  then
    cache = {
      change_id = change_id,
      indent_size = indent_size,
      blank_line_search_limit = limit,
      leading = {},
      effective = {},
    }
    indent_cache_by_doc[doc] = cache
  end
  return cache
end

local function compute_leading_indent_cols(doc, line, indent_size)
  local text = doc.lines[line]
  if not text then return 0, true end

  local whitespace = text:match("^[ \t]*") or ""
  local next_char = text:sub(#whitespace + 1, #whitespace + 1)
  -- doc.lines entries commonly include their trailing newline. Do not let that
  -- newline count as indentation, and treat newline-only lines as blank.
  local is_blank = next_char == "" or next_char == "\r" or next_char == "\n"
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

local function leading_indent_cols(doc, line, indent_size)
  local cache = indent_cache(doc, indent_size)
  local cached = cache.leading[line]
  if cached then return cached[1], cached[2] end

  local cols, is_blank = compute_leading_indent_cols(doc, line, indent_size)
  cache.leading[line] = { cols, is_blank }
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
  local cache = indent_cache(doc, indent_size)
  local cached = cache.effective[line]
  if cached ~= nil then return cached end

  local cols, blank = leading_indent_cols(doc, line, indent_size)
  if not blank then
    cache.effective[line] = cols
    return cols
  end

  local limit = cache.blank_line_search_limit
  local prev = previous_nonblank_indent(doc, line, indent_size, limit)
  local nexti = next_nonblank_indent(doc, line, indent_size, limit)
  cols = (prev and nexti) and math.max(prev, nexti) or (prev or nexti or 0)
  cache.effective[line] = cols
  return cols
end

local function is_closing_block_line(text)
  return text and text:match("^%s*[%]%)}][,;]?%s*$") ~= nil
end

local function current_clip_x_range(dv)
  local clip = core.clip_rect_stack and core.clip_rect_stack[#core.clip_rect_stack]
  if clip then
    return clip[1], clip[1] + clip[3]
  end

  local gw = dv:get_gutter_width()
  return dv.position.x + gw, dv.position.x + dv.size.x
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
    -- overlap is normally not an issue. Pre-clip horizontally so huge indents
    -- don't spend Lua/FFI calls on guides the renderer would discard anyway.
    if indent_px > 0 then
      local clip_left, clip_right = current_clip_x_range(self)
      local first_depth = math.max(1, math.floor((clip_left - x - lw) / indent_px) + 1)
      local last_depth = math.min(indent_levels - 1, math.ceil((clip_right - x) / indent_px))
      local function draw_grid(from_depth, to_depth, color)
        local count = to_depth - from_depth + 1
        if count <= 0 then return end
        if renderer.draw_rect_grid then
          renderer.draw_rect_grid(x + from_depth * indent_px, y, indent_px, lw, lh, count, color)
        else
          for depth = from_depth, to_depth do
            renderer.draw_rect(x + depth * indent_px, y, lw, lh, color)
          end
        end
      end

      if active_depth and active_depth >= first_depth and active_depth <= last_depth then
        draw_grid(first_depth, active_depth - 1, normal_color)
        renderer.draw_rect(x + active_depth * indent_px, y, lw, lh, active_color)
        draw_grid(active_depth + 1, last_depth, normal_color)
      else
        draw_grid(first_depth, last_depth, normal_color)
      end
    end
  end

  return line_height
end
