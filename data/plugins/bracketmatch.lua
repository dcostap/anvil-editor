--- mod-version:3.1
local core = require "core"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local TextView = require "core.textview"
local line_packets = require "core.textview_line_packets"

-- Colors can be configured as follows:
--   underline color  = `style.bracketmatch_color`
--   bracket color    = `style.bracketmatch_char_color`
--   background color = `style.bracketmatch_block_color`
--   frame color      = `style.bracketmatch_frame_color`

local bracketmatch = {
  -- highlight the current bracket too
  highlight_both = true,
  -- can be "underline", "block", "frame", "none"
  style = "frame",
  -- color the bracket
  color_char = false,
  line_limit = 3000,
}


local bracket_maps = {
  -- [     ]    (     )    {      }
  { [91] = 93, [40] = 41, [123] = 125, direction =  1 },
  -- ]     [    )     (    }      {
  { [93] = 91, [41] = 40, [125] = 123, direction = -1 },
}


--- @param buffer core.buffer
--- @param line integer
--- @param col integer
--- @return string? type
--- @return string? text
local function get_token_at(buffer, line, col)
  local column = 0
  for _,type,text in buffer.highlighter:each_token(line) do
    column = column + #text
    if column >= col then return type, text end
  end
end

local function get_render_token_at(buffer, line, col)
  local column = 0
  for _,type,text in buffer.highlighter:each_render_token(line) do
    column = column + #text
    if column >= col then return type, text end
  end
end


--- @param buffer core.buffer
--- @param line integer
--- @param col integer
--- @param line_limit integer
--- @param open_byte integer
--- @param close_byte integer
--- @param direction integer
--- @return integer? line
--- @return integer? col
local function get_matching_bracket(buffer, line, col, line_limit, open_byte, close_byte, direction)
  local end_line = line + line_limit * direction
  local depth = 0

  while line ~= end_line do
    local byte = buffer.lines[line]:byte(col)
    if byte == open_byte and get_token_at(buffer, line, col) ~= "comment" then
      depth = depth + 1
    elseif byte == close_byte and get_token_at(buffer, line, col) ~= "comment" then
      depth = depth - 1
      if depth == 0 then return line, col end
    end

    local prev_line, prev_col = line, col
    line, col = buffer:position_offset(line, col, direction)
    if line == prev_line and col == prev_col then
      break
    end
  end
end


local state = {}
local select_adj = 0

--- @param line_limit integer?
local function update_state(line_limit)
  line_limit = line_limit or math.huge

  -- reset if we don't have a buffer (eg. TextView isn't focused)
  local buffer = core.active_view.buffer
  if not buffer then
    state = {}
    return
  end

  -- early exit if nothing has changed since the last call
  local line, col = buffer:get_selection()
  local change_id = buffer:get_change_id()
  if  state.buffer == buffer and state.line == line and state.col == col
  and state.change_id == change_id and state.limit == line_limit then
    return
  end

  -- find matching bracket if we're on a bracket
  local line2, col2
  for _, map in ipairs(bracket_maps) do
    for i = 0, -1, -1 do
      local line, col = buffer:position_offset(line, col, i)
      local open = buffer.lines[line]:byte(col)
      local close = map[open]
      if close and get_token_at(buffer, line, col) ~= "comment" then
        -- i == 0 if the cursor is on the left side of a bracket (or -1 when on right)
        select_adj = i + 1 -- if i == 0 then select_adj = 1 else select_adj = 0 end
        line2, col2 = get_matching_bracket(buffer, line, col, line_limit, open, close, map.direction)
        goto found
      end
    end
  end
  ::found::

  -- update
  state = {
    change_id = change_id,
    buffer = buffer,
    line = line,
    col = col,
    line2 = line2,
    col2 = col2,
    limit = line_limit,
  }
end


local update = TextView.update

--- @param ... any
function TextView:update(...)
  update(self, ...)
  update_state(bracketmatch.line_limit)
end


--- @param dv core.textview
--- @param x number
--- @param y number
--- @param screen_x number
--- @param screen_y number
--- @param width number
--- @param height number
--- @param line integer
--- @param col integer
--- @param bg_color renderer.color | boolean
--- @param char_color renderer.color | boolean
local function redraw_char(dv, x, y, screen_x, screen_y, width, height, line, col, bg_color, char_color)
  local token = get_render_token_at(dv.buffer, line, col)
  if not char_color then
    char_color = style.syntax[token]
  end
  local font = style.syntax_fonts[token] or dv:get_font()
  local char = string.sub(dv.buffer.lines[line], col, col)

  if not bg_color then
    -- redraw background
    core.push_clip_rect(screen_x, screen_y, width, height)
    local dlt = TextView.draw_line_text
    TextView.draw_line_text = function() end
    line_packets.with_suspended_finalization(dv, function()
      dv:draw_line_body(line, x, y)
    end)
    TextView.draw_line_text = dlt
    core.pop_clip_rect()
  else
    renderer.draw_rect(screen_x, screen_y, width, height, bg_color)
  end
  -- redraw char
  renderer.draw_text(
    font, char, screen_x,
    screen_y + math.max(0, (height - font:get_height()) / 2),
    char_color
  )
end


--- @param dv core.textview
--- @param x number
--- @param y number
--- @param line integer
--- @param col integer
--- @param width integer
local function draw_decoration(dv, x, y, line, col, width)
  local conf = bracketmatch
  local color = style.bracketmatch_color
  local char_color = conf.style == "block"
    and style.bracketmatch_block_char_color
    or style.bracketmatch_char_color
  local block_color = style.bracketmatch_block_color
  local frame_color = style.bracketmatch_frame_color

  local thickness = math.max(1, SCALE)

  -- color char or block style
  if conf.color_char or conf.style == "block" then
    for i = 1, width, 1 do
      local char_col = col + i - 1
      for screen_x, screen_y, screen_x2, row_height in
        dv:iter_text_range_screen_segments(
          line, char_col, char_col + 1, x, y
        )
      do
        redraw_char(
          dv, x, y, screen_x, screen_y, screen_x2 - screen_x,
          row_height, line, char_col,
          conf.style == "block" and block_color,
          conf.color_char and char_color
        )
      end
    end
  end

  -- draw decoration
  for screen_x, screen_y, screen_x2, row_height in
    dv:iter_text_range_screen_segments(line, col, col + width, x, y)
  do
    local screen_w = screen_x2 - screen_x
    if conf.style == "underline" then
      renderer.draw_rect(
        screen_x, screen_y + row_height - thickness,
        screen_w, thickness, color
      )
    elseif conf.style == "frame" then
      renderer.draw_rect(screen_x, screen_y, screen_w, thickness, frame_color)
      renderer.draw_rect(screen_x, screen_y + row_height - thickness, screen_w, thickness, frame_color)
      renderer.draw_rect(screen_x, screen_y, thickness, row_height, frame_color)
      renderer.draw_rect(screen_x2 - thickness, screen_y, thickness, row_height, frame_color)
    end
  end
end

local function render_suppresses_range(dv, line, col, width)
  local render_line = dv:get_line_render(line)
  if not render_line then return false end
  local range_col2 = col + width
  for _, fragment in ipairs(render_line.fragments or {}) do
    if fragment.suppress_bracketmatch then
      local col1 = fragment.text_source_col1 or fragment.source_col1 or 1
      local col2 = fragment.text_source_col2 or fragment.source_col2 or col1
      if col < col2 and col1 < range_col2 then return true end
    end
  end
  return false
end


local draw_line_text = TextView.draw_line_text

local function perf_scope_begin(name)
  if not core.perf_draw_scope_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.scope_begin and perf.scope_begin(name) or nil
end

local function perf_scope_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.scope_end then perf.scope_end(token) end
end

--- @param line integer
--- @param x number
--- @param y number
--- @return number
function TextView:draw_line_text(line, x, y)
  local scope = perf_scope_begin("bracket_match")
  local lh = draw_line_text(self, line, x, y)
  local width = 1
  if self.buffer == state.buffer and state.line2 then
    if line == state.line and bracketmatch.highlight_both then
      local offset = 0
      if state.line == state.line2 and math.abs(state.col + select_adj - 1 - state.col2) == 1 then
        width = 2
        if state.col > state.col2 then
          offset = -1
        end
        if state.col2 > state.col + select_adj then
          offset = 1
        end
      end
      local col = state.col + select_adj + offset - 1
      if not render_suppresses_range(self, line, col, width) then
        draw_decoration(self, x, y, line, col, width)
      end
    end
    if line == state.line2 and width == 1 then
      if not render_suppresses_range(self, line, state.col2, width) then
        draw_decoration(self, x, y, line, state.col2, width)
      end
    end
  end
  perf_scope_end(scope)
  return lh
end


command.add("core.textview", {
  ["bracket-match:move-to-matching"] = function(dv)
    update_state()
    if state.line2 then
      dv.buffer:set_selection(state.line2, state.col2)
    end
  end,
  ["bracket-match:select-to-matching"] = function(dv)
    update_state()
    if state.line2 then
        dv.buffer:set_selection(state.line, state.col, state.line2, state.col2 + select_adj)
    end
  end,
})

keymap.add {
  ["ctrl+shift+m"] = "bracket-match:select-to-matching",
}
