local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local wrapping = require "core.linewrapping"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local test = require "core.test"

local function settle(view)
  local deadline = system.get_time() + 10
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    view:update()
    if model.peek(view.buffer) and model.peek(view.buffer).status == "ready"
      and not view.__async_wrap_reconstruction then return end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  error("Markdown layout did not settle")
end

test.describe("Markdown opening after a width change", function()
  test.before_each(function(context)
    context.live = config.markdown_live_editor
    context.active = core.active_view
    context.views = {}
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    config.markdown_live_editor = context.live
    core.active_view = context.active
  end)

  test.it("keeps the committed rows until the resized presentation is ready", function(context)
    local text = string.rep("# Heading\n\nLong paragraph with **bold** and a [link](https://example.com) that wraps several times.\n\n", 300)
    local buffer = Buffer("markdown-open-resize.md", nil, true)
    buffer:insert(1, 1, text)
    local view = Editor(buffer)
    context.views[#context.views + 1] = view
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 900, 700
    core.active_view = view
    view:set_wrapping_enabled(true)
    local committed = view.wrapped_lines
    markdown.live_render.refresh_view(view)
    test.ok(view.__async_wrap_reconstruction, "the presentation must still be pending")
    view.size.x = 650
    view:update_wrap_cache()
    test.ok(view.__async_wrap_reconstruction, "the resized presentation must remain pending")
    test.equal(view.wrapped_lines, committed, "the old rows stay visible until publication")

    settle(view)
    test.equal(view.wrapped_settings.width, view:compute_wrap_width())
    local fresh = Editor(buffer)
    context.views[#context.views + 1] = fresh
    fresh.position.x, fresh.position.y = 0, 0
    fresh.size.x, fresh.size.y = 650, 700
    fresh:set_wrapping_enabled(true)
    markdown.live_render.refresh_view(fresh)
    settle(fresh)
    test.equal(wrapping.get_total_wrapped_lines(view), wrapping.get_total_wrapped_lines(fresh))
    for _, line in ipairs { 1, 3, 299, 599, 899 } do
      local _, actual = view:get_line_screen_position(line, 1)
      local _, expected = fresh:get_line_screen_position(line, 1)
      test.equal(actual + view.scroll.y, expected + fresh.scroll.y,
        "line " .. line .. " must have the same layout")
    end
  end)
end)
