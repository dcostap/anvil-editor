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

  test.it("replaces selected Markdown containing long data-image rows", function()
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

    view:with_selection_state(function() buffer:text_input(source) end)

    test.equal(#buffer.lines, #lines)
    test.equal((buffer.lines[133] or ""):gsub("\n$", ""), data_image)

    markdown.live_render.release(view, "test")
    markdown.live_render.release(peer, "test")
    markdown_model.close(buffer, "test")
  end)

  -- Pasted screenshots arrive as data URIs, so one line holds the encoded image.
  local function open_data_image_note(name)
    local old_images, old_load = config.markdown_live_render_images, canvas.load_image_data
    config.markdown_live_render_images = true
    canvas.load_image_data = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end
    local data_image = "![](data:image/png;base64," .. string.rep("A", 2000000) .. ")"
    local buffer = Buffer(name, name, true)
    buffer:insert(1, 1, "before\n\n" .. data_image .. "\n# Heading\nafter")
    buffer:clear_undo_redo()
    local view = Editor(buffer)
    view.size.x, view.size.y = 800, 800
    view:set_wrapping_enabled(true)
    wait_ready(view)
    return view, function()
      markdown.live_render.release(view, "test")
      markdown_model.close(buffer, "test")
      view:on_close()
      config.markdown_live_render_images, canvas.load_image_data = old_images, old_load
    end
  end

  test.it("lays out a long data-image line as an image block", function()
    local view, close = open_data_image_note("data-image-layout.md")

    linewrapping.complete_async_reconstruction(view)
    local render = view:get_line_render(3)

    local image
    for _, fragment in ipairs(render and render.fragments or {}) do
      if fragment.widget and fragment.image_block then image = fragment end
    end
    close()
    test.not_nil(image, "the data image did not render as an image block")
  end)

  test.it("keeps a data-image line available after repeated lookups", function()
    local view, close = open_data_image_note("data-image-lookup.md")
    linewrapping.complete_async_reconstruction(view)
    for _ = 1, 2 do view:get_line_render(3) end
    local again = view:get_line_render(3)
    local image
    for _, fragment in ipairs(again and again.fragments or {}) do
      if fragment.widget and fragment.image_block then image = fragment break end
    end
    close()
    test.not_nil(image, "the data image disappeared after repeated line lookups")
  end)

  test.it("resizes a data-image block when the view becomes narrow", function()
    local view, close = open_data_image_note("data-image-resize.md")
    linewrapping.complete_async_reconstruction(view)
    local function image_width()
      local render = test.not_nil(view:get_line_render(3))
      for _, fragment in ipairs(render.fragments or {}) do
        if fragment.widget and fragment.image_block then return fragment.widget.width end
      end
    end
    local original_width = test.not_nil(image_width())

    view.size.x = 60
    view:update()
    linewrapping.complete_async_reconstruction(view)
    local resized_width = image_width()
    close()
    test.not_nil(resized_width)
    test.ok(resized_width < original_width, "the image did not fit the narrow view")
  end)

  -- The pointer rests over the view while the wheel scrolls, so each frame
  -- resolves the position under it.
  test.it("resolves a pointer past the end of a data-image line", function()
    local view, close = open_data_image_note("data-image-pointer.md")
    linewrapping.complete_async_reconstruction(view)
    local x, y = view:get_line_screen_position(3, 1)

    local line, col = view:resolve_screen_position(view.position.x + view.size.x - 20, y + 1)
    local length = #view.buffer.lines[3]
    close()
    test.equal(line, 3)
    test.equal(col, length)
  end)
end)
