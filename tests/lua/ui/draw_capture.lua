local core = require "core"
local test = require "core.test"

local black = { 0, 0, 0, 255 }
local red = { 255, 0, 0, 255 }
local green = { 0, 255, 0, 255 }

local function load_font()
  return renderer.font.load(
    DATADIR .. PATHSEP .. "fonts" .. PATHSEP .. "FiraSans-Regular.ttf", 12 * SCALE
  )
end

local function is_red(color) return color[1] > 240 and color[2] < 10 end
local function is_green(color) return color[2] > 240 and color[1] < 10 end
local function is_black(color) return color[1] < 10 and color[2] < 10 and color[3] < 10 end

-- Draws a frame: black, then `draw`. Returns what `draw` returns.
local function frame(draw)
  renderer.begin_frame(core.window)
  renderer.set_clip_rect(0, 0, 40, 24)
  renderer.draw_rect(0, 0, 40, 24, black)
  local a, b = draw()
  renderer.end_frame()
  return a, b
end

test.describe("native Draw Capture", function()
  test.it("draws the captured commands again in a later frame", function()
    local capture = frame(function()
      renderer.begin_capture()
      renderer.set_clip_rect(10, 0, 10, 24)
      renderer.draw_rect(0, 0, 40, 24, red)
      renderer.set_clip_rect(0, 0, 40, 24)
      return renderer.end_capture()
    end)
    test.ok(capture)

    test.equal(frame(function() return capture:draw() end), true)
    test.ok(is_red(renwindow.get_color(core.window, 15, 8)))
    test.ok(is_black(renwindow.get_color(core.window, 5, 8)), "the capture keeps its own clip")
  end)

  test.it("leaves the clip of the captured commands active after a replay", function()
    local capture = frame(function()
      renderer.begin_capture()
      renderer.set_clip_rect(0, 0, 40, 24)
      return renderer.end_capture()
    end)
    -- The replay widens the clip, so a later command outside the earlier clip still draws.
    frame(function()
      renderer.set_clip_rect(0, 0, 10, 24)
      test.equal(capture:draw(), true)
      renderer.draw_rect(20, 0, 10, 24, green)
    end)
    test.ok(is_green(renwindow.get_color(core.window, 25, 8)))
  end)

  test.it("draws a captured canvas again", function()
    local image = canvas.new(4, 4, green)
    local capture = frame(function()
      renderer.begin_capture()
      renderer.draw_canvas(image, 2, 2)
      return renderer.end_capture()
    end)
    test.ok(capture)
    test.equal(frame(function() return capture:draw() end), true)
    test.ok(is_green(renwindow.get_color(core.window, 3, 3)))
  end)

  test.it("refuses a replay after any canvas is freed", function()
    -- Free earlier garbage first, so only the captured canvas is freed below.
    collectgarbage("collect")
    collectgarbage("collect")
    local capture = frame(function()
      renderer.begin_capture()
      renderer.draw_canvas(canvas.new(4, 4, green), 2, 2)
      return renderer.end_capture()
    end)
    collectgarbage("collect")
    collectgarbage("collect")
    local ok, reason = frame(function() return capture:draw() end)
    test.equal(ok, false)
    test.equal(reason, "canvas_freed")
  end)

  test.it("refuses a replay after a captured Font changes size", function()
    local font = load_font()
    local capture = frame(function()
      renderer.begin_capture()
      renderer.draw_text(font, "stale", 0, 0, red)
      return renderer.end_capture()
    end)
    font:set_size(font:get_size() + 1)
    local ok, reason = frame(function() return capture:draw() end)
    test.equal(ok, false)
    test.equal(reason, "stale_font")
  end)

  test.it("refuses a replay after any Font is freed", function()
    local capture = frame(function()
      renderer.begin_capture()
      renderer.draw_text(load_font(), "freed", 0, 0, red)
      return renderer.end_capture()
    end)
    collectgarbage("collect")
    collectgarbage("collect")
    local ok, reason = frame(function() return capture:draw() end)
    test.equal(ok, false)
    test.equal(reason, "font_freed")
  end)
end)
