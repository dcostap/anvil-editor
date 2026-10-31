local test = require "core.test"

-- Seam: renderer.draw_poly inside a real renderer frame.
test.describe("Polygon rendering", function()
  test.it("finishes a frame with a polygon that reaches far outside the window", function()
    local window = renwindow.create("wide-polygon-test", 1024, 600)
    renderer.begin_frame(window)
    local ok, err = pcall(function()
      -- The caret trail from the far end of a 21,000-character prompt back to a terminal cursor.
      renderer.draw_poly({ { 818, 58 }, { 99086, 450 }, { 99776, 484 }, { 818, 88 } }, { 255, 255, 255, 255 })
      renderer.draw_poly({ { -70000, 10 }, { 500, 20 }, { 500, 40 }, { -70000, 30 } }, { 255, 255, 255, 255 })
    end)
    renderer.end_frame()
    if not ok then error(err, 0) end
  end)
end)
