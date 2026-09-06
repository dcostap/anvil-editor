local renderer = require "renderer"
local renwindow = require "renwindow"
local test = require "core.test"

-- Run with SDL_VIDEO_DRIVER=windows to check the D3D command path.
test.describe("polygon command rendering", function()
  test.it("draws antialiased polygons without per-polygon texture uploads", function()
    local window = renwindow.create("polygon commands", 320, 240)
    local function draw()
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 320, 240)
      renderer.draw_rect(0, 0, 320, 240, { 20, 30, 40, 255 })
      for row = 0, 7 do
        local y = 15 + row * 25
        renderer.draw_poly({ { 10, y }, { 100, y + 8 }, { 15, y + 18 } },
          { 240, 120, 60, 160 })
        renderer.draw_poly({ { 150, y }, { 165, y + 5 }, { 170, y + 15 },
          { 155, y + 20 }, { 145, y + 10 } }, { 80, 200, 250, 255 })
      end
      renderer.push_transform(35, 20, 0.6, 0.7)
      renderer.draw_poly({ { 180, 20 }, { 300, 40 }, { 220, 90 } },
        { 250, 220, 40, 190 })
      renderer.pop_transform()
      renderer.set_clip_rect(250, 170, 35, 30)
      renderer.draw_poly({ { 230, 160 }, { 310, 180 }, { 270, 225 } },
        { 180, 80, 240, 210 })
      renderer.set_clip_rect(0, 0, 320, 240)
      renderer.end_frame()
    end
    draw()
    local capture = os.getenv("ANVIL_POLYGON_CAPTURE")
    if capture then
      test.ok(renwindow.request_frame_capture(window, capture))
    end
    draw()
    local stats = renderer.get_last_frame_stats()
    if stats.path ~= "commands" then return end
    test.equal(stats.texture_uploads, 0)
    test.ok(stats.quad_instances > 0)
  end)
end)
