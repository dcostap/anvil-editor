local Buffer = require "core.buffer"
local Editor = require "core.editor"
local config = require "core.config"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local centered_editor = require "plugins.centered_editor"
local wrapping = require "core.linewrapping"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

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

-- The reading lane draws with substituted geometry every frame. An image
-- block's layout depends on width, so a plan keyed by that temporary width
-- was rebuilt once for update and once for drawing, every frame.
test.it("keeps a centered image block's render plan while the lane draws", function()
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

    local plan = test.not_nil(view:get_line_render(3))
    local drawn = centered_editor.with_editor_geometry(view, function()
      return view:get_line_render(3)
    end)
    test.ok(drawn == plan, "drawing in the reading lane rebuilt the image line's plan")
    test.ok(view:get_line_render(3) == plan, "leaving the reading lane rebuilt the image line's plan")
  end)
  markdown.live_render.release(view, "test")
  markdown_model.close(buffer, "test")
  view:on_close()
  cfg.pane_views_only = old_pane_views_only
  config.markdown_live_editor, config.markdown_live_render_images = old_live, old_images
  canvas.load_image_data = old_load
  if not ok then error(err, 0) end
end)
