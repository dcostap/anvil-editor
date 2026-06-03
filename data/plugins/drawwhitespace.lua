-- mod-version:3

local core = require "core"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local command = require "core.command"

local drawwhitespace = {
  enabled = true,
  show_leading = true,
  show_trailing = true,
  show_middle = false,
  show_selected_only = false,

  show_middle_min = 1,

  color = style.whitespace,
  leading_color = style.whitespace,
  middle_color = nil,
  trailing_color = style.whitespace_trailing or style.whitespace,

  substitutions = {
    {
      char = " ",
      sub = "·",
      show_leading = true,
      show_middle = false,
      show_trailing = true,
    },
    {
      char = "\t",
      sub = "→",
      show_leading = true,
      show_middle = false,
      show_trailing = true,
    },
  },
}


local function get_option(substitution, option)
  if substitution[option] == nil then
    return drawwhitespace[option]
  end
  return substitution[option]
end

local update = DocView.update
function DocView:update()
  update(self)
  if
    drawwhitespace.enabled
    and
    drawwhitespace.show_selected_only
  then
    local selections = {}
    local col1, col2
    local vl1, vl2 = self:get_visible_line_range()
    for _, l1, c1, l2, c2 in self.doc:get_selections(true) do
      -- everything selected treat as not show_selected_only
      if l1 < vl1 and l2 > vl2 then
        selections.all = true
        goto out_of_loop
      end
      -- nothing selected so skip
      if l1 == l2 and c1 == c2 then goto skip end
      -- handle single line selection
      if l1 == l2 and l1 >= vl1 and l1 <= vl2 then
        col1, col2 = self:get_visible_cols_range(l1, 20)
        c1, c2 = math.max(col1, c1), math.min(col2, c2)
        selections[l1] = {c1, c2, self.doc.lines[l1]:sub(c1, c2)}
      -- multiple lines selection
      elseif l1 ~= l2 then
        -- first line
        if l1 >= vl1 and l1 <= vl2 then
          col1, col2 = self:get_visible_cols_range(l1, 20)
          col1 = math.max(c1, col1)
          selections[l1] = {col1, col2, self.doc.lines[l1]:sub(col1, col2)}
        end
        -- lines in between
        if l2 - l1 > 1 then
          for idx=l1+1, l2-1 do
            col1, col2 = self:get_visible_cols_range(idx, 20)
            selections[idx] = {col1, col2, self.doc.lines[idx]:sub(col1, col2)}
          end
        end
        -- last line
        if l2 >= vl1 and l2 <= vl2 then
          col1, col2 = self:get_visible_cols_range(l2, 20)
          col2 = math.min(c2, col2)
          selections[l2] = {col1, col2, self.doc.lines[l2]:sub(col1, col2)}
        end
      end
      ::skip::
    end
    ::out_of_loop::
    self.drawwhitespace_selections = selections
  elseif self.drawwhitespace_selections then
    self.drawwhitespace_selections = nil
  end
end

local function get_line_runs(self, idx)
  local cache = self.drawwhitespace_cache
  local change_id = self.doc:get_change_id()
  if not cache or cache.change_id ~= change_id then
    cache = { change_id = change_id, lines = {} }
    self.drawwhitespace_cache = cache
  end

  local entry = cache.lines[idx]
  local text = self.doc.lines[idx]
  if entry and entry.text == text then return entry end

  local line_len = #text
  local runs = {}
  for sidx, substitution in ipairs(drawwhitespace.substitutions) do
    local char = substitution.char
    local pattern = char .. "+"
    local offset = 1
    while true do
      local s, e = text:find(pattern, offset)
      if not s then break end
      runs[#runs + 1] = {
        substitution = sidx,
        start_col = s,
        end_col = e + 1,
        leading = s == 1,
        trailing = e + 1 >= line_len,
      }
      offset = e + 1
    end
  end

  entry = { text = text, line_len = line_len, runs = runs }
  cache.lines[idx] = entry
  return entry
end

local function draw_whitespace_run(self, idx, x, y, font, ty, substitution, start_col, end_col, color)
  if start_col >= end_col then return end

  -- Draw each marker at the source column position. Tabs need this because
  -- they can have a different visual width than the substituting glyph; spaces
  -- need it because repeated middle-dot strings can be shaped/ligated by the
  -- renderer and become visually incorrect with ligature-enabled fonts.
  for i = start_col, end_col - 1 do
    local tx = self:get_col_x_offset(idx, i) + x
    if substitution.char == " " then
      local next_tx = self:get_col_x_offset(idx, i + 1) + x
      local dot_size = math.max(2, math.floor(2 * SCALE))
      renderer.draw_rect(
        math.floor(tx + (next_tx - tx - dot_size) / 2),
        math.floor(ty + (font:get_height() - dot_size) / 2),
        dot_size,
        dot_size,
        color
      )
    else
      renderer.draw_text(font, substitution.sub, tx, ty, color)
    end
  end
end

local draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(idx, x, y)
  if
    not drawwhitespace.enabled
    or
    getmetatable(self) ~= DocView
  then
    return draw_line_text(self, idx, x, y)
  end

  if not self.drawwhitespace_selections then
    self.drawwhitespace_selections = {}
  end

  local font = (self:get_font() or style.syntax_fonts["whitespace"] or style.syntax_fonts["comment"])
  local ty = y + self:get_line_text_y_offset()
  local col1, col2, text
  if
    not drawwhitespace.show_selected_only
    or
    self.drawwhitespace_selections.all
  then
    col1, col2 = self:get_visible_cols_range(idx, 20)
    if col1 == 0 or col2 == 1 then goto not_selected end -- skip empty line
  else
    if not self.drawwhitespace_selections[idx] then goto not_selected end
    col1, col2, text = table.unpack(self.drawwhitespace_selections[idx])
  end

  if not drawwhitespace.show_selected_only or self.drawwhitespace_selections.all then
    local entry = get_line_runs(self, idx)
    for _, run in ipairs(entry.runs) do
      local substitution = drawwhitespace.substitutions[run.substitution]
      local start_col = math.max(run.start_col, col1)
      local end_col = math.min(run.end_col, col2 + 1)
      if start_col < end_col then
        local draw = false
        local color = get_option(substitution, "color")
        if run.trailing then
          draw = get_option(substitution, "show_trailing")
          color = get_option(substitution, "trailing_color") or color
        elseif run.leading then
          draw = get_option(substitution, "show_leading")
          color = get_option(substitution, "leading_color") or color
        else
          draw = get_option(substitution, "show_middle")
            and (run.end_col - run.start_col >= get_option(substitution, "show_middle_min"))
          color = get_option(substitution, "middle_color") or color
        end
        if draw then
          draw_whitespace_run(self, idx, x, y, font, ty, substitution, start_col, end_col, color)
        end
      end
    end
  else
    local line_len = #self.doc.lines[idx]
    for _, substitution in pairs(drawwhitespace.substitutions) do
      local offset = 1
      local pattern = substitution.char.."+"
      while true do
        local s, e = text:find(pattern, offset)
        if not s then break end

        local as, ae = col1 + s - 1, col1 + e
        local draw = false
        local color = get_option(substitution, "color")
        if ae >= line_len then
          draw = get_option(substitution, "show_trailing")
          color = get_option(substitution, "trailing_color") or color
        elseif as == 1 then
          draw = get_option(substitution, "show_leading")
          color = get_option(substitution, "leading_color") or color
        else
          draw = get_option(substitution, "show_middle") and (ae - as >= get_option(substitution, "show_middle_min"))
          color = get_option(substitution, "middle_color") or color
        end
        if draw then
          draw_whitespace_run(self, idx, x, y, font, ty, substitution, as, ae, color)
        end
        offset = e + 1
      end
    end
  end

  ::not_selected::
  return draw_line_text(self, idx, x, y)
end


command.add(nil, {
  ["draw-whitespace:toggle"]  = function()
    drawwhitespace.enabled = not drawwhitespace.enabled
  end,

  ["draw-whitespace:disable"] = function()
    drawwhitespace.enabled = false
  end,

  ["draw-whitespace:enable"]  = function()
    drawwhitespace.enabled = true
  end,
})
