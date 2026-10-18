local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function wait_ready(view)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(markdown_model.peek(view.buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

local function refresh(view)
  wait_ready(view)
  linewrapping.complete_async_reconstruction(view)
end

test.describe("Markdown long paste", function()
  test.before_each(function(context)
    context.old_markdown_live_editor = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    config.markdown_live_editor = context.old_markdown_live_editor
  end)

  test.it("replaces selected Markdown containing long data-image rows promptly", function()
    local data_image = "![](data:image/png;base64," .. string.rep("A", 59000) .. ")"
    local lines = {}
    for line = 1, 170 do
      if line == 133 or line == 153 then
        lines[line] = data_image
      else
        lines[line] = "ordinary Markdown line " .. line
      end
    end
    local source = table.concat(lines, "\n")
    local buffer = Buffer("data-image-paste.md", "data-image-paste.md", true)
    buffer:insert(1, 1, "old\nselected\nMarkdown\ntext\n")
    buffer:clear_undo_redo()
    local view, peer = Editor(buffer), Editor(buffer)
    for _, current in ipairs({ view, peer }) do
      current.size.x, current.size.y = 500, 800
      current:set_wrapping_enabled(true)
      refresh(current)
      current:get_visual_row_metric_cache()
    end
    view:set_selection_state({
      selections = { 1, 1, #buffer.lines, #buffer.lines[#buffer.lines] + 1 },
      last_selection = 1,
    })

    local started = system.get_time()
    view:with_selection_state(function() buffer:text_input(source) end)
    local elapsed = system.get_time() - started

    test.equal(#buffer.lines, #lines)
    test.equal((buffer.lines[133] or ""):gsub("\n$", ""), data_image)
    test.ok(elapsed < 2, string.format(
      "long data-image replacement blocked the editor for %.3fs", elapsed
    ))

    markdown.live_render.release(view, "test")
    markdown.live_render.release(peer, "test")
    markdown_model.close(buffer, "test")
  end)

  test.it("lays out a long data-image line promptly", function()
    local old_images, old_load = config.markdown_live_render_images, canvas.load_image_data
    config.markdown_live_render_images = true
    canvas.load_image_data = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end
    local data_image = "![](data:image/png;base64," .. string.rep("A", 2000000) .. ")"
    local buffer = Buffer("data-image-layout.md", "data-image-layout.md", true)
    buffer:insert(1, 1, "before\n\n" .. data_image .. "\n# Heading\nafter")
    buffer:clear_undo_redo()
    local view = Editor(buffer)
    view.size.x, view.size.y = 800, 800
    view:set_wrapping_enabled(true)
    wait_ready(view)

    local started = system.get_time()
    linewrapping.complete_async_reconstruction(view)
    local render = view:get_line_render(3)
    local elapsed = system.get_time() - started

    local image
    for _, fragment in ipairs(render and render.fragments or {}) do
      if fragment.widget and fragment.image_block then image = fragment end
    end
    test.not_nil(image, "the data image did not render as an image block")
    test.ok(elapsed < 0.45, string.format(
      "laying out the data-image line blocked the editor for %.3fs", elapsed
    ))

    markdown.live_render.release(view, "test")
    markdown_model.close(buffer, "test")
    config.markdown_live_render_images, canvas.load_image_data = old_images, old_load
  end)
end)
