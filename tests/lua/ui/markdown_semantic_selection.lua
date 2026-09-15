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
