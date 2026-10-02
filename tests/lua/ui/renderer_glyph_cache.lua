local test = require "core.test"

local function draw_frame(window, font, text, background)
  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, 160, 32)
  renderer.draw_rect(0, 0, 160, 32, background)
  renderer.draw_text(font, text, 2, 2, {255, 255, 255, 255})
  renderer.end_frame()
  return renderer.get_last_frame_stats()
end

local function draw_known_frame(window, font, text, background, clip_width)
  renderer.begin_frame(window)
  renderer.set_clip_rect(0, 0, clip_width or 400, 48)
  renderer.draw_rect(0, 0, 400, 48, background)
  renderer.draw_text_known_bounds(font, text, 2, 2, 0, 0, 400, 48,
    {255, 255, 255, 255})
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

  test.it("reuses drawn shaping results when bounds do not need measurement", function()
    local path = DATADIR .. "/fonts/JetBrainsMono-Regular.ttf"
    local font = renderer.font.load(path, 14 * SCALE, { ligatures = true })
    local reference = renderer.font.load(path, 14 * SCALE, { ligatures = true })
    local window = renwindow.create("renderer-shaping-cache-test-window", 400, 48)
    local text = "office->affine!=caféλ"
    local expected_width = reference:get_width(text)

    local first = draw_known_frame(window, font, text, {0, 0, 0, 255}, 16)
    test.ok(first.text_render_hb_shapes > 0, "the fresh font must shape the text")
    local second = draw_known_frame(window, font, text, {8, 8, 8, 255})
    test.ok(second.text_render_glyphs > 0, "the changed background must force replay")
    test.ok(second.text_render_glyphs > first.text_render_glyphs,
      "the cached shape must include glyphs outside the first clip")
    test.equal(second.text_render_hb_shapes, 0,
      "replay must reuse shaping without a prior width query")
    test.equal(font:get_width(text), expected_width)

    font:set_size(20 * SCALE)
    reference:set_size(20 * SCALE)
    local resized = draw_known_frame(window, font, text, {16, 16, 16, 255})
    test.ok(resized.text_render_hb_shapes > 0, "resize must invalidate the shaped result")
    test.equal(font:get_width(text), reference:get_width(text))
  end)

  test.it("keeps italic overhang visible when drawn text is measured later", function()
    local font = renderer.font.load(DATADIR .. "/fonts/CrimsonPro-Italic.ttf",
      40 * SCALE, { ligatures = true, antialiasing = "grayscale" })
    local window = renwindow.create("renderer-italic-overhang-test-window", 64, 96)
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, 64, 96)
    renderer.draw_rect(0, 0, 64, 96, {0, 0, 0, 255})
    renderer.draw_text_known_bounds(font, "j́", 20, 0, 0, 0, 64, 96,
      {255, 255, 255, 255})
    renderer.end_frame()

    local ink_x, ink_y
    for y = 0, 95 do
      for x = 0, 18 do
        if renwindow.get_color(window, x, y)[1] > 100 then ink_x, ink_y = x, y end
      end
    end
    test.not_nil(ink_x, "the fixture must have visible ink before the text origin")
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, 19, 96)
    renderer.draw_rect(0, 0, 64, 96, {8, 8, 8, 255})
    renderer.draw_text(font, "j́", 20, 0, {255, 255, 255, 255})
    renderer.end_frame()
    test.ok(renwindow.get_color(window, ink_x, ink_y)[1] > 100,
      "measured bounds must include the ink before the text origin")
  end)
end)
