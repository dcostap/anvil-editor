local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local config = require "core.config"
local core = require "core"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local panes = require "core.panes"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

require "plugins.intellij_actions"

local serial = 0

local function wait_ready(instance, timeout)
  local deadline = system.get_time() + (timeout or 5)
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return instance.status == "ready"
end

local function open_markdown(context, text)
  serial = serial + 1
  local filename = "semantic-selection-" .. system.get_process_id() .. "-" .. serial .. ".md"
  local buffer = Buffer(filename, filename, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  context.buffers[#context.buffers + 1] = buffer
  panes.present(view, { placement = "new", focus = true })
  markdown.live_render.refresh_view(view)
  local instance = markdown_model.get(buffer)
  test.ok(wait_ready(instance), instance.reason)
  core.set_active_view(view)
  return view, buffer
end

local function selected_text(buffer)
  local line1, col1, line2, col2 = buffer:get_selection(true)
  return buffer:get_text(line1, col1, line2, col2)
end

local function perform(name)
  test.ok(command.perform(name), name .. " was unavailable")
end

local function cell_fill_count(view, line)
  local count = 0
  local draw_rect, draw_text, draw_poly = renderer.draw_rect, renderer.draw_text, renderer.draw_poly
  renderer.draw_rect = function(_, _, _, _, color)
    if color == style.markdown_live_table_cell_selection then count = count + 1 end
  end
  renderer.draw_text = function(font, text, x) return x + font:get_width(text) end
  renderer.draw_poly = function() end
  local ok, err = pcall(view.with_selection_state, view, function()
    view:prepare_line_body_draw_cache(line, line)
    view:draw_line_body(line, view:get_line_screen_position(line))
  end)
  renderer.draw_rect, renderer.draw_text, renderer.draw_poly = draw_rect, draw_text, draw_poly
  if not ok then error(err, 0) end
  return count
end

test.describe("Markdown semantic selection", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.buffers = {}
    context.old_live = config.markdown_live_editor
    context.old_interactive = config.markdown_live_interactive_tables
    config.markdown_live_editor = true
    config.markdown_live_interactive_tables = true
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    config.markdown_live_editor = context.old_live
    config.markdown_live_interactive_tables = context.old_interactive
    for _, buffer in ipairs(context.buffers) do
      markdown_model.close(buffer, "test")
      buffer:on_close()
    end
  end)

  test.it("grows and shrinks through inline Markdown and its paragraph", function(context)
    local _, buffer = open_markdown(context, "Paragraph with **bold** text.\n")
    buffer:set_selection(1, 19)

    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "bold")
    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "**bold**")
    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "Paragraph with **bold** text.")

    perform("editor:shrink_selection_smart")
    test.equal(selected_text(buffer), "**bold**")
    perform("editor:shrink_selection_smart")
    test.equal(selected_text(buffer), "bold")
  end)

  test.it("grows through a sentence before its paragraph", function(context)
    local paragraph = "Hello world. This is **the second.** Third one\nwraps here."
    local _, buffer = open_markdown(context, paragraph .. "\n")
    buffer:set_selection(1, 28)
    for _, expected in ipairs({ "second", "the second.", "**the second.**",
      "This is **the second.**", paragraph }) do
      perform("editor:extend_selection_smart")
      test.equal(selected_text(buffer), expected)
    end

    buffer:set_selection(2, 3)
    for _, expected in ipairs({ "Third one\nwraps here.", paragraph }) do
      perform("editor:expand_selection_block")
      test.equal(selected_text(buffer), expected)
    end
  end)

  test.it("grows a partial word selection to the whole word first", function(context)
    local _, buffer = open_markdown(context, "First one. Partial word here.\n")
    buffer:set_selection(1, 14, 1, 17)
    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "Partial")
    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "Partial word here.")
  end)

  test.it("does not end sentences at abbreviations, code, or links", function(context)
    local paragraph = "See e.g. `a.b()` and [v1.2](x.md) docs. Next one!"
    local _, buffer = open_markdown(context, paragraph .. "\n")
    buffer:set_selection(1, 37)
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "See e.g. `a.b()` and [v1.2](x.md) docs.")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), paragraph)
  end)

  test.it("selects sentences inside list items and quotes", function(context)
    local _, buffer = open_markdown(context, "- First thing. Second thing.\n- other\n\n> Quoted one. Quoted two.\n")
    buffer:set_selection(1, 18)
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "Second thing.")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "- First thing. Second thing.")

    buffer:set_selection(4, 5)
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "Quoted one.")
  end)

  test.it("uses list items, lists, heading sections, and the document as parents", function(context)
    local _, buffer = open_markdown(context, table.concat({
      "# Parent",
      "",
      "- first",
      "- second",
      "",
      "## Child",
      "",
      "child text",
      "",
      "# Next",
      "next text",
      "",
    }, "\n"))

    buffer:set_selection(4, 4)
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "- second")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "- first\n- second")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "# Parent\n\n- first\n- second\n\n## Child\n\nchild text\n\n")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), table.concat({
      "# Parent", "", "- first", "- second", "", "## Child", "", "child text", "",
      "# Next", "next text", "",
    }, "\n"))
  end)

  test.it("walks from a child heading section to its parent section", function(context)
    local _, buffer = open_markdown(context, table.concat({
      "# Parent",
      "",
      "parent text",
      "",
      "## Child",
      "",
      "child text",
      "",
      "# Next",
      "next text",
      "",
    }, "\n"))

    buffer:set_selection(7, 3)
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "child text")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "## Child\n\nchild text\n\n")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "# Parent\n\nparent text\n\n## Child\n\nchild text\n\n")
  end)

  test.it("selects fenced code content before its delimiters", function(context)
    local _, buffer = open_markdown(context, table.concat({
      "# Examples",
      "",
      "```java",
      "int value = 1;",
      "return value;",
      "```",
      "",
    }, "\n"))

    buffer:set_selection(4, 6)
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "int value = 1;\nreturn value;")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "```java\nint value = 1;\nreturn value;\n```")
  end)

  for _, marker in ipairs({ "`", "``" }) do
    test.it("expands inline code before its paragraph with " .. #marker .. " backticks", function(context)
      local code = marker .. "some code" .. marker
      local paragraph = "Run " .. code .. " now."
      local _, buffer = open_markdown(context, paragraph .. "\n")
      buffer:set_selection(1, 5 + #marker + 2)

      perform("editor:expand_selection_block")
      test.equal(selected_text(buffer), "some code")
      perform("editor:expand_selection_block")
      test.equal(selected_text(buffer), code)
      perform("editor:expand_selection_block")
      test.equal(selected_text(buffer), paragraph)

      perform("editor:shrink_selection_smart")
      test.equal(selected_text(buffer), code)
      perform("editor:shrink_selection_smart")
      test.equal(selected_text(buffer), "some code")
    end)
  end

  test.it("selects link text before the complete Markdown link", function(context)
    local _, buffer = open_markdown(context, "Read [the guide](guide.md) today.\n")
    buffer:set_selection(1, 9)

    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "the")
    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "the guide")
    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "[the guide](guide.md)")
  end)

  test.it("expands nested prose pairs before Markdown blocks and restores selections", function(context)
    local _, buffer = open_markdown(context, "Text (outer [inner {value}] tail) end.\n")
    buffer:set_selection(1, 22)
    for _, expected in ipairs({ "value", "{value}", "inner {value}",
      "[inner {value}]", "outer [inner {value}] tail", "(outer [inner {value}] tail)",
      "Text (outer [inner {value}] tail) end." }) do
      perform("editor:expand_selection_block")
      test.equal(selected_text(buffer), expected)
    end
    perform("editor:shrink_selection_smart")
    test.equal(selected_text(buffer), "(outer [inner {value}] tail)")
  end)

  test.it("includes pairs in smart expansion inside inline code", function(context)
    local _, buffer = open_markdown(context, "Run `call(first, second)` now.\n")
    buffer:set_selection(1, 13)
    for _, expected in ipairs({ "first", "first, second", "(first, second)",
      "call(first, second)", "`call(first, second)`" }) do
      perform("editor:extend_selection_smart")
      test.equal(selected_text(buffer), expected)
    end
  end)

  test.it("expands code pairs before the fenced code body", function(context)
    local _, buffer = open_markdown(context, "```js\nif (ready) {\n  call(value);\n}\n```\n")
    buffer:set_selection(3, 9)
    for _, expected in ipairs({ "value", "(value)", "\n  call(value);\n",
      "{\n  call(value);\n}", "if (ready) {\n  call(value);\n}",
      "```js\nif (ready) {\n  call(value);\n}\n```" }) do
      perform("editor:expand_selection_block")
      test.equal(selected_text(buffer), expected)
    end
  end)

  test.it("does not create scopes from crossed or escaped prose pairs", function(context)
    for _, text in ipairs({ "Text ([value)] end.", "Text \\(value\\) end." }) do
      local _, buffer = open_markdown(context, text .. "\n")
      buffer:set_selection(1, 10)
      perform("editor:expand_selection_block")
      test.equal(selected_text(buffer), text)
      buffer:set_selection(1, 10)
      perform("editor:move_to_matching_bracket_with_history")
      test.same({ buffer:get_selection() }, { 1, 1, 1, 1 })
    end
  end)

  test.it("jumps to the enclosing prose pair and toggles its delimiters", function(context)
    local _, buffer = open_markdown(context, "Text (outer [value] tail) end.\n")
    buffer:set_selection(1, 16)
    for _, col in ipairs({ 13, 19, 13 }) do
      perform("editor:move_to_matching_bracket_with_history")
      test.same({ buffer:get_selection() }, { 1, col, 1, col })
    end
  end)

  test.it("jumps between Markdown block boundaries without brackets", function(context)
    local _, buffer = open_markdown(context, "# Title\n\nFirst paragraph.\n\n- first item\n- second item\n")
    buffer:set_selection(3, 8)
    for _, col in ipairs({ 1, 17, 1 }) do
      perform("editor:move_to_matching_bracket_with_history")
      test.same({ buffer:get_selection() }, { 3, col, 3, col })
    end
    buffer:set_selection(6, 6)
    perform("editor:move_to_matching_bracket_with_history")
    test.same({ buffer:get_selection() }, { 6, 1, 6, 1 })
    perform("editor:move_to_matching_bracket_with_history")
    test.same({ buffer:get_selection() }, { 6, 14, 6, 14 })
  end)

  test.it("navigates pairs inside fenced code", function(context)
    local _, buffer = open_markdown(context, "```js\ncall(value);\n```\n")
    buffer:set_selection(2, 8)
    for _, col in ipairs({ 5, 11, 5 }) do
      perform("editor:move_to_matching_bracket_with_history")
      test.same({ buffer:get_selection() }, { 2, col, 2, col })
    end
  end)

  test.it("navigates inline code and fenced content without bracket pairs", function(context)
    local _, buffer = open_markdown(context, "Run `some code` now.\n\n```text\nfirst line\nlast line\n```\n")
    buffer:set_selection(1, 9)
    for _, col in ipairs({ 6, 15, 6 }) do
      perform("editor:move_to_matching_bracket_with_history")
      test.same({ buffer:get_selection() }, { 1, col, 1, col })
    end
    buffer:set_selection(5, 4)
    for _, expected in ipairs({ { 4, 1, 4, 1 }, { 5, 10, 5, 10 }, { 4, 1, 4, 1 } }) do
      perform("editor:move_to_matching_bracket_with_history")
      test.same({ buffer:get_selection() }, expected)
    end
  end)

  test.it("uses table cells, rows, and the complete table as blocks", function(context)
    local _, buffer = open_markdown(context, table.concat({
      "| Name | Value |",
      "| --- | --- |",
      "| alpha | beta |",
      "",
    }, "\n"))
    buffer:set_selection(3, 13)

    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "beta")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "beta")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "| alpha | beta |")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "| Name | Value |\n| --- | --- |\n| alpha | beta |")
  end)

  for _, case in ipairs({
    { name = "one-word", text = "beta", steps = { "beta" } },
    { name = "multi-word", text = "beta gamma", steps = { "beta", "beta gamma" } },
    { name = "empty", text = "", steps = {} },
    { name = "formatted", text = "**beta gamma**", steps = { "beta", "beta gamma", "**beta gamma**" } },
  }) do
    test.it("selects a whole " .. case.name .. " cell before its row and shrinks back", function(context)
      local row = "| alpha | " .. case.text .. " |"
      local table_text = "| Name | Value |\n| --- | --- |\n" .. row
      local view, buffer = open_markdown(context, table_text .. "\n\nafter\n")
      local col = case.text == "" and 11 or case.name == "formatted" and 14 or 12
      buffer:set_selection(3, col)

      for _, expected in ipairs(case.steps) do
        perform("editor:extend_selection_smart")
        test.equal(selected_text(buffer), expected)
        test.equal(cell_fill_count(view, 3), 0, "text selection looked like a whole cell")
      end
      perform("editor:extend_selection_smart")
      test.equal(selected_text(buffer), case.text)
      test.equal(cell_fill_count(view, 3), 1, "the whole cell was not highlighted")
      perform("editor:extend_selection_smart")
      test.equal(selected_text(buffer), row)
      perform("editor:extend_selection_smart")
      test.equal(selected_text(buffer), table_text)

      perform("editor:shrink_selection_smart")
      test.equal(selected_text(buffer), row)
      perform("editor:shrink_selection_smart")
      test.equal(selected_text(buffer), case.text)
      test.equal(cell_fill_count(view, 3), 1, "shrink lost the whole-cell selection")
      perform("editor:shrink_selection_smart")
      test.equal(selected_text(buffer), case.text)
      test.equal(cell_fill_count(view, 3), 0, "shrink did not restore text selection")
    end)
  end

  test.it("keeps ordinary text selection ordinary after selecting a whole cell", function(context)
    local view, buffer = open_markdown(context, "| A | B |\n| --- | --- |\n| one | two |\n")
    buffer:set_selection(3, 4)
    perform("editor:extend_selection_smart")
    perform("editor:extend_selection_smart")
    test.equal(cell_fill_count(view, 3), 1)

    buffer:set_selection(3, 3, 3, 6)
    test.equal(selected_text(buffer), "one")
    test.equal(cell_fill_count(view, 3), 0)
    perform("editor:extend_selection_smart")
    test.equal(selected_text(buffer), "one")
    test.equal(cell_fill_count(view, 3), 1)
  end)

  test.it("extends a whole-cell selection into the next cell", function(context)
    local view, buffer = open_markdown(context, "| A | B |\n| --- | --- |\n| one | two |\n")
    buffer:set_selection(3, 4)
    perform("editor:extend_selection_smart")
    perform("editor:extend_selection_smart")
    perform("markdown:table_select_next_char")
    test.equal(cell_fill_count(view, 3), 2)
    test.same(buffer.selections, { 3, 6, 3, 3, 3, 12, 3, 9 })
  end)

  test.it("clears a selected cell without leaving its empty cell selected", function(context)
    local view, buffer = open_markdown(context, "| A | B |\n| --- | --- |\n| one | two |\n")
    buffer:set_selection(3, 4)
    perform("editor:extend_selection_smart")
    perform("editor:extend_selection_smart")
    view:on_text_input("")
    test.equal(buffer.lines[3], "|  | two |\n")
    test.equal(cell_fill_count(view, 3), 0, "deleting cell text did not restore a caret")
  end)

  test.it("keeps whole-cell selection and shrink history separate between Editors", function(context)
    local first, buffer = open_markdown(context, "| A | B |\n| --- | --- |\n| one | two |\n")
    buffer:set_selection(3, 4)
    perform("editor:extend_selection_smart")
    perform("editor:extend_selection_smart")

    local second = Editor(buffer)
    panes.present(second, { placement = "new", focus = true })
    markdown.live_render.refresh_view(second)
    second:set_selection_state({ selections = { 3, 10, 3, 10 } })
    perform("editor:extend_selection_smart")
    perform("editor:extend_selection_smart")
    test.equal(cell_fill_count(second, 3), 1)
    perform("editor:shrink_selection_smart")
    test.equal(selected_text(buffer), "two")
    test.equal(cell_fill_count(second, 3), 0)
    test.equal(cell_fill_count(first, 3), 1)

    core.set_active_view(first)
    perform("editor:shrink_selection_smart")
    test.equal(selected_text(buffer), "one")
    test.equal(cell_fill_count(first, 3), 0)
  end)

  test.it("treats a Markdown Callout as an enclosing quote block", function(context)
    local _, buffer = open_markdown(context, table.concat({
      "> [!NOTE] Example",
      "> Callout body.",
      "",
    }, "\n"))
    buffer:set_selection(2, 5)

    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "> [!NOTE] Example\n> Callout body.")
  end)
end)
