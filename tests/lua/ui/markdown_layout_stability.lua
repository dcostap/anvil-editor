local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local workers = require "core.worker_pool"
local test = require "core.test"

require "core.commands.text"

local function ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function prepare(view)
  view:update()
  view:with_selection_state(function()
    local first, last = view:get_visible_line_range()
    for line = first, last do view:get_line_render(line) end
  end)
end

local function settle_horizontal_extent(view)
  view:get_h_content_size()
  local deadline = system.get_time() + 2
  while view:is_horizontal_extent_scan_pending() and system.get_time() < deadline do
    view:get_h_content_size()
    coroutine.yield(0.01)
  end
  test.not_ok(view:is_horizontal_extent_scan_pending(),
    "horizontal extent scan did not finish")
  view:update()
end

local function make_editor(context, buffer, width, height)
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.size.x, view.size.y = width, height
  view:set_wrapping_enabled(true)
  markdown.live_render.refresh_view(view)
  ready(model.peek(buffer))
  wrapping.complete_async_reconstruction(view)
  prepare(view)
  return view
end

local function fixture(name)
  local lines = {}
  for line = 1, 150 do
    lines[line] = line % 8 == 1 and "## Heading " .. line
      or string.rep("Ordinary paragraph content. ", 8)
  end
  local buffer = Buffer(name .. ".md", name .. ".md", true)
  return buffer, lines
end

local function position(view, line, col)
  return view:with_selection_state(function()
    local x, y = view:get_line_screen_position(line, col)
    return { x = x, y = y }
  end)
end

local function same_position(actual, expected, phase)
  test.ok(math.abs(actual.x - expected.x) < 0.01, phase .. ": horizontal position changed")
  test.ok(math.abs(actual.y - expected.y) < 0.01,
    string.format("%s: vertical position changed from %.2f to %.2f", phase, expected.y, actual.y))
end

test.describe("Markdown layout stability", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.transitions = config.transitions
    context.undo_merge_timeout = config.undo_merge_timeout
    context.views = {}
    config.transitions = false
    config.undo_merge_timeout = 0
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do view:release_owned_features("test") end
    core.active_view = context.active
    config.transitions = context.transitions
    config.undo_merge_timeout = context.undo_merge_timeout
  end)

  for _, operation in ipairs({ "backspace", "indent", "unindent" }) do
    test.it("keeps unchanged code blocks stable while list " .. operation .. " is parsed", function(context)
      local buffer, lines = fixture("list-layout-" .. operation)
      lines[78], lines[79], lines[80] = "```sql", "select 1", "```"
      lines[83], lines[84], lines[85], lines[86] = "", "- parent", "- [ ] task", ""
      if operation == "unindent" then lines[85] = "    - [ ] task" end
      buffer:insert(1, 1, table.concat(lines, "\n"))
      local view = make_editor(context, buffer, 750, 1000)
      core.set_active_view(view)
      buffer:set_selection(85, operation == "unindent" and 11 or 7)
      prepare(view)
      local before = position(view, 84, 3)
      local delimiter_height = view:get_position_visual_row_height(78, 1)
      test.equal(command.perform("core:" .. operation), true)
      local expected_source = operation == "indent" and "    - [ ] task\n"
        or operation == "unindent" and "- [ ] task\n" or "- task\n"
      test.equal(buffer.lines[85], expected_source)
      test.equal(model.peek(buffer).status, "pending")
      same_position(position(view, 84, 3), before, "immediate")
      test.equal(view:get_position_visual_row_height(78, 1), delimiter_height)
      prepare(view)
      same_position(position(view, 84, 3), before, "pending")
      ready(model.peek(buffer))
      wrapping.complete_async_reconstruction(view)
      prepare(view)
      same_position(position(view, 84, 3), before, "published")
    end)
  end

  test.it("keeps distant wrapped content stable through parser publication in a split pane", function(context)
    local buffer, lines = fixture("split-layout")
    buffer:insert(1, 1, table.concat(lines, "\n"))
    local editing = make_editor(context, buffer, 600, 400)
    local other = make_editor(context, buffer, 600, 400)
    core.set_active_view(other)
    buffer:set_selection(82, 1)
    prepare(other)
    core.set_active_view(editing)
    buffer:set_selection(10, 5)
    prepare(editing)
    prepare(other)
    editing:on_text_input("x")
    ready(model.peek(buffer))
    prepare(editing)
    prepare(other)
    local before = position(other, 82, 1)
    editing:on_text_input("\n")
    test.equal(model.peek(buffer).status, "pending")
    same_position(position(other, 83, 1), before, "split edit")
    prepare(editing)
    prepare(other)
    local pending = position(other, 83, 1)
    local pending_size = other:get_scrollable_size()
    ready(model.peek(buffer))
    wrapping.complete_async_reconstruction(editing)
    wrapping.complete_async_reconstruction(other)
    prepare(editing)
    prepare(other)
    same_position(position(other, 83, 1), pending, "split publication")
    test.equal(other:get_scrollable_size(), pending_size, "publication changed the scrollable extent")
  end)

  for _, wrapped in ipairs({ true, false }) do
    test.it("keeps measurements across consecutive edits " .. (wrapped and "with wrapping" or "without wrapping"), function(context)
      local buffer, lines = fixture("repeated-layout-" .. tostring(wrapped))
      buffer:insert(1, 1, table.concat(lines, "\n"))
      local editing = make_editor(context, buffer, 600, 400)
      local other = make_editor(context, buffer, 420, 400)
      editing:set_wrapping_enabled(wrapped)
      other:set_wrapping_enabled(wrapped)
      core.set_active_view(other)
      buffer:set_selection(82, 1)
      prepare(other)
      core.set_active_view(editing)
      buffer:set_selection(10, 5)
      prepare(editing)
      prepare(other)
      for _ = 1, 3 do
        editing:on_text_input("\n")
        prepare(editing)
        prepare(other)
      end
      if not wrapped then settle_horizontal_extent(other) end
      local pending = position(other, 85, 1)
      local pending_size = other:get_scrollable_size()
      ready(model.peek(buffer))
      wrapping.complete_async_reconstruction(other)
      prepare(other)
      if not wrapped then settle_horizontal_extent(other) end
      same_position(position(other, 85, 1), pending, "consecutive publication")
      local published_size = other:get_scrollable_size()
      test.equal(published_size, pending_size, string.format(
        "consecutive publication changed the scrollable extent from %.2f to %.2f",
        pending_size, published_size
      ))
    end)
  end

  local blocks = {
    { name = "paragraph", lines = { string.rep("**Formatted** paragraph content. ", 8), "" } },
    { name = "heading", lines = { "## Heading", "Heading body", "" } },
    { name = "list", lines = { "- parent", "    - [ ] nested task", "- next item", "" } },
    { name = "code", lines = { "```sql", "select 1", "```", "" } },
    { name = "callout", lines = { "> [!note] Note", "> Callout body", "> Another row", "" } },
    { name = "table", lines = { "| A | B |", "| --- | --- |", "| one | two |", "" } },
  }
  for _, block in ipairs(blocks) do
    test.it("keeps a distant " .. block.name .. " stable across newline, join, undo, and redo", function(context)
      local buffer, lines = fixture("matrix-layout-" .. block.name)
      lines[79] = ""
      for index, text in ipairs(block.lines) do lines[79 + index] = text end
      buffer:insert(1, 1, table.concat(lines, "\n"))
      buffer:clear_undo_redo()
      local editing = make_editor(context, buffer, 600, 400)
      local other = make_editor(context, buffer, 460, 600)
      core.set_active_view(other)
      buffer:set_selection(80, #lines[80] + 1)
      prepare(other)
      core.set_active_view(editing)
      buffer:set_selection(10, 5)
      prepare(editing)
      prepare(other)
      local expected = position(other, 80, 1)
      local operations = {
        { name = "newline", shift = 1, run = function() editing:on_text_input("\n") end },
        { name = "join", shift = 0, run = function() test.equal(command.perform("core:backspace"), true) end },
        { name = "undo", shift = 1, run = function() test.equal(command.perform("core:undo"), true) end },
        { name = "redo", shift = 0, run = function() test.equal(command.perform("core:redo"), true) end },
      }
      for _, operation in ipairs(operations) do
        operation.run()
        test.equal(#buffer.lines, 150 + operation.shift, operation.name .. " source line count")
        local line = 80 + operation.shift
        same_position(position(other, line, 1), expected, operation.name .. " immediate")
        prepare(editing)
        prepare(other)
        same_position(position(other, line, 1), expected, operation.name .. " pending")
        local pending_size = other:get_scrollable_size()
        ready(model.peek(buffer))
        wrapping.complete_async_reconstruction(other)
        prepare(other)
        same_position(position(other, line, 1), expected, operation.name .. " published")
        test.equal(other:get_scrollable_size(), pending_size, operation.name .. " changed the scrollable extent on publication")
      end
    end)
  end

  test.it("remeasures retained rows when the viewport width changes during parsing", function(context)
    local buffer = Buffer("resize-layout.md", "resize-layout.md", true)
    buffer:insert(1, 1, string.rep("Ordinary paragraph content. ", 8)
      .. "\n\n- parent\n- [ ] task\n\nFollowing paragraph.")
    local view = make_editor(context, buffer, 750, 600)
    core.set_active_view(view)
    buffer:set_selection(4, 7)
    prepare(view)
    local wide_rows = view:get_visual_row_count_for_line(1)
    test.equal(command.perform("core:backspace"), true)
    view.size.x = 350
    prepare(view)
    local narrow_rows = view:get_visual_row_count_for_line(1)
    test.ok(narrow_rows > wide_rows, "the narrower viewport reused old line breaks")
    local pending_size = view:get_scrollable_size()
    ready(model.peek(buffer))
    wrapping.complete_async_reconstruction(view)
    prepare(view)
    test.equal(view:get_visual_row_count_for_line(1), narrow_rows)
    test.equal(view:get_scrollable_size(), pending_size)
  end)

  test.it("does not retain offscreen heading heights when a new fence changes their meaning", function(context)
    local buffer, lines = fixture("context-layout")
    lines[140], lines[141] = "```", "code content"
    buffer:insert(1, 1, table.concat(lines, "\n"))
    local view = make_editor(context, buffer, 600, 400)
    core.set_active_view(view)
    buffer:set_selection(1, 1)
    prepare(view)
    local code_height = view:get_position_visual_row_height(141, 1)
    test.ok(view:get_position_visual_row_height(81, 1) > code_height)
    buffer:insert(2, 1, "```\n")
    test.equal(model.peek(buffer).status, "pending")
    test.equal(view:get_position_visual_row_height(82, 1), code_height,
      "the new code block retained an old heading height")
    ready(model.peek(buffer))
    wrapping.complete_async_reconstruction(view)
    test.equal(view:get_position_visual_row_height(82, 1), code_height)
  end)
end)
