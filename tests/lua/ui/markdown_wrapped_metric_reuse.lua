local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local test = require "core.test"

local function ready(view)
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
  test.ok(not view.__async_wrap_reconstruction, "wrapped publication must finish")
end

local function make_view(context, text)
  local buffer = Buffer("wrapped-metrics-" .. #context.views .. ".md", nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 900, 700
  view:set_wrapping_enabled(true)
  markdown.live_render.refresh_view(view)
  ready(view)
  return view, buffer
end

local function geometry(view)
  local positions = {}
  for line = 1, #view.buffer.lines do
    local _, y = view:get_line_screen_position(line, 1)
    positions[line] = y + view.scroll.y
  end
  return positions
end

test.describe("Markdown wrapped metrics after edits", function()
  test.before_each(function(context)
    context.views = {}
    context.active = core.active_view
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    core.active_view = context.active
    config.markdown_live_editor = context.live
  end)

  test.it("keeps unrelated heights when typing adds wrapped rows", function(context)
    local view, buffer = make_view(context,
      "# Heading\n\nParagraph\n\n" .. string.rep("## Other heading\n\nother text\n\n", 30))
    core.active_view = view
    view:with_selection_state(function() buffer:set_selection(3, #buffer.lines[3]) end)
    local before = geometry(view)
    local rebuilds = view:get_render_cache_diagnostics().metric_full_rebuilds
    view:on_text_input(string.rep(" more words", 40))
    local actual = geometry(view)
    test.ok(actual[4] > before[4], "the edit must add wrapped rows")
    test.equal(view:get_render_cache_diagnostics().metric_full_rebuilds, rebuilds,
      "local wrapping must not rebuild every row height")
    ready(view)
    view:with_selection_state(function() buffer:set_selection(#buffer.lines, 1) end)
    actual = geometry(view)
    local fresh = make_view(context, table.concat(buffer.lines):sub(1, -2))
    fresh:with_selection_state(function() fresh.buffer:set_selection(#fresh.buffer.lines, 1) end)
    local expected = geometry(fresh)
    for line = 1, #expected do
      test.equal(actual[line], expected[line], "line " .. line .. " screen y")
    end
  end)
end)
