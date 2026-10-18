local test = require "core.test"
local style = require "core.style"

local WIDTH, HEIGHT = 400, 60

local function ink_between(pixels, x1, x2)
  for y = 0, HEIGHT - 1 do
    for x = math.max(0, math.floor(x1)), math.min(WIDTH, math.ceil(x2)) - 1 do
      if pixels:byte((y * WIDTH + x) * 4 + 1) > 96 then return true end
    end
  end
  return false
end

local function draw_cells(font, text, cells, cell_width)
  local target = canvas.new(WIDTH, HEIGHT, { 0, 0, 0, 255 }, false)
  local end_x = target:draw_text_cells(font, text, cells, 0, 0, cell_width, { 255, 255, 255, 255 })
  target:render()
  return target:get_pixels(0, 0, WIDTH, HEIGHT), end_x
end

test.describe("Renderer cell text", function()
  test.it("keeps text that a ligature font shapes on its cells", function()
    -- The code font shapes whole runs so ligatures can form. Each glyph
    -- cluster must still land on the cell that holds its character.
    local font = style.code_font
    local cell_width = font:get_width("M") * 3
    local pixels, end_x = draw_cells(font, "abcd", "\1\1\1\1\1\1\1\1", cell_width)

    test.equal(end_x, 4 * cell_width)
    for cell = 0, 3 do
      test.ok(
        ink_between(pixels, cell * cell_width, (cell + 1) * cell_width),
        string.format("Cell %d is empty", cell + 1)
      )
    end
  end)

  test.it("rejects cells that do not describe the text", function()
    local target = canvas.new(10, 10, { 0, 0, 0, 255 }, false)
    local color = { 255, 255, 255, 255 }
    local font = style.code_font
    test.ok(not pcall(target.draw_text_cells, target, font, "ab", "\1\1", 0, 0, 8, color))
    test.ok(not pcall(target.draw_text_cells, target, font, "ab", "\1\1\1", 0, 0, 8, color))
    test.ok(not pcall(target.draw_text_cells, target, font, "ab", "\2\0", 0, 0, 8, color))
    test.ok(not pcall(target.draw_text_cells, target, font, "ab", "\1\1\1\1", 0, 0, 0, color))
    test.ok(pcall(target.draw_text_cells, target, font, "ab", "\1\1\1\1", 0, 0, 8, color))
  end)
end)
