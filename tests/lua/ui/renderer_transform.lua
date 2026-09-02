local test = require "core.test"

test.describe("renderer transform", function()
  test.it("scales cached glyph quads without new glyph texture uploads", function()
    local font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf",
      12 * SCALE
    )
    local window = renwindow.create("renderer-transform-test-window", 32, 32)
    test.not_nil(window)

    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, 32, 32)
    renderer.draw_rect(0, 0, 32, 32, {0, 0, 0, 255})
    renderer.draw_text(font, "A", 2, 2, {255, 255, 255, 255})
    renderer.end_frame()

    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, 32, 32)
    renderer.draw_rect(0, 0, 32, 32, {0, 0, 0, 255})
    renderer.push_transform(0, 0, 0.5, 0.5)
    renderer.draw_rect(0, 0, 20, 20, {255, 255, 255, 255})
    renderer.draw_text(font, "A", 2, 2, {255, 255, 255, 255})
    renderer.pop_transform()
    renderer.draw_rect(16, 16, 4, 4, {255, 255, 255, 255})
    renderer.end_frame()

    local stats = renderer.get_last_frame_stats()
    if stats.path == "commands" then
      test.equal(stats.texture_uploads, 0)
      return
    end

    local transformed = renwindow.get_color(window, 4, 4)
    for channel = 1, 3 do
      test.ok(transformed[channel] > 110 and transformed[channel] < 145)
    end
    local outside = renwindow.get_color(window, 12, 12)
    for channel = 1, 3 do test.ok(outside[channel] < 5) end
    local after_scope = renwindow.get_color(window, 17, 17)
    for channel = 1, 3 do test.ok(after_scope[channel] > 250) end
  end)
end)
