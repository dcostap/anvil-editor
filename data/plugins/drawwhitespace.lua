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
  trailing_color = style.whitespace_trailing,

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
  local tx
  local col1, col2
  local text, offset
  local s, e
  local line_len = #self.doc.lines[idx]
  local l1, c1, l2, c2
  if
    not drawwhitespace.show_selected_only
    or
    self.drawwhitespace_selections.all
  then
    col1, col2 = self:get_visible_cols_range(idx, 20)
    if col1 == 0 or col2 == 1 then goto not_selected end -- skip empty line
    text = self.doc.lines[idx]:sub(col1, col2)
  else
    if not self.drawwhitespace_selections[idx] then goto not_selected end
    col1, col2, text = table.unpack(self.drawwhitespace_selections[idx])
  end

  for _, substitution in pairs(drawwhitespace.substitutions) do
    local char = substitution.char
    local sub = substitution.sub
    offset = 1

    local show_leading = get_option(substitution, "show_leading")
    local show_middle = get_option(substitution, "show_middle")
    local show_trailing = get_option(substitution, "show_trailing")

    local show_middle_min = get_option(substitution, "show_middle_min")

    local base_color = get_option(substitution, "color")
    local leading_color = get_option(substitution, "leading_color") or base_color
    local middle_color = get_option(substitution, "middle_color") or base_color
    local trailing_color = get_option(substitution, "trailing_color") or base_color

    local pattern = char.."+"
    while true do
      s, e = text:find(pattern, offset)
      if not s then break end

      local as, ae = col1 + s - 1, col1 + e

      tx = self:get_col_x_offset(idx, as) + x

      local color = base_color
      local draw = false

      if ae >= line_len then
        draw = show_trailing
        color = trailing_color
      elseif as == 1 then
        draw = show_leading
        color = leading_color
      else
        draw = show_middle and (ae - as >= show_middle_min)
        color = middle_color
      end

      if draw then
        -- We need to draw tabs one at a time because they might have a
        -- different size than the substituting character.
        -- This also applies to any other char if we use non-monospace fonts
        -- but we ignore this case for now.
        if char == "\t" then
          for i = as,ae-1 do
            tx = self:get_col_x_offset(idx, i) + x
            tx = renderer.draw_text(font, sub, tx, ty, color)
          end
        else
          tx = renderer.draw_text(font, string.rep(sub, ae - as), tx, ty, color)
        end

        end

      offset = e + 1
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
