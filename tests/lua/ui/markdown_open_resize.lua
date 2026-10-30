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
    local instance = model.peek(view.buffer)
    if instance and instance.status == "ready" then
      wrapping.complete_async_reconstruction(view)
      view:update()
      return
    end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  error("Markdown layout did not settle")
end

local function visible_geometry(view, lines)
  local result = {}
  for _, line in ipairs(lines) do
    local x, y = view:get_line_screen_position(line, 1)
    local rows = view:get_visual_row_count_for_line(line)
    test.ok(type(x) == "number" and type(y) == "number" and rows > 0,
      "line " .. line .. " has no visible layout")
    result[line] = { x = x, y = y, rows = rows }
  end
  return result
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

  test.it("keeps rendered rows usable while resizing a large Markdown file", function(context)
    local text = string.rep("# Heading\n\nLong paragraph with **bold** and a [link](https://example.com) that wraps several times.\n\n", 300)
    local buffer = Buffer("markdown-open-resize.md", nil, true)
    buffer:insert(1, 1, text)
    local view = Editor(buffer)
    context.views[#context.views + 1] = view
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 900, 700
    core.active_view = view
    view:set_wrapping_enabled(true)
    markdown.live_render.refresh_view(view)
    settle(view)
    local lines = { 1, 3, 299, 599, 899 }
    local old_geometry = visible_geometry(view, lines)

    view.size.x = 650
    view:update()
    visible_geometry(view, lines)

    settle(view)
    local fresh = Editor(buffer)
    context.views[#context.views + 1] = fresh
    fresh.position.x, fresh.position.y = 0, 0
    fresh.size.x, fresh.size.y = 650, 700
    fresh:set_wrapping_enabled(true)
    markdown.live_render.refresh_view(fresh)
    settle(fresh)
    test.equal(wrapping.get_total_wrapped_lines(view), wrapping.get_total_wrapped_lines(fresh))
    local resized, expected_geometry = visible_geometry(view, lines), visible_geometry(fresh, lines)
    for _, line in ipairs(lines) do
      local actual, expected = resized[line], expected_geometry[line]
      test.ok(actual.rows >= old_geometry[line].rows,
        "narrower line " .. line .. " lost wrapped rows")
      test.equal(actual.rows, expected.rows, "line " .. line .. " has the wrong row count")
      test.equal(actual.y + view.scroll.y, expected.y + fresh.scroll.y,
        "line " .. line .. " must have the same layout")
    end
  end)
end)
