local Buffer = require "core.buffer"
local command = require "core.command"
local core = require "core"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local next_buffer_id = 0

local function wait_ready(view)
  local instance = test.not_nil(markdown_model.peek(view.buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
  linewrapping.complete_async_reconstruction(view)
end

local function make_view(source, name)
  next_buffer_id = next_buffer_id + 1
  local identity = name:gsub("%.md$", "") .. "-" .. next_buffer_id .. ".md"
  local buffer = Buffer(name, identity, true)
  buffer:insert(1, 1, source)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 600, 240
  view:set_wrapping_enabled(false)
  markdown.live_render.refresh_view(view)
  wait_ready(view)
  return view, buffer
end

local function perform(view, name)
  local old_active = core.active_view
  core.active_view = view
  local ok, result = pcall(command.perform, name, view)
  core.active_view = old_active
  if not ok then error(result, 0) end
  return result
end

local function has_presented_list_marker(view, line)
  local render = view:get_line_render(line)
  for _, fragment in ipairs(render and render.fragments or {}) do
    if fragment.unordered_list_marker and fragment.widget
      or fragment.ordered_list_marker
      or fragment.markdown_task_checkbox and fragment.widget
    then
      return true
    end
  end
  return false
end

local function body_x(view, line, needle)
  local source = (view.buffer.lines[line] or ""):gsub("\n$", "")
  local col = test.not_nil(source:find(needle, 1, true), "expected source body " .. needle)
  return view:get_col_x_offset(line, col)
end

local function render_detail(view, line)
  local render = test.not_nil(view:get_line_render(line))
  local fragments = {}
  for _, fragment in ipairs(render.fragments or {}) do
    fragments[#fragments + 1] = string.format(
      "%s-%s:%q:w=%s:widget=%s:list=%s:source_list=%s:task=%s",
      tostring(fragment.source_col1), tostring(fragment.source_col2),
      tostring(fragment.text), tostring(fragment.width),
      tostring(fragment.widget ~= nil),
      tostring(fragment.unordered_list_marker or fragment.ordered_list_marker or false),
      tostring(fragment.unordered_list_source_marker or fragment.ordered_list_source_marker or false),
      tostring(fragment.markdown_task_checkbox or false)
    )
  end
  return string.format(
    "provenance=%s pending=%s raw=%s source=%q fragments=[%s]",
    tostring(render.markdown_provenance), tostring(render.markdown_pending_provenance),
    tostring(render.raw_passthrough), tostring(render.source_text),
    table.concat(fragments, ", ")
  )
end

local function assert_same_position(label, pending_x, ready_x, pending_marker, detail)
  test.ok(
    pending_marker and math.abs(pending_x - ready_x) < 0.5,
    string.format(
      "%s changed between pending and published rendering: pending=%.3f ready=%.3f marker=%s %s",
      label, pending_x, ready_x, tostring(pending_marker), detail
    )
  )
end

local first_character_cases = {
  { name = "dash", source = "- item", line = 1 },
  { name = "asterisk", source = "* item", line = 1 },
  { name = "plus", source = "+ item", line = 1 },
  { name = "ordered-dot", source = "1. item", line = 1 },
  { name = "ordered-parenthesis", source = "1) item", line = 1 },
  { name = "unchecked-task", source = "- [ ] item", line = 1 },
  {
    name = "checked-task",
    source = "* [x] ",
    line = 1,
    marker_only = true,
  },
  {
    name = "ordered-task",
    source = "1. [ ] ",
    line = 1,
    marker_only = true,
  },
  { name = "nested-unordered", source = "- parent\n    - item", line = 2 },
  { name = "nested-task", source = "- parent\n    - [ ] item", line = 2 },
}

local indent_cases = {
  {
    name = "unordered",
    source = "- parent\n- BODY",
    line = 2,
    col = 3,
    needle = "BODY",
  },
  {
    name = "ordered",
    source = "1. parent\n2. BODY",
    line = 2,
    col = 4,
    needle = "BODY",
  },
  {
    name = "task",
    source = "- [ ] parent\n- [ ] BODY",
    line = 2,
    col = 7,
    needle = "BODY",
  },
  {
    name = "formatted-body",
    source = "- parent\n- See [[Target|Alias]] now",
    line = 2,
    col = 3,
    needle = "Alias",
  },
}

local unindent_cases = {
  {
    name = "unordered",
    source = "- parent\n    - BODY",
    line = 2,
    col = 7,
    needle = "BODY",
  },
  {
    name = "ordered",
    source = "1. parent\n    2. BODY",
    line = 2,
    col = 8,
    needle = "BODY",
  },
  {
    name = "task",
    source = "- [ ] parent\n    - [ ] BODY",
    line = 2,
    col = 11,
    needle = "BODY",
  },
  {
    name = "formatted-body",
    source = "- parent\n    - See [[Target|Alias]] now",
    line = 2,
    col = 7,
    needle = "Alias",
  },
}

test.describe("Markdown list pending geometry", function()
  for _, case in ipairs(first_character_cases) do
    test.it("keeps a new " .. case.name .. " item stable on its first character", function()
      local view, buffer = make_view(
        case.source .. "\nplain\n", "pending-first-character-" .. case.name .. ".md"
      )
      local line
      if case.marker_only then
        line = case.line
        buffer:set_selection(line, #buffer.lines[line])
      else
        buffer:set_selection(case.line, #buffer.lines[case.line])
        test.equal(perform(view, "core:newline"), true)
        wait_ready(view)
        line = case.line + 1
      end
      local marker_source = (buffer.lines[line] or ""):gsub("\n$", "")
      test.ok(marker_source:match("%s$"), "fixture did not provide a marker-only item")
      local expected_x = view:get_col_x_offset(line, #marker_source + 1)

      test.equal(view:on_text_input("a"), true)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.equal(instance.status, "pending")
      local pending_x = body_x(view, line, "a")
      local pending_marker = has_presented_list_marker(view, line)
      local pending_detail = render_detail(view, line)

      wait_ready(view)
      local ready_x = body_x(view, line, "a")
      local published_returned = math.abs(expected_x - ready_x) < 0.5
      markdown_model.close(buffer, "test")
      test.ok(published_returned,
        "published body did not return to the marker-only content position")
      assert_same_position(
        case.name .. " first character", pending_x, ready_x,
        pending_marker, pending_detail
      )
    end)
  end

  for _, case in ipairs(indent_cases) do
    test.it("keeps " .. case.name .. " content stable while the indent command runs", function()
      local view, buffer = make_view(
        case.source .. "\nplain\n", "pending-indent-" .. case.name .. ".md"
      )
      buffer:set_selection(case.line, case.col)
      test.equal(perform(view, "core:indent"), true)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.equal(instance.status, "pending")
      local pending_x = body_x(view, case.line, case.needle)
      local pending_marker = has_presented_list_marker(view, case.line)
      local pending_detail = render_detail(view, case.line)

      wait_ready(view)
      local ready_x = body_x(view, case.line, case.needle)
      markdown_model.close(buffer, "test")
      assert_same_position(
        case.name .. " indentation", pending_x, ready_x,
        pending_marker, pending_detail
      )
    end)
  end

  for _, case in ipairs(unindent_cases) do
    test.it("keeps " .. case.name .. " content stable while the unindent command runs", function()
      local view, buffer = make_view(
        case.source .. "\nplain\n", "pending-unindent-" .. case.name .. ".md"
      )
      buffer:set_selection(case.line, case.col)
      test.equal(perform(view, "core:unindent"), true)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.equal(instance.status, "pending")
      local pending_x = body_x(view, case.line, case.needle)
      local pending_marker = has_presented_list_marker(view, case.line)
      local pending_detail = render_detail(view, case.line)

      wait_ready(view)
      local ready_x = body_x(view, case.line, case.needle)
      markdown_model.close(buffer, "test")
      assert_same_position(
        case.name .. " unindentation", pending_x, ready_x,
        pending_marker, pending_detail
      )
    end)
  end

  test.it("keeps a deep list stable while the unindent command runs", function()
    local view, buffer = make_view(
      "- parent\n        - BODY\nplain\n", "pending-deep-unindent.md"
    )
    buffer:set_selection(2, #buffer.lines[2])
    test.equal(perform(view, "core:unindent"), true)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.equal(instance.status, "pending")
    local pending_x = body_x(view, 2, "BODY")
    local pending_marker = has_presented_list_marker(view, 2)
    local pending_detail = render_detail(view, 2)
    wait_ready(view)
    local ready_x = body_x(view, 2, "BODY")
    markdown_model.close(buffer, "test")
    assert_same_position(
      "deep unindentation", pending_x, ready_x,
      pending_marker, pending_detail
    )
  end)

  test.it("keeps a source-revealed list stable while unindenting", function()
    local view, buffer = make_view(
      "- parent\n- BODY\nplain\n", "pending-unindent-after-indent.md"
    )
    buffer:set_selection(2, 3)
    test.equal(perform(view, "core:indent"), true)
    wait_ready(view)
    test.equal(perform(view, "core:indent"), true)
    wait_ready(view)
    buffer:set_selection(2, #buffer.lines[2])
    test.equal(perform(view, "core:unindent"), true)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.equal(instance.status, "pending")
    local pending_x = body_x(view, 2, "BODY")
    local pending_marker = has_presented_list_marker(view, 2)
    local pending_detail = render_detail(view, 2)

    wait_ready(view)
    local ready_x = body_x(view, 2, "BODY")
    markdown_model.close(buffer, "test")
    assert_same_position(
      "source-revealed unindentation", pending_x, ready_x,
      pending_marker, pending_detail
    )
  end)

  test.it("keeps an indented list prefix raw while typing", function()
    local view, buffer = make_view(
      "- parent\n- item\nplain\n", "pending-indented-list-code.md"
    )
    buffer:set_selection(2, 3)
    test.equal(perform(view, "core:indent"), true)
    wait_ready(view)
    test.equal(perform(view, "core:indent"), true)
    wait_ready(view)

    local source = (buffer.lines[2] or ""):gsub("\n$", "")
    test.ok(source:match("^%s+%-%s+item$"))
    test.ok(
      not render_detail(view, 2):find("list=true", 1, true),
      render_detail(view, 2)
    )

    buffer:set_selection(2, #buffer.lines[2])
    test.equal(view:on_text_input("x"), true)
    test.equal(markdown_model.peek(buffer).status, "pending")
    test.ok(not has_presented_list_marker(view, 2), render_detail(view, 2))

    wait_ready(view)
    test.ok(not has_presented_list_marker(view, 2), render_detail(view, 2))
  end)

  test.it("keeps an indented list prefix raw while deleting its body", function()
    local view, buffer = make_view(
      "- parent\n- item\nplain\n", "pending-indented-list-code-delete.md"
    )
    buffer:set_selection(2, 3)
    test.equal(perform(view, "core:indent"), true)
    wait_ready(view)
    test.equal(perform(view, "core:indent"), true)
    wait_ready(view)

    buffer:set_selection(2, #buffer.lines[2])
    for _ = 1, 4 do
      test.equal(perform(view, "core:backspace"), true)
      test.ok(
        not has_presented_list_marker(view, 2),
        "after deletion " .. tostring(_) .. ": " .. render_detail(view, 2)
      )
    end

    local source = (buffer.lines[2] or ""):gsub("\n$", "")
    test.equal(source, "        - ")
    test.equal(markdown_model.peek(buffer).status, "pending")
    test.ok(not has_presented_list_marker(view, 2), render_detail(view, 2))

    wait_ready(view)
    test.ok(not has_presented_list_marker(view, 2), render_detail(view, 2))
  end)

  test.it("keeps the marker presented when Backspace removes the final body character", function()
    local view, buffer = make_view("- x\nplain\n", "pending-empty-list-item.md")
    buffer:set_selection(1, #buffer.lines[1])
    test.equal(perform(view, "core:backspace"), true)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.equal(instance.status, "pending")
    local pending_marker = has_presented_list_marker(view, 1)
    local pending_detail = render_detail(view, 1)

    wait_ready(view)
    local ready_marker = has_presented_list_marker(view, 1)
    markdown_model.close(buffer, "test")
    test.ok(
      pending_marker and ready_marker,
      "the marker changed while the item became empty: " .. pending_detail
    )
  end)

  test.it("keeps content stable when the list command adds a task checkbox", function()
    local view, buffer = make_view("- BODY\nplain\n", "pending-add-task-checkbox.md")
    buffer:set_selection(1, 3)
    test.equal(perform(view, "markdown:alternate_list_item_checkbox"), true)
    local pending_x = body_x(view, 1, "BODY")
    local pending_marker = has_presented_list_marker(view, 1)
    local pending_detail = render_detail(view, 1)

    wait_ready(view)
    local ready_x = body_x(view, 1, "BODY")
    markdown_model.close(buffer, "test")
    assert_same_position(
      "adding a task checkbox", pending_x, ready_x,
      pending_marker, pending_detail
    )
  end)

  test.it("keeps content stable when the list command changes task state", function()
    local view, buffer = make_view("- [ ] BODY\nplain\n", "pending-change-task-state.md")
    buffer:set_selection(1, 7)
    test.equal(perform(view, "markdown:alternate_list_item_checkbox"), true)
    local pending_x = body_x(view, 1, "BODY")
    local pending_marker = has_presented_list_marker(view, 1)
    local pending_detail = render_detail(view, 1)

    wait_ready(view)
    local ready_x = body_x(view, 1, "BODY")
    markdown_model.close(buffer, "test")
    assert_same_position(
      "changing task state", pending_x, ready_x,
      pending_marker, pending_detail
    )
  end)

  test.it("keeps content stable when Backspace removes a task checkbox", function()
    local view, buffer = make_view("- [ ] BODY\nplain\n", "pending-remove-task-checkbox.md")
    buffer:set_selection(1, 7)
    test.equal(perform(view, "core:backspace"), true)
    local pending_x = body_x(view, 1, "BODY")
    local pending_marker = has_presented_list_marker(view, 1)
    local pending_detail = render_detail(view, 1)

    wait_ready(view)
    local ready_x = body_x(view, 1, "BODY")
    markdown_model.close(buffer, "test")
    assert_same_position(
      "removing a task checkbox", pending_x, ready_x,
      pending_marker, pending_detail
    )
  end)

  test.it("keeps the suffix stable when Enter splits a list item", function()
    local view, buffer = make_view("- BEFOREAFTER\nplain\n", "pending-split-list-item.md")
    buffer:set_selection(1, 9)
    test.equal(perform(view, "core:newline"), true)
    local pending_x = body_x(view, 2, "AFTER")
    local pending_marker = has_presented_list_marker(view, 2)
    local pending_detail = render_detail(view, 2)

    wait_ready(view)
    local ready_x = body_x(view, 2, "AFTER")
    markdown_model.close(buffer, "test")
    assert_same_position(
      "splitting a list item", pending_x, ready_x,
      pending_marker, pending_detail
    )
  end)

  test.it("keeps content stable while undo reverses list indentation", function()
    local view, buffer = make_view(
      "- parent\n- BODY\nplain\n", "pending-undo-list-indent.md"
    )
    buffer:set_selection(2, 3)
    test.equal(perform(view, "core:indent"), true)
    wait_ready(view)
    test.equal(perform(view, "core:undo"), true)
    local pending_x = body_x(view, 2, "BODY")
    local pending_marker = has_presented_list_marker(view, 2)
    local pending_detail = render_detail(view, 2)

    wait_ready(view)
    local ready_x = body_x(view, 2, "BODY")
    markdown_model.close(buffer, "test")
    assert_same_position(
      "undoing list indentation", pending_x, ready_x,
      pending_marker, pending_detail
    )
  end)

  test.it("keeps content stable while redo restores list indentation", function()
    local view, buffer = make_view(
      "- parent\n- BODY\nplain\n", "pending-redo-list-indent.md"
    )
    buffer:set_selection(2, 3)
    test.equal(perform(view, "core:indent"), true)
    wait_ready(view)
    test.equal(perform(view, "core:undo"), true)
    wait_ready(view)
    test.equal(perform(view, "core:redo"), true)
    local pending_x = body_x(view, 2, "BODY")
    local pending_marker = has_presented_list_marker(view, 2)
    local pending_detail = render_detail(view, 2)

    wait_ready(view)
    local ready_x = body_x(view, 2, "BODY")
    markdown_model.close(buffer, "test")
    assert_same_position(
      "redoing list indentation", pending_x, ready_x,
      pending_marker, pending_detail
    )
  end)

  test.it("keeps all marker-only items stable during multi-caret input", function()
    local view, buffer = make_view("- \n- \nplain\n", "pending-multi-caret-list-input.md")
    buffer:set_selection(1, 3)
    buffer:add_selection(2, 3)
    test.equal(view:on_text_input("a"), true)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.equal(instance.status, "pending")
    local pending = {}
    for line = 1, 2 do
      pending[line] = {
        x = body_x(view, line, "a"),
        marker = has_presented_list_marker(view, line),
        detail = render_detail(view, line),
      }
    end

    wait_ready(view)
    local ready = {
      body_x(view, 1, "a"),
      body_x(view, 2, "a"),
    }
    markdown_model.close(buffer, "test")
    for line = 1, 2 do
      assert_same_position(
        "multi-caret first character on line " .. line,
        pending[line].x, ready[line], pending[line].marker,
        pending[line].detail
      )
    end
  end)

  test.it("keeps all list items stable during multi-caret indentation", function()
    local view, buffer = make_view(
      "- parent\n- BODY1\n- BODY2\nplain\n", "pending-multi-caret-list-indent.md"
    )
    buffer:set_selection(2, 3)
    buffer:add_selection(3, 3)
    test.equal(perform(view, "core:indent"), true)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.equal(instance.status, "pending")
    local pending = {}
    for line = 2, 3 do
      local needle = "BODY" .. (line - 1)
      pending[line] = {
        x = body_x(view, line, needle),
        marker = has_presented_list_marker(view, line),
        detail = render_detail(view, line),
      }
    end

    wait_ready(view)
    local ready = {
      [2] = body_x(view, 2, "BODY1"),
      [3] = body_x(view, 3, "BODY2"),
    }
    markdown_model.close(buffer, "test")
    for line = 2, 3 do
      assert_same_position(
        "multi-caret indentation on line " .. line,
        pending[line].x, ready[line], pending[line].marker,
        pending[line].detail
      )
    end
  end)
end)
