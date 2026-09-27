local test = require "core.test"

local function draw_frame(window, font, text, background)
  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, 160, 32)
  renderer.draw_rect(0, 0, 160, 32, background)
  renderer.draw_text(font, text, 2, 2, {255, 255, 255, 255})
  renderer.end_frame()
  return renderer.get_last_frame_stats()
end

test.describe("renderer glyph cache", function()
  test.it("redraws ligature text without reloading its glyph bitmaps", function()
    local font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "CaskaydiaCoveNerdFontMono-Regular.ttf",
      14 * SCALE, { ligatures = true }
    )
    local window = renwindow.create("renderer-glyph-cache-test-window", 160, 32)
    test.not_nil(window)
    local text = "a -> b != c => d"

    local first = draw_frame(window, font, text, {0, 0, 0, 255})
    test.ok(first.text_render_glyph_bitmap_cache_misses > 0,
      "a fresh font should load the glyph bitmaps it draws")

    local second = draw_frame(window, font, text, {8, 8, 8, 255})
    test.ok(second.text_render_glyphs > 0, "the second frame should draw the text again")
    test.equal(second.text_render_glyph_bitmap_cache_misses, 0)
  end)
end)
