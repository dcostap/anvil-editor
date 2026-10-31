local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function make_view(text, wrapping)
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename("resize-presentation.md", nil)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 900, 600
  view:set_wrapping_enabled(wrapping)
  return view, buffer
end

local function refresh(view)
  markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.buffer)
  local deadline = system.get_time() + 5
  while instance and instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then system.sleep(0.001) end
  end
  test.equal(test.not_nil(instance).status, "ready", instance.reason)
  linewrapping.complete_async_reconstruction(view)
end

local TEXT = "# Title\n\n" .. string.rep("A paragraph with **bold** text. ", 20)
  .. "\n\n| A | B |\n| --- | --- |\n| one | two |\n\nplain"

local function snapshot(view)
  local result = {}
  for _, line in ipairs({ 1, 3, 5, 6, 7, 9 }) do
    local x, y = view:get_line_screen_position(line, 1)
    result[line] = {
      rows = view:get_visual_row_count_for_line(line), x = x, y = y,
    }
  end
  return result
end

test.describe("Markdown presentation across a width change", function()
  test.before_each(function(context)
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    config.markdown_live_editor = context.live
    for _, view in ipairs(context.views or {}) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
  end)

  for _, wrapping in ipairs({ true, false }) do
    local mode = wrapping and "wrapped" or "unwrapped"
    test.it("keeps rendered content correct after resizing a " .. mode .. " view", function(context)
      context.views = {}
      local view = make_view(TEXT, wrapping)
      context.views[#context.views + 1] = view
      view.buffer:set_selection(9, 1)
      refresh(view)
      local wide_rows = view:get_visual_row_count_for_line(3)

      view.size.x = 600
      view:update()
      linewrapping.complete_async_reconstruction(view)
      view:update()
      local resized = snapshot(view)

      if wrapping then
        test.ok(resized[3].rows > wide_rows,
          "the narrower view did not wrap the long paragraph")
      end

      local reference = make_view(TEXT, wrapping)
      context.views[#context.views + 1] = reference
      reference.size.x = 600
      reference.buffer:set_selection(9, 1)
      refresh(reference)
      test.same(resized, snapshot(reference),
        "resized Markdown geometry differs from a view opened at the same width")
    end)
  end
end)
