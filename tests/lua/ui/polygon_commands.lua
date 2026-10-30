local renderer = require "renderer"
local renwindow = require "renwindow"
local test = require "core.test"

-- Run with SDL_VIDEO_DRIVER=windows to check the D3D command path.
test.describe("polygon command rendering", function()
  test.it("draws translucent polygons with antialiased edges", function()
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
    local ok, err = pcall(function()
      draw()
      local capture = os.getenv("ANVIL_POLYGON_CAPTURE")
      if capture then test.ok(renwindow.request_frame_capture(window, capture)) end
      draw()

      local background = renwindow.get_color(window, 120, 24)
      local interior = renwindow.get_color(window, 35, 24)
      test.not_equal(interior, background, "the translucent triangle did not render")

      local antialiased_edge = false
      for y = 14, 34 do
        for x = 9, 101 do
          local pixel = renwindow.get_color(window, x, y)
          local differs = false
          local between = true
          for channel = 1, 3 do
            local low = math.min(background[channel], interior[channel])
            local high = math.max(background[channel], interior[channel])
            if pixel[channel] < low - 3 or pixel[channel] > high + 3 then between = false end
            if math.abs(pixel[channel] - background[channel]) > 3
              and math.abs(pixel[channel] - interior[channel]) > 3 then
              differs = true
            end
          end
          if between and differs then antialiased_edge = true; break end
        end
        if antialiased_edge then break end
      end
      test.ok(antialiased_edge, "polygon edges had no partial coverage")
    end)
    renwindow.close(window)
    if not ok then error(err, 0) end
  end)
end)
