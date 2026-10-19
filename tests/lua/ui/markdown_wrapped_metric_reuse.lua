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

-- A collapsed callout folds its body, so the note's rows are composed from folds.
local FOLDED_NOTE = "> [!note]- Folded\n> hidden body\n> second body line\n\nParagraph\n\n"
  .. string.rep("## Other heading\n\nother text\n\n", 30)

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

  test.it("keeps unrelated heights when typing below a collapsed callout", function(context)
    local view, buffer = make_view(context, FOLDED_NOTE)
    core.active_view = view
    test.ok(view:has_collapsed_folds(), "the callout must start collapsed")
    view:with_selection_state(function() buffer:set_selection(5, #buffer.lines[5]) end)
    local before = geometry(view)
    local rebuilds = view:get_render_cache_diagnostics().metric_full_rebuilds
    view:on_text_input(string.rep(" more words", 40))
    local actual = geometry(view)
    test.ok(actual[6] > before[6], "the edit must add wrapped rows")
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

  test.it("keeps unrelated heights when typing above a collapsed callout", function(context)
    local view, buffer = make_view(context, "Paragraph\n\n" .. FOLDED_NOTE)
    core.active_view = view
    test.ok(view:has_collapsed_folds(), "the callout must start collapsed")
    view:with_selection_state(function() buffer:set_selection(1, #buffer.lines[1]) end)
    local before = geometry(view)
    local rebuilds = view:get_render_cache_diagnostics().metric_full_rebuilds
    view:on_text_input(string.rep(" more words", 40))
    local actual = geometry(view)
    test.ok(actual[2] > before[2], "the edit must add wrapped rows")
    test.equal(view:get_render_cache_diagnostics().metric_full_rebuilds, rebuilds,
      "local wrapping must not rebuild every row height")
    ready(view)
    view:with_selection_state(function() buffer:set_selection(#buffer.lines, 1) end)
    actual = geometry(view)
    -- A fresh view would show the callout header before its fold collapsed,
    -- so compare with every row measured again from the current presentation.
    view:invalidate_visual_metrics()
    local expected = geometry(view)
    for line = 1, #expected do
      test.equal(actual[line], expected[line], "line " .. line .. " screen y")
    end
  end)

  test.it("keeps unrelated heights on the first edit above an expanded callout", function(context)
    local view, buffer = make_view(context,
      "Paragraph\n\n> [!tip]+ Open\n> shown body\n\n" .. FOLDED_NOTE)
    core.active_view = view
    test.ok(view:has_collapsed_folds(), "the folded callout must start collapsed")
    view:with_selection_state(function() buffer:set_selection(1, #buffer.lines[1]) end)
    geometry(view)
    local rebuilds = view:get_render_cache_diagnostics().metric_full_rebuilds
    view:on_text_input(" more")
    geometry(view)
    test.equal(view:get_render_cache_diagnostics().metric_full_rebuilds, rebuilds,
      "an edit above the folds must not rebuild every row height")
  end)

  test.it("keeps unrelated heights when the caret moves past a collapsed callout", function(context)
    local view, buffer = make_view(context, FOLDED_NOTE)
    core.active_view = view
    view:with_selection_state(function() buffer:set_selection(7, 1) end)
    geometry(view)
    local rebuilds = view:get_render_cache_diagnostics().metric_full_rebuilds
    -- Each step leaves one heading and enters the next, revealing its source.
    for _ = 1, 4 do
      view:with_selection_state(function()
        local line = buffer:get_selection()
        buffer:set_selection(line + 4, 1)
      end)
      view:update()
      geometry(view)
    end
    test.equal(view:get_render_cache_diagnostics().metric_full_rebuilds, rebuilds,
      "moving the caret must not rebuild every row height")
    -- Compare row positions, not a scroll that is still animating.
    view.scroll.y = view.scroll.to.y
    local actual = geometry(view)
    local fresh = make_view(context, FOLDED_NOTE)
    fresh:with_selection_state(function() fresh.buffer:set_selection(buffer:get_selection(), 1) end)
    local expected = geometry(fresh)
    for line = 1, #expected do
      test.equal(actual[line], expected[line], "line " .. line .. " screen y")
    end
  end)
end)
