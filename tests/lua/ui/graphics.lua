local common = require "core.common"
local core = require "core"
local ImageView = require "core.imageview"
local test = require "core.test"
local panes = require "core.panes"

local temp_root
local project_temp_root

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

test.describe("graphics apis", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    temp_root = USERDIR
      .. PATHSEP .. "graphics-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root

    project_temp_root = core.root_project().path
      .. PATHSEP .. "graphics-project-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    ok, err = common.mkdirp(project_temp_root)
    test.ok(ok, err)
    context.project_temp_root = project_temp_root
  end)

  test.after_each(function(context)
    panes.reset_for_tests()

    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
    if context.project_temp_root and system.get_file_info(context.project_temp_root) then
      local ok, err = common.rm(context.project_temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("loads fonts and exposes font metadata", function()
    local font_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf"
    local font = renderer.font.load(font_path, 14 * SCALE)
    test.not_nil(font)
    test.ok(font:get_width("Hello") > 0)
    test.ok(font:get_height() > 0)
    test.ok(font:get_size() > 0)
    test.equal(font:get_path(), font_path)

    font:set_tab_size(2)
    local copy = font:copy(18 * SCALE)
    test.not_nil(copy)
    test.ok(copy:get_size() > font:get_size())

    local metadata, err = renderer.font.get_metadata(font_path)
    test.not_nil(metadata, err)
    test.type(metadata, "table")

    local group = renderer.font.group({font, copy})
    local paths = group:get_path()
    test.type(paths, "table")
    test.equal(paths[1], font_path)

    local group_meta = renderer.font.get_metadata(group)
    test.type(group_meta, "table")
  end)

  test.test("supports toggling font ligatures", function()
    local font_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "JetBrainsMono-Regular.ttf"
    local font_plain = renderer.font.load(font_path, 24 * SCALE, { ligatures = false, antialiasing = "grayscale" })
    local font_liga = renderer.font.load(font_path, 24 * SCALE, { ligatures = true, antialiasing = "grayscale" })
    local font_liga_copy = font_liga:copy(24 * SCALE)
    local font_plain_copy = font_liga:copy(24 * SCALE, { ligatures = false, antialiasing = "grayscale" })
    local text = "-> === ffi"

    test.equal(font_plain:get_width(text), font_plain_copy:get_width(text))
    test.equal(font_liga:get_width(text), font_liga_copy:get_width(text))

    local c_plain = canvas.new(180 * SCALE, 48 * SCALE, {0, 0, 0, 255}, true)
    local c_liga = canvas.new(180 * SCALE, 48 * SCALE, {0, 0, 0, 255}, true)
    local plain_x = c_plain:draw_text(font_plain, text, 0, 0, {255, 255, 255, 255})
    local liga_x = c_liga:draw_text(font_liga, text, 0, 0, {255, 255, 255, 255})

    test.equal(plain_x, font_plain:get_width(text))
    test.equal(liga_x, font_liga:get_width(text))

    c_plain:render()
    c_liga:render()
    local pixels_plain = c_plain:get_pixels(0, 0, 180 * SCALE, 48 * SCALE)
    local pixels_liga = c_liga:get_pixels(0, 0, 180 * SCALE, 48 * SCALE)
    test.ok(pixels_plain ~= pixels_liga, "ligature-enabled rendering should differ from plain glyph rendering")
  end)

  test.test("keeps raster quality options out of text layout", function()
    local font_path = DATADIR .. PATHSEP .. "fonts"
      .. PATHSEP .. "CaskaydiaCoveNerdFontMono-SemiLight.ttf"
    local natural = renderer.font.load(font_path, 15 * SCALE, {
      antialiasing = "subpixel", hinting = "none", ligatures = true,
    })
    local hinted = renderer.font.load(font_path, 15 * SCALE, {
      antialiasing = "subpixel", hinting = "full", ligatures = true,
    })
    local grayscale = renderer.font.load(font_path, 15 * SCALE, {
      antialiasing = "grayscale", hinting = "slight", ligatures = true,
    })
    local samples = {
      "ASCII iiii ====", "────────", "tabs\talign", "é λ Ελληνικά",
    }

    for _, text in ipairs(samples) do
      local expected_width = natural:get_width(text)
      test.equal(hinted:get_width(text), expected_width)
      test.equal(grayscale:get_width(text), expected_width)
      test.equal(hinted:text_layout(text):width(), natural:text_layout(text):width())
      test.equal(grayscale:text_layout(text):width(), natural:text_layout(text):width())
      local wrap_width = math.max(1, expected_width * 0.55)
      test.same(hinted:wrap_text(text, wrap_width), natural:wrap_text(text, wrap_width))
      test.same(grayscale:wrap_text(text, wrap_width), natural:wrap_text(text, wrap_width))
    end
  end)

  test.test("uses fractional nominal font sizes for deterministic layout", function()
    local font_path = DATADIR .. PATHSEP .. "fonts"
      .. PATHSEP .. "CaskaydiaCoveNerdFontMono-SemiLight.ttf"
    local integer = renderer.font.load(font_path, 15 * SCALE, { ligatures = true })
    local fractional = renderer.font.load(font_path, 15.5 * SCALE, { ligatures = true })
    local repeated = renderer.font.load(font_path, 15.5 * SCALE, { ligatures = true })
    local text = "office ──────── Ελληνικά"

    test.ok(
      math.abs(fractional:get_width(text) - integer:get_width(text)) > 0.01,
      "fractional font size must not use the lower integer scale"
    )
    test.equal(fractional:get_width(text), repeated:get_width(text))
    test.equal(fractional:text_layout(text):width(), repeated:text_layout(text):width())
    test.same(
      fractional:wrap_text(text, fractional:get_width(text) * 0.55),
      repeated:wrap_text(text, repeated:get_width(text) * 0.55)
    )

    local expected_width = fractional:get_width(text)
    fractional:set_size(16 * SCALE)
    fractional:set_size(15.5 * SCALE)
    test.equal(fractional:get_width(text), expected_width)
    fractional:set_size(14 * SCALE)
    fractional:set_size(15.5 * SCALE)
    test.equal(fractional:get_width(text), expected_width)
  end)

  test.test("keeps raster policy and glyph caches local to each font", function()
    local font_path = DATADIR .. PATHSEP .. "fonts"
      .. PATHSEP .. "CaskaydiaCoveNerdFontMono-SemiLight.ttf"
    local full = renderer.font.load(font_path, 15 * SCALE, {
      antialiasing = "subpixel", hinting = "full", ligatures = false,
    })
    local copy = full:copy(15 * SCALE)
    local slight = full:copy(15 * SCALE, { hinting = "slight" })
    local text = "────────────────────────"
    local full_canvas = canvas.new(260 * SCALE, 32 * SCALE, {18, 20, 28, 255}, true)
    local copy_canvas = canvas.new(260 * SCALE, 32 * SCALE, {18, 20, 28, 255}, true)
    local slight_canvas = canvas.new(260 * SCALE, 32 * SCALE, {18, 20, 28, 255}, true)
    full_canvas:draw_text(full, text, 0.5 * SCALE, 0, {220, 225, 235, 255})
    copy_canvas:draw_text(copy, text, 0.5 * SCALE, 0, {220, 225, 235, 255})
    slight_canvas:draw_text(slight, text, 0.5 * SCALE, 0, {220, 225, 235, 255})
    full_canvas:render()
    copy_canvas:render()
    slight_canvas:render()

    local full_pixels = full_canvas:get_pixels(0, 0, 260 * SCALE, 32 * SCALE)
    test.equal(copy_canvas:get_pixels(0, 0, 260 * SCALE, 32 * SCALE), full_pixels)
    test.ok(
      slight_canvas:get_pixels(0, 0, 260 * SCALE, 32 * SCALE) ~= full_pixels,
      "a font copy with a different hint policy must own different glyph pixels"
    )

    local generation = full:get_generation()
    full:set_size(16 * SCALE)
    test.ok(full:get_generation() > generation)
    test.equal(copy:get_size(), 15 * SCALE)
  end)

  test.test("supports canvas pixel, copy and image loading operations", function(context)
    local c = canvas.new(2, 2, {0, 0, 0, 255}, true)
    local width, height = c:get_size()
    test.equal(width, 2)
    test.equal(height, 2)

    local pixels = string.char(
      255, 0, 0, 255,
      0, 255, 0, 255,
      0, 0, 255, 255,
      255, 255, 255, 255
    )
    c:set_pixels(pixels, 0, 0, 2, 2)
    local readback = c:get_pixels(0, 0, 2, 2)
    test.type(readback, "string")
    test.equal(#readback, #pixels)

    local copy = c:copy()
    local copy_width, copy_height = copy:get_size()
    test.equal(copy_width, 2)
    test.equal(copy_height, 2)

    local scaled = c:scaled(4, 4, "nearest")
    local scaled_width, scaled_height = scaled:get_size()
    test.equal(scaled_width, 4)
    test.equal(scaled_height, 4)

    local font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf",
      12 * SCALE
    )
    test.type(c:draw_text(font, "A", 0, 0, {255, 255, 255, 255}), "number")
    c:draw_rect(0, 0, 1, 1, {0, 0, 0, 255}, true)
    c:draw_canvas(copy, 0, 0, true)
    local x, y, w, h = c:draw_poly({{0, 0}, {1, 0}, {0, 1}}, {255, 255, 255, 255})
    test.type(x, "number")
    test.type(y, "number")
    test.type(w, "number")
    test.type(h, "number")
    c:render()

    local png_path = context.temp_root .. PATHSEP .. "sample.png"
    local saved, save_err = c:save_image(png_path)
    test.ok(saved, save_err)
    local loaded, load_err = canvas.load_image(png_path)
    test.not_nil(loaded, load_err)
    local loaded_width, loaded_height = loaded:get_size()
    test.equal(loaded_width, 2)
    test.equal(loaded_height, 2)

    local removed, remove_err = os.remove(png_path)
    test.ok(removed, remove_err)

    local svg_path = context.temp_root .. PATHSEP .. "sample.svg"
    write_file(svg_path, [[<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="#fff"/></svg>]])
    local svg_canvas, svg_err = canvas.load_svg_image(svg_path, 32, 32)
    test.not_nil(svg_canvas, svg_err)
    local svg_width, svg_height = svg_canvas:get_size()
    test.equal(svg_width, 32)
    test.equal(svg_height, 32)
  end)

  test.test("opens project-relative images through core.open_file", function(context)
    local c = canvas.new(2, 2, {255, 0, 0, 255}, true)
    local image_path = context.project_temp_root .. PATHSEP .. "open-file-image.png"
    local saved, save_err = c:save_image(image_path)
    test.ok(saved, save_err)

    local relative_path = common.relative_path(core.root_project().path, image_path)
    local cwd = system.getcwd()
    system.chdir(context.temp_root)
    local view = core.open_file(relative_path)
    system.chdir(cwd)

    test.not_nil(view)
    test.ok(view:extends(ImageView))
    test.equal(view.path, image_path)
  end)

  test.test("uses smooth filtering when the image viewer scales raster images", function(context)
    local image_path = context.temp_root .. PATHSEP .. "smooth-scale.png"
    write_file(image_path, "not-a-real-png")
    local original_load_image = canvas.load_image
    local scale_mode
    canvas.load_image = function()
      return {
        get_size = function() return 100, 50 end,
        scaled = function(_, width, height, mode)
          scale_mode = mode
          return { get_size = function() return width, height end }
        end,
      }
    end

    local ok, err = pcall(function()
      local view = ImageView(image_path, "fixed", 0.5)
      view.size.x, view.size.y = 200, 100
      view:scale_image()
      test.equal(scale_mode, "linear")
    end)
    canvas.load_image = original_load_image
    if not ok then error(err, 0) end
  end)

  test.test("draws text with maximum-size FFI font fallback group", function()
    local font_path = DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf"
    local base_font = renderer.font.load(font_path, 12 * SCALE)
    test.not_nil(base_font)

    local fonts = { base_font }
    for i = 2, 10 do
      fonts[i] = base_font:copy((11 + i) * SCALE)
      test.not_nil(fonts[i])
    end
    local group = renderer.font.group(fonts)
    test.not_nil(group)
    test.equal(#group:get_path(), 10)

    local window = renwindow.create("graphics-font-fallback-test-window", 64, 64)
    test.not_nil(window)
    renderer.begin_frame(window)
    for _ = 1, 20 do
      test.type(renderer.draw_text(group, "fallback", 0, 0, {255, 255, 255, 255}), "number")
    end
    renderer.end_frame()
    collectgarbage("collect")
  end)

  test.test("renders to a temporary window", function()
    local font = renderer.font.load(
      DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf",
      12 * SCALE
    )
    local window = renwindow.create("graphics-test-window", 64, 64)
    test.not_nil(window)

    local width, height = renwindow.get_size(window)
    test.ok(width > 0)
    test.ok(height > 0)

    local refresh_rate = renwindow.get_refresh_rate(window)
    test.ok(refresh_rate == nil or refresh_rate > 0)

    renderer.show_debug(false)
    renderer.begin_frame(window)
    renderer.set_clip_rect(0, 0, width, height)
    renderer.draw_rect(0, 0, width, height, {0, 0, 0, 255})
    renderer.draw_rounded_rect(8, 8, 32, 24, 6, {255, 255, 255, 255})
    test.type(renderer.draw_text(font, "A", 0, 0, {255, 255, 255, 255}), "number")

    local offscreen = canvas.new(4, 4, {0, 0, 0, 255}, true)
    renderer.draw_canvas(offscreen, 0, 0)
    local box_x, box_y, box_w, box_h =
      renderer.draw_poly({{0, 0}, {4, 0}, {0, 4}}, {255, 255, 255, 255})
    test.type(box_x, "number")
    test.type(box_y, "number")
    test.type(box_w, "number")
    test.type(box_h, "number")

    local rendered = renderer.to_canvas(0, 0, 1, 1)
    test.not_nil(rendered)
    local rendered_width, rendered_height = rendered:get_size()
    test.equal(rendered_width, 1)
    test.equal(rendered_height, 1)
    renderer.end_frame()

    local color = renwindow.get_color(window, 0, 0)
    test.type(color, "table")
    test.equal(#color, 4)
    local rounded_corner = renwindow.get_color(window, 8, 8)
    local rounded_center = renwindow.get_color(window, 24, 20)
    for channel = 1, 3 do
      test.ok(rounded_corner[channel] < 5)
      test.ok(rounded_center[channel] > 250)
    end
    test.equal(rounded_corner[4], 255)
    test.equal(rounded_center[4], 255)
  end)
end)
