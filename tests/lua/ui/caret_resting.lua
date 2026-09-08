local CaretRenderer = require "core.caret_renderer"
local test = require "core.test"

test.describe("Resting caret", function()
  test.it("stops painting the trail when movement has ended", function()
    local caret = CaretRenderer.new()
    local owner = {}
    local color, trail_color = { 0, 0, 0, 255 }, { 30, 30, 30, 255 }
    local painted = {}
    local old_rect, old_poly = renderer.draw_rect, renderer.draw_poly
    renderer.draw_rect = function(_, _, _, _, paint) painted[#painted + 1] = paint end
    renderer.draw_poly = function(_, paint) painted[#painted + 1] = paint end
    local ok, err = pcall(function()
      local function draw(now, x, y, line)
        caret:begin_frame(true)
        caret:submit {
          x = x, y = y, width = 2, height = 20,
          owner = owner, line = line, col = 1,
          color = color, trail_color = trail_color,
        }
        return caret:draw(now, 0.15, 0.025, 1, 1, 6)
      end
      draw(0, 10.25, 10.25, 1)
      draw(0.01, 90.25, 70.25, 2)
      for i = 2, 200 do draw(i / 60, 90.25, 70.25, 2) end
      painted = {}
      test.equal(draw(4, 90.25, 70.25, 2), false)
      test.ok(#painted > 0)
      for _, paint in ipairs(painted) do
        test.same(paint, color, "the stopped caret still paints a trail")
      end
    end)
    renderer.draw_rect, renderer.draw_poly = old_rect, old_poly
    if not ok then error(err, 0) end
  end)
end)
