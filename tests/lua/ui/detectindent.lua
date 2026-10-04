local config = require "core.config"
local command = require "core.command"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local detectindent = require "plugins.detectindent"
local test = require "core.test"

local function make_buffer(text, syntax)
  local buffer = Buffer("note.md", "note.md", true)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  buffer.syntax = syntax
  return buffer
end

test.describe("Indent detection", function()
  test.before_each(function(context)
    context.tab_type, context.indent_size = config.tab_type, config.indent_size
    config.tab_type, config.indent_size = "soft", 8
  end)

  test.after_each(function(context)
    if context.pane then
      core.global_prompt_bar:exit(true)
      panes.reset_for_tests()
    end
    config.tab_type, config.indent_size = context.tab_type, context.indent_size
    if context.buffer then context.buffer:on_close() end
  end)

  test.it("keeps repeated block indentation despite stray leading spaces", function(context)
    local buffer = make_buffer(table.concat({
      "root", "    child", "        nested", "    child again", "root again",
      " stray", " another stray",
    }, "\n"), { name = "Plain Text", patterns = {} })
    context.buffer = buffer

    local indent_type, size, score = detectindent.detect(buffer)
    test.equal(indent_type, "soft")
    test.equal(size, 4)
    test.ok(score > 0)
  end)

  test.it("does not mistake aligned arguments for the block indentation size", function(context)
    context.buffer = make_buffer(table.concat({
      "call(", "  first,", "  second);",
      "block {", "    child", "        nested", "    child again", "}",
      "another block {", "    child", "        nested", "    child again", "}",
    }, "\n"), { name = "C++", patterns = {} })

    local indent_type, size, score = detectindent.detect(context.buffer)
    test.equal(indent_type, "soft")
    test.equal(size, 4)
    test.ok(score > 0)
  end)

  test.it("keeps configured defaults when repeated widths have no level changes", function(context)
    config.tab_type = "hard"
    context.buffer = make_buffer("    first\n    second\n    third", {
      name = "Plain Text", patterns = {},
    })

    local indent_type, size, score = detectindent.detect(context.buffer)
    test.equal(indent_type, config.tab_type)
    test.equal(size, config.indent_size)
    test.equal(score, 0)
  end)

  test.it("does not confirm size one from isolated one-space changes", function(context)
    context.buffer = make_buffer(table.concat({
      "root", " first", " second", "root again", "    child", "last root",
    }, "\n"), { name = "Plain Text", patterns = {} })

    local _, size, score = detectindent.detect(context.buffer)
    test.equal(size, config.indent_size)
    test.equal(score, 0)
  end)

  test.it("detects size one when repeated level changes directly support it", function(context)
    context.buffer = make_buffer("root\n child\n  nested\n child again\nroot again", {
      name = "Plain Text", patterns = {},
    })

    local indent_type, size, score = detectindent.detect(context.buffer)
    test.equal(indent_type, "soft")
    test.equal(size, 1)
    test.ok(score > 0)
  end)

  test.it("detects repeated levels without restricting files to common sizes", function(context)
    config.indent_size = 4
    for _, expected_size in ipairs({ 2, 3, 8 }) do
      local indent = string.rep(" ", expected_size)
      local buffer = make_buffer(table.concat({
        "root", indent .. "child", indent:rep(2) .. "nested",
        indent .. "child again", "root again",
      }, "\n"), { name = "Plain Text", patterns = {} })
      context.buffer = buffer
      local indent_type, size, score = detectindent.detect(buffer)
      test.equal(indent_type, "soft")
      test.equal(size, expected_size)
      test.ok(score > 0)
      buffer:on_close()
      context.buffer = nil
    end
  end)

  test.it("keeps a manual size-one choice when the buffer becomes clean", function(context)
    panes.reset_for_tests()
    context.buffer = make_buffer("root\n    child\n        nested\n    child again\nroot again", {
      name = "Plain Text", patterns = {},
    })
    context.pane = panes.create { factory = function() return Editor(context.buffer) end }
    test.ok(command.perform("editor:set_file_indent_size"))
    core.global_prompt_bar:set_text("1")
    core.global_prompt_bar:submit()
    context.buffer:clean()

    local _, size, confirmed = context.buffer:get_indent_info()
    test.equal(size, 1)
    test.ok(confirmed)
  end)

  test.it("excludes complete Markdown fenced blocks from indentation evidence", function()
    local markdown = {
      name = "Markdown",
      -- Inline-code highlighting overlaps fenced-code markers. Indentation
      -- detection must not depend on which highlighting pattern matches first.
      patterns = {
        { pattern = { "`", "`" }, type = "string" },
      },
    }
    local buffer = make_buffer(table.concat({
      "\toutside one",
      "\toutside two",
      "```sql",
      " one",
      "  two",
      "   three",
      " one again",
      "  two again",
      "   three again",
      "```",
      "\toutside three",
      "~~~ text",
      " one",
      "  two",
      "~~",
      "   still fenced",
      "~~~~",
      "\toutside four",
    }, "\n"), markdown)

    local indent_type, indent_size, score = detectindent.detect(buffer)

    test.equal(indent_type, "hard")
    test.equal(indent_size, config.indent_size)
    test.equal(score, 4)
    buffer:on_close()
  end)
end)
