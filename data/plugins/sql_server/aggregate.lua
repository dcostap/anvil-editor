-- The aggregates of selected result cells, like DbVisualizer's Aggregates
-- Viewer: the cell count, the NULL count and, when each other cell is a
-- number, its sum, average, minimum and maximum. Decimal text sums exactly
-- while the sum fits in 15 digits; a larger sum or float text shows "≈".
local M = {}

local EXACT_LIMIT = 2 ^ 53

local function trim_zeros(text)
  if text:find("%.") then text = text:gsub("0+$", ""):gsub("%.$", "") end
  return text
end

-- Scaled integer to decimal text: 12345 at scale 2 is 123.45.
local function decimal_text(value, scale)
  local digits = string.format("%.0f", math.abs(value))
  if scale > 0 then
    digits = string.rep("0", scale + 1 - #digits) .. digits
    digits = digits:sub(1, #digits - scale) .. "." .. digits:sub(#digits - scale + 1)
  end
  digits = trim_zeros(digits)
  return (value < 0 and digits ~= "0") and "-" .. digits or digits
end

---@param cells (string|false)[] Cell values; false is NULL
---@return string
function M.summary(cells)
  local count, nulls, numbers = #cells, 0, 0
  local sum, scale, exact, float_sum = 0, 0, true, 0
  local min, max, min_text, max_text
  for i = 1, count do
    local cell = cells[i]
    if cell == false then
      nulls = nulls + 1
    else
      -- Character columns can pad numbers with spaces.
      local text = cell
      if (text:byte(1) or 33) <= 32 or (text:byte(-1) or 33) <= 32 then text = text:match("^%s*(.-)%s*$") end
      local value = tonumber(text)
      if value and text:find("^[-+]?%d*%.?%d*$") then
        local dot = text:find(".", 1, true)
        local digits, places = #text, dot and #text - dot or 0
        if dot then digits = digits - 1 end
        local first = text:byte(1)
        if first == 43 or first == 45 then digits = digits - 1 end
        if places > scale then
          sum, scale = sum * 10 ^ (places - scale), places
          if math.abs(sum) >= EXACT_LIMIT then exact = false end
        end
        -- Text with 15 digits or fewer is exact as a scaled double.
        local scaled = value * 10 ^ scale
        sum = sum + (scaled < 0 and math.ceil(scaled - 0.5) or math.floor(scaled + 0.5))
        if digits > 15 or scale > 15 or math.abs(sum) >= EXACT_LIMIT then exact = false end
      elseif value and text:find("^[-+]?%d*%.?%d*[eE][-+]?%d+$") and text:find("%d[eE]") then
        exact = false
      else
        value = nil
      end
      if value then
        numbers = numbers + 1
        float_sum = float_sum + value
        if not min or value < min then min, min_text = value, text end
        if not max or value > max then max, max_text = value, text end
      end
    end
  end
  local parts = { string.format("%d %s", count, count == 1 and "cell" or "cells") }
  if nulls > 0 then parts[#parts + 1] = string.format("%d NULL", nulls) end
  if numbers > 0 and numbers == count - nulls then
    local average = float_sum / numbers
    if exact then
      parts[#parts + 1] = "Sum " .. decimal_text(sum, scale)
      parts[#parts + 1] = "Avg " .. trim_zeros(string.format("%." .. math.min(15, scale + 4) .. "f", average))
    else
      parts[#parts + 1] = "Sum ≈" .. string.format("%.15g", float_sum)
      parts[#parts + 1] = "Avg ≈" .. string.format("%.15g", average)
    end
    parts[#parts + 1] = "Min " .. min_text
    parts[#parts + 1] = "Max " .. max_text
  end
  return table.concat(parts, " · ")
end

return M
