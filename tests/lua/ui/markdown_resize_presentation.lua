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

local TEXT = "# Title\n\nA paragraph with **bold** text.\n\n| A | B |\n| --- | --- |\n| one | two |\n\nplain"

test.describe("Markdown presentation across a width change", function()
  test.before_each(function(context)
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    config.markdown_live_editor = context.live
    if context.view then
      context.view.discard_buffer_on_close = true
      context.view:on_close()
    end
  end)

  for _, wrapping in ipairs({ true, false }) do
    local mode = wrapping and "wrapped" or "unwrapped"
    test.it("rebuilds only width-dependent lines in a " .. mode .. " view", function(context)
      local view = make_view(TEXT, wrapping)
      context.view = view
      view.buffer:set_selection(9, 1)
      refresh(view)
      local paragraph = test.not_nil(view:resolve_line_render(3))
      local row = test.not_nil(view:resolve_line_render(7))

      view.size.x = 600
      if wrapping then view:update_wrap_cache() end
      linewrapping.complete_async_reconstruction(view)

      test.ok(view:resolve_line_render(3) == paragraph, "the paragraph was rebuilt")
      test.ok(view:resolve_line_render(7) ~= row, "the table row kept its old width")
    end)
  end
end)
