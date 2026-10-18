local image_animation = require "core.image_animation"
local images = require "core.markdown.images"
local test = require "core.test"

-- 2x2 GIF: red for 50 ms, green for 100 ms, blue for 150 ms, looping.
local THREE_FRAME_GIF_BASE64 = "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQEBQAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQECgAAACwAAAAAAgACAIEA/wAAAAAAAAAAAAAIBgABCAQQEAAh+QQEDwAAACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"
-- 2x2 red GIF with a single frame.
local ONE_FRAME_GIF_BASE64 = "R0lGODdhAgACAIEAAP8AAAAAAAAAAAAAACwAAAAAAgACAAAIBgABCAQQEAA7"

local function gif_url(base64)
  return "data:image/gif;base64," .. base64
end

local function gif_bytes(base64)
  return assert(images.decode_data_image(gif_url(base64)))
end

local function pixel(image)
  local r, g, b = image:get_pixels(0, 0, 1, 1):byte(1, 3)
  if r > 200 and g < 50 and b < 50 then return "red" end
  if g > 200 and r < 50 and b < 50 then return "green" end
  if b > 200 and r < 50 and g < 50 then return "blue" end
  return string.format("rgb(%d,%d,%d)", r, g, b)
end

test.describe("Streaming image animations", function()
  test.after_each(function()
    image_animation.close_all()
    images.clear_assets()
  end)

  test.it("decodes frames into one canvas and loops", function()
    local animation = assert(canvas.open_animation_data(gif_bytes(THREE_FRAME_GIF_BASE64), "gif"))
    local image = animation:get_canvas()
    test.equal(pixel(image), "red")
    test.equal(animation:get_frame_duration(), 50)

    test.equal(animation:next_frame(), 100)
    test.equal(pixel(image), "green")
    test.equal(animation:next_frame(), 150)
    test.equal(pixel(image), "blue")
    test.equal(animation:next_frame(), 50)
    test.equal(pixel(image), "red")
    test.equal(animation:get_canvas(), image)
    animation:close()
  end)

  test.it("reports that a single-frame image has nothing to animate", function()
    local animation = assert(canvas.open_animation_data(gif_bytes(ONE_FRAME_GIF_BASE64), "gif"))
    test.equal(animation:next_frame(), false)
    animation:close()
  end)

  test.it("marks GIF assets as animated and opens them", function()
    local entry = images.get_asset(gif_url(THREE_FRAME_GIF_BASE64))
    test.equal(entry.status, "ready")
    test.equal(entry.animation_type, "gif")

    local animation = assert(images.open_animation(entry))
    test.equal(pixel(animation:get_canvas()), "red")
    animation:close()
  end)

  test.it("advances a drawn animation once each frame is due", function()
    local entry = images.get_asset(gif_url(THREE_FRAME_GIF_BASE64))
    local now = system.get_time()
    local function draw(at)
      return image_animation.frame(entry, {
        version = entry.image, open = images.open_animation, width = 2, height = 2, now = at,
      })
    end

    test.equal(pixel(draw(now)), "red")
    test.equal(pixel(draw(now + 0.04)), "red")
    test.equal(pixel(draw(now + 0.05)), "green")
    test.equal(pixel(draw(now + 0.15)), "blue")
  end)

  test.it("does not replay frames missed while the image was not drawn", function()
    local entry = images.get_asset(gif_url(THREE_FRAME_GIF_BASE64))
    local now = system.get_time()
    local function draw(at)
      return image_animation.frame(entry, {
        version = entry.image, open = images.open_animation, width = 2, height = 2, now = at,
      })
    end

    test.equal(pixel(draw(now)), "red")
    -- Five frame periods pass undrawn; the next draw shows one new frame.
    test.equal(pixel(draw(now + 0.5)), "green")
    test.equal(pixel(draw(now + 0.55)), "green")
    test.equal(pixel(draw(now + 0.6)), "blue")
  end)

  test.it("draws the still image for single-frame and oversized animations", function()
    local still = images.get_asset(gif_url(ONE_FRAME_GIF_BASE64))
    local now = system.get_time()
    local opts = { version = still.image, open = images.open_animation, width = 2, height = 2, now = now }
    test.ok(image_animation.frame(still, opts))
    opts.now = now + 0.2
    test.equal(image_animation.frame(still, opts), nil)

    local large = images.get_asset(gif_url(THREE_FRAME_GIF_BASE64))
    local opened = false
    test.equal(image_animation.frame(large, {
      version = large.image, width = 4000, height = 4000, now = now,
      open = function() opened = true end,
    }), nil)
    test.equal(opened, false)
  end)
end)
