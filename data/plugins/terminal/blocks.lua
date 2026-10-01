-- Unicode Block Elements use cell geometry, not font outlines.
local blocks = {}

-- Round shared boundaries, not widths. Adjacent cells must use the same edge.
local function round(value) return math.floor(value + 0.5) end

-- Quadrant bits: upper left, upper right, lower left, lower right.
local quadrants = { 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 }

local function draw_cell(codepoint, left, top, right, bottom, color)
  local width, height = right - left, bottom - top
  local function rect(x1, y1, x2, y2)
    if x2 > x1 and y2 > y1 then
      renderer.draw_rect(x1, y1, x2 - x1, y2 - y1, color)
    end
  end
  if codepoint == 0x2588 then
    rect(left, top, right, bottom)
  elseif codepoint == 0x2580 then
    rect(left, top, right, top + round(height / 2))
  elseif codepoint >= 0x2581 and codepoint <= 0x2587 then
    rect(left, top + round(height * (0x2588 - codepoint) / 8), right, bottom)
  elseif codepoint >= 0x2589 and codepoint <= 0x258f then
    rect(left, top, left + round(width * (0x2590 - codepoint) / 8), bottom)
  elseif codepoint == 0x2590 then
    rect(left + round(width / 2), top, right, bottom)
  elseif codepoint == 0x2594 then
    rect(left, top, right, top + round(height / 8))
  elseif codepoint == 0x2595 then
    rect(left + round(width * 7 / 8), top, right, bottom)
  else
    local mask = quadrants[codepoint - 0x2595]
    local middle_x, middle_y = left + round(width / 2), top + round(height / 2)
    if mask % 2 >= 1 then rect(left, top, middle_x, middle_y) end
    if math.floor(mask / 2) % 2 >= 1 then rect(middle_x, top, right, middle_y) end
    if math.floor(mask / 4) % 2 >= 1 then rect(left, middle_y, middle_x, bottom) end
    if math.floor(mask / 8) % 2 >= 1 then rect(middle_x, middle_y, right, bottom) end
  end
end

function blocks.draw(codepoint, origin_x, top, cell_width, cell_height, col, columns, color)
  local y1, y2 = round(top), round(top + cell_height)
  local x1 = round(origin_x + col * cell_width)
  local x2 = round(origin_x + (col + columns) * cell_width)
  if codepoint == 0x2588 then
    -- A solid run needs one rectangle, including faint or transparent ink.
    renderer.draw_rect(x1, y1, x2 - x1, y2 - y1, color)
    return
  end
  if codepoint >= 0x2591 and codepoint <= 0x2593 then
    -- One shared pixel pattern keeps shade density stable across cell joins.
    for y = y1, y2 - 1 do
      if codepoint == 0x2593 and y % 2 == 1 then
        renderer.draw_rect(x1, y, x2 - x1, 1, color)
      elseif codepoint ~= 0x2591 or y % 2 == 0 then
        local parity = codepoint == 0x2591 and 0
          or codepoint == 0x2592 and y % 2 or 1
        local x = x1 + (parity - x1) % 2
        local count = math.ceil((x2 - x) / 2)
        if count > 0 then renderer.draw_rect_grid(x, y, 2, 1, 1, count, color) end
      end
    end
    return
  end
  for index = col, col + columns - 1 do
    draw_cell(codepoint,
      round(origin_x + index * cell_width), y1,
      round(origin_x + (index + 1) * cell_width), y2, color)
  end
end

return blocks
