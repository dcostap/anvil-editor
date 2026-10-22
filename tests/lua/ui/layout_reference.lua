local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local layout_reference = require "core.layout_reference"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local test = require "core.test"

local function make_view(context, name, text, width)
  local buffer = Buffer(name, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = width or 900, 400
  view:set_wrapping_enabled(true)
  return view, buffer
end

local function markdown_ready(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    view:update()
    if instance.status == "ready" and not view.__async_wrap_reconstruction then break end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready")
end

local NOTE = table.concat({
  "# Heading",
  "",
  "A paragraph with a footnote[^1] and " .. string.rep("more words ", 30),
  "",
  "> [!note]- Folded",
  "> hidden body",
  "> second body line",
  "",
  "> [!tip]+ Open",
  "> shown body",
  "",
  "[^1]: The footnote text.",
  "",
  string.rep("Closing paragraph words. ", 20),
}, "\n")

test.describe("Layout reference", function()
  test.before_each(function(context)
    context.views = {}
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    config.markdown_live_editor = context.live
  end)

  test.it("matches a wrapped view with a collapsed fold", function(context)
    local view = make_view(context, "plain.txt",
      string.rep("plain text that wraps across the view width ", 8) .. "\n"
      .. string.rep("short line\n", 40), 500)
    test.ok(view:add_fold_region { line1 = 4, line2 = 9 })
    view:update()
    local report = layout_reference.compare(view)
    test.ok(report.ok, report.summary .. "\n" .. table.concat(report.mismatches or {}, "\n"))
    test.ok(not report.skipped, "a settled view must be compared")
  end)

  test.it("matches a Markdown view with Callouts and an inline footnote", function(context)
    local view, buffer = make_view(context, "reference.md", NOTE, 1000)
    markdown.live_render.refresh_view(view)
    markdown_ready(view)
    view:with_selection_state(function() buffer:set_selection(#buffer.lines, 1) end)
    view:update()
    test.ok(view:has_collapsed_folds(), "the folded Callout must start collapsed")
    local report = layout_reference.compare(view)
    test.ok(report.ok, report.summary .. "\n" .. table.concat(report.mismatches or {}, "\n"))
  end)

  test.it("matches unchanged wrapped rows after a local edit", function(context)
    local view, buffer = make_view(context, "edited.txt",
      string.rep(string.rep("words that wrap ", 12) .. "\n", 10), 500)
    view:update()
    buffer:insert(2, 1, "x")
    view:update()
    local report = layout_reference.compare(view)
    test.ok(report.ok, report.summary .. "\n" .. table.concat(report.mismatches or {}, "\n"))
  end)

  test.it("reports a row height that a provider changed without invalidation", function(context)
    local view = make_view(context, "heights.txt", string.rep("line\n", 30))
    local heights = {}
    view:add_visual_metric_provider("test.heights", {
      line_height = function(_, _, line) return heights[line] end,
    })
    view:update()
    view:get_scrollable_size()
    -- The provider does not report this change, so the view keeps its old row height.
    heights[5] = view:get_line_height() + 0.5
    local report = layout_reference.compare(view)
    heights[5] = nil
    test.not_ok(report.ok, "a stale row height must be reported")
    test.ok((report.kinds.height or 0) >= 1, report.summary)
  end)

  test.it("leaves a view whose Markdown publication is pending for later", function(context)
    local view, buffer = make_view(context, "pending.md", NOTE)
    markdown.live_render.refresh_view(view)
    markdown_ready(view)
    buffer:insert(1, 1, "x")
    test.equal(layout_reference.pending_reason(view), "Markdown model publication")
  end)
end)
