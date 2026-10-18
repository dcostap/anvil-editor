local Buffer = require "core.buffer"
local Editor = require "core.editor"
local image_animation = require "core.image_animation"
local images = require "core.markdown.images"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

-- 2x2 GIF: red for 50 ms, green for 100 ms, blue for 150 ms, looping.
local THREE_FRAME_GIF_BASE64 = "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQEBQAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQECgAAACwAAAAAAgACAIEA/wAAAAAAAAAAAAAIBgABCAQQEAAh+QQEDwAAACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"

local function pixel(image)
  local r, g, b = image:get_pixels(0, 0, 1, 1):byte(1, 3)
  if r > 200 and g < 50 and b < 50 then return "red" end
  if g > 200 and r < 50 and b < 50 then return "green" end
  if b > 200 and r < 50 and g < 50 then return "blue" end
  return string.format("rgb(%d,%d,%d)", r, g, b)
end

test.describe("Markdown Live Preview animated images", function()
  test.it("plays an embedded GIF while its line is drawn", function()
    local gif_path = USERDIR .. PATHSEP .. "markdown-animated-" .. system.get_process_id() .. ".gif"
    local file = test.not_nil(io.open(gif_path, "wb"))
    file:write(test.not_nil(images.decode_data_image("data:image/gif;base64," .. THREE_FRAME_GIF_BASE64)))
    file:close()
    local filename = gif_path:match("[^/\\]+$")
    local old_draw_canvas = renderer.draw_canvas
    local old_draw_canvas_scaled = renderer.draw_canvas_scaled
    local old_draw_text = renderer.draw_text
    local old_draw_rect = renderer.draw_rect
    local drawn
    renderer.draw_canvas = function(image) drawn = pixel(image) end
    renderer.draw_canvas_scaled = function(image) drawn = pixel(image) end
    renderer.draw_text = function(font, text, x) return x + font:get_width(text) end
    renderer.draw_rect = function() end

    local ok, err = pcall(function()
      local buffer = Buffer(gif_path .. ".md", gif_path .. ".md", true)
      buffer:insert(1, 1, "![[" .. filename .. "]]\nnext")
      local view = Editor(buffer)
      view.position.x, view.position.y = 0, 0
      view.size.x, view.size.y = 500, 200
      view:set_wrapping_enabled(false)
      buffer:set_selection(2, 1)
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(markdown_model.peek(buffer))
      local deadline = system.get_time() + 5
      while instance.status ~= "ready" and system.get_time() < deadline do
        local pool = worker_pool.current_system()
        if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
        if instance.status ~= "ready" then system.sleep(0.001) end
      end
      test.equal(instance.status, "ready", instance.reason)

      local x, y = view:get_line_screen_position(1)
      view:draw_line_text(1, x, y)
      test.equal(drawn, "red")
      -- The first frame lasts 50 ms.
      system.sleep(0.08)
      view:draw_line_text(1, x, y)
      test.equal(drawn, "green")
    end)
    renderer.draw_canvas = old_draw_canvas
    renderer.draw_canvas_scaled = old_draw_canvas_scaled
    renderer.draw_text = old_draw_text
    renderer.draw_rect = old_draw_rect
    image_animation.close_all()
    os.remove(gif_path)
    if not ok then error(err, 0) end
  end)
end)
