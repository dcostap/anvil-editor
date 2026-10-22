local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local layout_reference = require "core.layout_reference"
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
end

local function make_view(context, name, text, width)
  local buffer = Buffer(name, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = width or 900, 700
  view:set_wrapping_enabled(true)
  if name:match("%.md$") then
    markdown.live_render.refresh_view(view)
    ready(view)
  end
  core.active_view = view
  return view, buffer
end

-- Read every row position, so the view resolves its complete layout.
local function read_layout(view)
  for line = 1, #view.buffer.lines do view:get_line_screen_position(line, 1) end
  return view:get_scrollable_size()
end

local function counts(view)
  local diagnostics = view:get_render_cache_diagnostics()
  return { composed = diagnostics.composed_row_builds, heights = diagnostics.metric_full_rebuilds }
end

local function same_as_fresh_view(view, opts)
  local report = layout_reference.compare(view, opts)
  test.ok(not report.skipped, "the view must be compared: " .. report.summary)
  test.ok(report.ok, report.summary .. "\n" .. table.concat(report.mismatches or {}, "\n"))
  return report
end

local FOLDED_NOTE = "Paragraph\n\n> [!note]- Folded\n> hidden body\n> second body line\n\n"
  .. string.rep("## Other heading\n\nother text\n\n", 30)

-- In a narrow view, footnotes show as rows below the block of their reference.
local FOOTNOTE_NOTE = table.concat({
  "First paragraph.",
  "",
  "A sentence with a note[^a] and an inline note^[Short inline text.] here.",
  "",
  string.rep("Paragraph text.\n\n", 20),
  "Another reference[^b] near the end.",
  "",
  "Closing paragraph.",
  "",
  "[^a]: The first definition.",
  "[^b]: The second definition.",
}, "\n")

local function make_footnote_view(context, name)
  local view, buffer = make_view(context, name, FOOTNOTE_NOTE, 420)
  view:update()
  read_layout(view)
  test.ok(view.visual_row_providers["markdown.footnotes"], "footnotes must show as rows")
  return view, buffer
end

local function footnote_row_heights(view)
  local heights = {}
  for row = 1, view:get_composed_visual_row_count() do
    local entry = view:get_visual_row_entry(row)
    if entry.provider_id == "markdown.footnotes" then
      heights[#heights + 1] = view:get_visual_row_height(row)
    end
  end
  return heights
end

test.describe("Incremental layout rows", function()
  test.before_each(function(context)
    context.views = {}
    context.active = core.active_view
    context.live = config.markdown_live_editor
    context.undo_merge_timeout = config.undo_merge_timeout
    config.markdown_live_editor = true
    config.undo_merge_timeout = 0
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    core.active_view = context.active
    config.markdown_live_editor = context.live
    config.undo_merge_timeout = context.undo_merge_timeout
  end)

  test.it("updates only the edited line's rows below a collapsed fold", function(context)
    local view, buffer = make_view(context, "plain.txt",
      "first line\n" .. string.rep("folded line\n", 6) .. string.rep("short line\n", 40), 500)
    test.ok(view:add_fold_region { line1 = 2, line2 = 7 })
    view:with_selection_state(function() buffer:set_selection(20, 1) end)
    read_layout(view)
    local before = counts(view)
    view:on_text_input(string.rep("words that wrap ", 20))
    read_layout(view)
    test.same(counts(view), before)
    same_as_fresh_view(view)
  end)

  test.it("matches a fresh layout after Source Mode changes with off-screen Markdown rows", function(context)
    local view, buffer = make_view(context, "source-mode.md", table.concat({
      "# Title", "", string.rep("Long paragraph with words that wrap. ", 30), "",
      "## Heading below the viewport", "", "```lua", "print('hello')", "```", "",
      "| Name | Value |", "| --- | --- |", "| first | second |", "", "Last paragraph.",
    }, "\n"), 420)
    view.size.y = 200
    view:with_selection_state(function() buffer:set_selection(1, 1) end)
    for _, wrapped in ipairs({ true, false }) do
      view:set_wrapping_enabled(wrapped)
      ready(view)
      read_layout(view)
      if not wrapped then view.scroll.x, view.scroll.to.x = 7, 7 end
      for _, source in ipairs({ true, false }) do
        test.ok(markdown.live_render.set_source_mode(view, source, "test-layout"))
        ready(view)
        read_layout(view)
        same_as_fresh_view(view)
        local report = same_as_fresh_view(view, { ui_frames = true })
        test.equal(report.skipped_size, nil, "settled extents must be compared")
      end
    end
  end)

  test.it("updates only the edited line's rows below a collapsed Callout", function(context)
    local view, buffer = make_view(context, "below.md", FOLDED_NOTE)
    test.ok(view:has_collapsed_folds(), "the Callout must start collapsed")
    view:with_selection_state(function() buffer:set_selection(9, #buffer.lines[9]) end)
    read_layout(view)
    local before = counts(view)
    view:on_text_input(string.rep(" more words", 40))
    read_layout(view)
    ready(view)
    read_layout(view)
    test.same(counts(view), before)
    same_as_fresh_view(view)
  end)

  test.it("moves the rows below a line break above a collapsed Callout", function(context)
    local view, buffer = make_view(context, "newline.md", FOLDED_NOTE)
    view:with_selection_state(function() buffer:set_selection(1, #buffer.lines[1] ) end)
    read_layout(view)
    local before = counts(view)
    view:on_text_input("\n")
    read_layout(view)
    ready(view)
    read_layout(view)
    test.same(counts(view), before)
    test.ok(view:has_collapsed_folds(), "the Callout must stay collapsed")
    same_as_fresh_view(view)
  end)

  test.it("restores the rows when a line break above a collapsed Callout is undone", function(context)
    local view, buffer = make_view(context, "undo.md", FOLDED_NOTE)
    view:with_selection_state(function() buffer:set_selection(1, #buffer.lines[1] ) end)
    local expected = read_layout(view)
    local before = counts(view)
    view:on_text_input("\n")
    read_layout(view)
    test.equal(command.perform("core:undo"), true)
    ready(view)
    test.equal(read_layout(view), expected)
    test.same(counts(view), before)
    same_as_fresh_view(view)
  end)

  test.it("keeps footnote rows when typing in another paragraph", function(context)
    local view, buffer = make_footnote_view(context, "type-footnotes.md")
    view:with_selection_state(function() buffer:set_selection(1, #buffer.lines[1]) end)
    local before = counts(view)
    view:on_text_input(" More words.")
    read_layout(view)
    ready(view)
    view:update()
    read_layout(view)
    test.same(counts(view), before)
    same_as_fresh_view(view)
  end)

  test.it("moves footnote rows below a line break", function(context)
    local view, buffer = make_footnote_view(context, "newline-footnotes.md")
    view:with_selection_state(function() buffer:set_selection(1, #buffer.lines[1]) end)
    local before = counts(view)
    view:on_text_input("\n")
    read_layout(view)
    ready(view)
    view:update()
    read_layout(view)
    test.same(counts(view), before)
    same_as_fresh_view(view)
  end)

  test.it("grows a distant footnote row when its definition grows", function(context)
    local view, buffer = make_footnote_view(context, "definition-footnotes.md")
    local definition = #buffer.lines - 1
    test.equal(buffer.lines[definition]:sub(1, 5), "[^a]:")
    local heights = footnote_row_heights(view)
    -- The caret opens the fold that hides the definitions.
    view:with_selection_state(function()
      buffer:set_selection(definition, #buffer.lines[definition])
    end)
    view:update()
    read_layout(view)
    local before = counts(view)
    view:on_text_input(string.rep(" Longer definition text.", 12))
    read_layout(view)
    ready(view)
    view:update()
    read_layout(view)
    test.ok(footnote_row_heights(view)[1] > heights[1], "the first card must grow")
    test.equal(counts(view).heights, before.heights)
    same_as_fresh_view(view)
  end)

  test.it("keeps the render plans of other lines until the typed text publishes", function(context)
    local view, buffer = make_view(context, "type-plans.md", table.concat({
      "## Heading above",
      "",
      "Text with *emphasis* and a [link](https://example.com).",
      "",
      "The edited paragraph.",
      "",
      "Text with **strong** words and `code`.",
      "",
      "## Heading below",
    }, "\n"))
    view:with_selection_state(function() buffer:set_selection(5, #buffer.lines[5]) end)
    view:update()
    read_layout(view)
    local others = { 1, 3, 7, 9 }
    local plans = {}
    for _, line in ipairs(others) do plans[line] = test.not_nil(view:get_line_render(line)) end

    view:on_text_input(" More words.")
    test.equal(model.peek(buffer).status, "pending")
    view:update()
    read_layout(view)
    for _, line in ipairs(others) do
      test.equal(view:get_line_render(line), plans[line], "line " .. line .. " changed while pending")
    end
    -- The publication rebuilds them, because an edit can change other lines.
    ready(view)
    view:update()
    read_layout(view)
    same_as_fresh_view(view)
  end)

  test.it("keeps off-screen heading heights through line breaks without wrapping", function(context)
    local lines = {}
    for line = 1, 150 do
      lines[line] = line % 8 == 4 and ("## Heading " .. line) or ("Body line " .. line)
    end
    local view, buffer = make_view(context, "unwrapped-breaks.md", table.concat(lines, "\n"), 600)
    view.size.y = 400
    view:set_wrapping_enabled(false)
    ready(view)
    read_layout(view)
    view:with_selection_state(function() buffer:set_selection(10, 1) end)
    local before = counts(view)
    -- Each line break shows before the parse publishes.
    for _ = 1, 3 do
      view:on_text_input("\n")
      view:update()
      read_layout(view)
    end
    ready(view)
    view:update()
    read_layout(view)
    test.equal(counts(view).heights, before.heights)
    same_as_fresh_view(view)
  end)
end)
