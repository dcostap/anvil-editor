local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local reference = require "core.layout_reference"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local test = require "core.test"

local function ready(view)
  local instance = model.peek(view.buffer)
  local deadline = system.get_time() + 15
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    view:update()
    if instance.status == "ready" and instance.published_revision == view.buffer.text_revision then return end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  error("Markdown publication did not finish")
end

test.describe("Markdown edit publication", function()
  test.before_each(function(context)
    context.active, context.live = core.active_view, config.markdown_live_editor
    config.markdown_live_editor = true
  end)
  test.after_each(function(context)
    if context.view then
      context.view.discard_buffer_on_close = true
      context.view:on_close()
    end
    core.active_view, config.markdown_live_editor = context.active, context.live
  end)

  test.it("keeps unwrapped front matter and Callout heights outside the viewport", function(context)
    local buffer = Buffer("offscreen.md", nil, true)
    buffer:insert(1, 1, "---\ntitle: Test\n---\n\n> [!note]+ Title\n> Body\n\n"
      .. string.rep("Paragraph\n\n", 20))
    local view = Editor(buffer)
    context.view = view
    view.size.x, view.size.y = 420, 380
    view:set_wrapping_enabled(false)
    core.active_view = view
    markdown.live_render.refresh_view(view)
    ready(view)
    view:reconcile_visible_line_layout()
    view:with_selection_state(function() buffer:set_selection(#buffer.lines, 1) end)
    view:scroll_to_line(#buffer.lines, false, true)
    view:update()
    local report = reference.compare(view)
    test.ok(report.ok, report.summary .. "\n" .. table.concat(report.mismatches or {}, "\n"))
  end)

  for _, wrapped in ipairs({ false, true }) do
    test.it("restores off-screen front matter geometry after pending edits / " .. tostring(wrapped), function(context)
      local buffer = Buffer("publication.md", nil, true)
      buffer:insert(1, 1, "---\ntitle: Test\n---\n\n" .. string.rep("Body\n\n", 20) .. "Tail")
      local view = Editor(buffer)
      context.view = view
      view.size.x, view.size.y = 420, 380
      view:set_wrapping_enabled(wrapped)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      ready(view)
      local before = reference.compare(view, { ui_frames = true })
      test.ok(before.ok, before.summary)
      view:with_selection_state(function() buffer:set_selection(40, 1) end)
      view:on_text_input("x")
      view:update()
      view:get_scrollable_size()
      view:with_selection_state(function() buffer:set_selection(2, 5) end)
      view:on_text_input("\n")
      test.equal(model.peek(buffer).status, "pending")
      view:update()
      view:get_scrollable_size()
      view:with_selection_state(function() buffer:set_selection(40, 1) end)
      view:on_text_input("x")
      view:update()
      view:get_scrollable_size()
      ready(view)
      local report = reference.compare(view, { ui_frames = true })
      test.ok(report.ok, report.summary .. "\n" .. table.concat(report.mismatches or {}, "\n"))
    end)
  end
end)
