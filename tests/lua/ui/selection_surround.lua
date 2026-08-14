local core = require "core"
local config = require "core.config"
local command = require "core.command"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown_live = require "core.markdown.live_render"
local test = require "core.test"

require "plugins.selection_surround"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  if #buffer.lines == 0 then buffer.lines[1] = "\n" end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function new_view(context, text, filename)
  local buffer = filename and Buffer(filename, filename, true) or Buffer()
  set_text(buffer, text)
  local view = Editor(buffer)
  context.buffers[#context.buffers + 1] = buffer
  return view, buffer
end

local function buffer_text(buffer)
  return table.concat(buffer.lines)
end

local function selection_text(buffer)
  local line1, col1, line2, col2 = buffer:get_selection(true)
  return buffer:get_text(line1, col1, line2, col2)
end

local function type_over_selection(view, line1, col1, line2, col2, char)
  view:with_selection_state(function()
    view.buffer:set_selection(line1, col1, line2, col2)
    view:on_text_input(char)
  end)
end

test.describe("Selection surrounding", function()
  test.before_each(function(context)
    context.buffers = {}
    context.previous_active_view = core.active_view
    context.previous_tab_type = config.tab_type
    context.previous_indent_size = config.indent_size
    config.tab_type = "soft"
    config.indent_size = 2
  end)

  test.after_each(function(context)
    config.tab_type = context.previous_tab_type
    config.indent_size = context.previous_indent_size
    if context.previous_active_view then core.set_active_view(context.previous_active_view) end
    for _, buffer in ipairs(context.buffers) do buffer:on_close() end
  end)

  test.it("surrounds a single-line selection with the requested delimiters", function(context)
    local cases = {
      { "(", "(test)" },
      { "[", "[test]" },
      { "{", "{ test }" },
      { "<", "<test>" },
      { "\"", "\"test\"" },
      { "'", "'test'" },
      { "`", "`test`" },
    }
    for _, case in ipairs(cases) do
      local view, buffer = new_view(context, "test")
      type_over_selection(view, 1, 1, 1, 5, case[1])
      test.equal(buffer_text(buffer), case[2] .. "\n")
      test.equal(selection_text(buffer), "test")
    end
  end)

  test.it("nests delimiters instead of converting an existing wrapper", function(context)
    local view, buffer = new_view(context, "(test)")

    type_over_selection(view, 1, 1, 1, 7, "[")

    test.equal(buffer_text(buffer), "[(test)]\n")
    test.equal(selection_text(buffer), "(test)")
  end)

  test.it("types normally at a collapsed caret without inserting a companion", function(context)
    local view, buffer = new_view(context, "ab")

    type_over_selection(view, 1, 2, 1, 2, "{")

    test.equal(buffer_text(buffer), "a{b\n")
    test.same(buffer.selections, { 1, 3, 1, 3 })
  end)

  test.it("keeps smart newline block creation after typing an unmatched opener", function(context)
    local view, buffer = new_view(context, "")
    core.set_active_view(view)

    view:with_selection_state(function() view:on_text_input("{") end)
    test.ok(command.perform("text:newline"))

    test.equal(buffer_text(buffer), "{\n  \n}\n")
    test.same(buffer.selections, { 2, 3, 2, 3 })
  end)

  test.it("creates an indented block for bracket-like delimiters over fully covered multiline content", function(context)
    local cases = {
      { "(", "(", ")" },
      { "[", "[", "]" },
      { "{", "{", "}" },
    }
    for _, case in ipairs(cases) do
      local view, buffer = new_view(context, "  one\n    two\n  three\nnext")
      local changes = 0
      function buffer:on_text_change() changes = changes + 1 end

      type_over_selection(view, 1, 3, 3, 8, case[1])

      test.equal(buffer_text(buffer), table.concat({
        "  " .. case[2],
        "    one",
        "      two",
        "    three",
        "  " .. case[3],
        "next",
        "",
      }, "\n"))
      test.equal(selection_text(buffer), "one\n      two\n    three")
      test.equal(changes, 1)
    end
  end)

  test.it("recognizes a linewise multiline selection ending at the next line", function(context)
    local view, buffer = new_view(context, "  one\n  two\nnext")

    type_over_selection(view, 1, 1, 3, 1, "[")

    test.equal(buffer_text(buffer), "  [\n    one\n    two\n  ]\nnext\n")
    test.equal(selection_text(buffer), "one\n    two")
  end)

  test.it("uses ordinary edge surrounding when multiline boundary content is only partially selected", function(context)
    local view, buffer = new_view(context, "prefix one\n two suffix")

    type_over_selection(view, 1, 8, 2, 5, "[")

    test.equal(buffer_text(buffer), "prefix [one\n two] suffix\n")
    test.equal(selection_text(buffer), "one\n two")
  end)

  test.it("does not block-format multiline quote or angle surrounds", function(context)
    local cases = {
      { "<", "<one\ntwo>\n" },
      { "\"", "\"one\ntwo\"\n" },
      { "'", "'one\ntwo'\n" },
      { "`", "`one\ntwo`\n" },
    }
    for _, case in ipairs(cases) do
      local view, buffer = new_view(context, "one\ntwo")
      type_over_selection(view, 1, 1, 2, 4, case[1])
      test.equal(buffer_text(buffer), case[2])
      test.equal(selection_text(buffer), "one\ntwo")
    end
  end)

  test.it("surrounds selections and types normally at collapsed carets in one change", function(context)
    local view, buffer = new_view(context, "aa\nbb")
    view:with_selection_state(function()
      buffer:set_selection(1, 1, 1, 3)
      buffer:set_selections(2, 2, 2, 2, 2, nil, 0)
    end)
    local changes = 0
    function buffer:on_text_change() changes = changes + 1 end

    view:with_selection_state(function() view:on_text_input("(") end)

    test.equal(buffer_text(buffer), "(aa)\nb(b\n")
    test.same(buffer.selections, {
      1, 2, 1, 4,
      2, 3, 2, 3,
    })
    test.equal(changes, 1)
  end)

  test.it("preserves reversed selection direction", function(context)
    local view, buffer = new_view(context, "test")

    type_over_selection(view, 1, 5, 1, 1, "(")

    test.equal(buffer_text(buffer), "(test)\n")
    test.same(buffer.selections, { 1, 6, 1, 2 })
  end)

  test.it("surrounds selected Markdown in Live Preview and Source Mode", function(context)
    local view, buffer = new_view(context, "alpha beta", "note.md")
    core.set_active_view(view)
    markdown_live.set_source_mode(view, false, "selection-surround-test")
    buffer:set_selection(1, 1, 1, 6)

    test.ok(command.perform("markdown:surround-bold"))
    test.equal(buffer_text(buffer), "**alpha** beta\n")
    test.equal(selection_text(buffer), "alpha")

    markdown_live.set_source_mode(view, true, "selection-surround-test")
    test.ok(markdown_live.is_source_mode(view))
    buffer:set_selection(1, 11, 1, 15)
    test.ok(command.perform("markdown:surround-italic"))
    test.equal(buffer_text(buffer), "**alpha** _beta_\n")
    test.equal(selection_text(buffer), "beta")
  end)

  test.it("offers Markdown surround commands only for selected Markdown text", function(context)
    local markdown_view, markdown_buffer = new_view(context, "alpha", "note.md")
    core.set_active_view(markdown_view)
    markdown_buffer:set_selection(1, 1)
    test.equal(command.perform("markdown:surround-bold"), false)
    test.equal(buffer_text(markdown_buffer), "alpha\n")

    local text_view, text_buffer = new_view(context, "alpha", "note.txt")
    core.set_active_view(text_view)
    text_buffer:set_selection(1, 1, 1, 6)
    test.equal(command.perform("markdown:surround-italic"), false)
    test.equal(buffer_text(text_buffer), "alpha\n")
  end)
end)
