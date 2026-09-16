local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local config = require "core.config"
local core = require "core"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local panes = require "core.panes"
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

test.describe("Markdown semantic selection", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.buffers = {}
    context.old_live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    config.markdown_live_editor = context.old_live
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
    test.equal(selected_text(buffer), "| alpha | beta |")
    perform("editor:expand_selection_block")
    test.equal(selected_text(buffer), "| Name | Value |\n| --- | --- |\n| alpha | beta |")
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
