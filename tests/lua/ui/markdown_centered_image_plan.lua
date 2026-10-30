local Buffer = require "core.buffer"
local Editor = require "core.editor"
local config = require "core.config"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local centered_editor = require "plugins.centered_editor"
local wrapping = require "core.linewrapping"
local test = require "core.test"
local worker_pool = require "core.worker_pool"
local renwindow = require "renwindow"

local function wait_ready(buffer)
  local deadline = system.get_time() + 5
  local instance = test.not_nil(markdown_model.peek(buffer))
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

test.it("draws a centered image block inside the reading lane", function()
  local cfg = config.plugins.centered_editor
  local old_pane_views_only = cfg.pane_views_only
  local old_live, old_images = config.markdown_live_editor, config.markdown_live_render_images
  local old_load = canvas.load_image_data
  cfg.pane_views_only = false
  config.markdown_live_editor = true
  config.markdown_live_render_images = true
  canvas.load_image_data = function()
    return {
      get_size = function() return 400, 200 end,
      scaled = function(self) return self end,
    }
  end
  local buffer = Buffer("centered-image.md", "centered-image.md", true)
  buffer:insert(1, 1, "before\n\n![](data:image/png;base64,iVBORw0KGgo=)\n# after\n")
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.size.x, view.size.y = 1600, 700
  local ok, err = pcall(function()
    view:set_wrapping_enabled(true)
    markdown.live_render.refresh_view(view)
    wait_ready(buffer)
    wrapping.complete_async_reconstruction(view)
    test.ok(centered_editor.should_center(view), "the view is not centered")

    local draws = {}
    local old_draw, old_scaled = renderer.draw_canvas, renderer.draw_canvas_scaled
    renderer.draw_canvas = function(image, x, y)
      local width, height = image:get_size()
      draws[#draws + 1] = { x = x, y = y, width = width, height = height }
    end
    renderer.draw_canvas_scaled = function(_, x, y, width, height)
      draws[#draws + 1] = { x = x, y = y, width = width, height = height }
    end
    local window = renwindow.create("centered-image-plan", 1600, 700)
    renderer.begin_frame(window)
    local drawn, draw_error = pcall(view.draw, view)
    renderer.end_frame()
    renderer.draw_canvas, renderer.draw_canvas_scaled = old_draw, old_scaled
    if not drawn then error(draw_error, 0) end
    test.equal(#draws, 1, "the image block did not draw")
    local editor_x, editor_width = centered_editor.get_editor_rect(view)
    test.ok(draws[1].x >= editor_x, "the image starts outside the reading lane")
    test.ok(draws[1].x + draws[1].width <= editor_x + editor_width,
      "the image ends outside the reading lane")
    test.ok(draws[1].width > 0 and draws[1].height > 0)
  end)
  markdown.live_render.release(view, "test")
  markdown_model.close(buffer, "test")
  view:on_close()
  cfg.pane_views_only = old_pane_views_only
  config.markdown_live_editor, config.markdown_live_render_images = old_live, old_images
  canvas.load_image_data = old_load
  if not ok then error(err, 0) end
end)
