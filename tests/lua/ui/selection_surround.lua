local core = require "core"
local config = require "core.config"
local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

require "plugins.selection_surround"

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_view(context, text)
  local doc = Doc()
  set_text(doc, text)
  local view = DocView(doc)
  context.docs[#context.docs + 1] = doc
  return view, doc
end

local function document_text(doc)
  return table.concat(doc.lines)
end

local function selection_text(doc)
  local line1, col1, line2, col2 = doc:get_selection(true)
  return doc:get_text(line1, col1, line2, col2)
end

local function type_over_selection(view, line1, col1, line2, col2, char)
  view:with_selection_state(function()
    view.doc:set_selection(line1, col1, line2, col2)
    view:on_text_input(char)
  end)
end

test.describe("Selection surrounding", function()
  test.before_each(function(context)
    context.docs = {}
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
    for _, doc in ipairs(context.docs) do doc:on_close() end
  end)

  test.it("surrounds a single-line selection with the requested delimiters", function(context)
    local cases = {
      { "(", "(test)" },
      { "[", "[test]" },
      { "{", "{ test }" },
      { "<", "<test>" },
      { "\"", "\"test\"" },
      { "'", "'test'" },
    }
    for _, case in ipairs(cases) do
      local view, doc = new_view(context, "test")
      type_over_selection(view, 1, 1, 1, 5, case[1])
      test.equal(document_text(doc), case[2] .. "\n")
      test.equal(selection_text(doc), "test")
    end
  end)

  test.it("nests delimiters instead of converting an existing wrapper", function(context)
    local view, doc = new_view(context, "(test)")

    type_over_selection(view, 1, 1, 1, 7, "[")

    test.equal(document_text(doc), "[(test)]\n")
    test.equal(selection_text(doc), "(test)")
  end)

  test.it("types normally at a collapsed caret without inserting a companion", function(context)
    local view, doc = new_view(context, "ab")

    type_over_selection(view, 1, 2, 1, 2, "{")

    test.equal(document_text(doc), "a{b\n")
    test.same(doc.selections, { 1, 3, 1, 3 })
  end)

  test.it("keeps smart newline block creation after typing an unmatched opener", function(context)
    local view, doc = new_view(context, "")
    core.set_active_view(view)

    view:with_selection_state(function() view:on_text_input("{") end)
    test.ok(command.perform("doc:newline"))

    test.equal(document_text(doc), "{\n  \n}\n")
    test.same(doc.selections, { 2, 3, 2, 3 })
  end)

  test.it("creates an indented block for bracket-like delimiters over fully covered multiline content", function(context)
    local cases = {
      { "(", "(", ")" },
      { "[", "[", "]" },
      { "{", "{", "}" },
    }
    for _, case in ipairs(cases) do
      local view, doc = new_view(context, "  one\n    two\n  three\nnext")
      local changes = 0
      function doc:on_text_change() changes = changes + 1 end

      type_over_selection(view, 1, 3, 3, 8, case[1])

      test.equal(document_text(doc), table.concat({
        "  " .. case[2],
        "    one",
        "      two",
        "    three",
        "  " .. case[3],
        "next",
        "",
      }, "\n"))
      test.equal(selection_text(doc), "one\n      two\n    three")
      test.equal(changes, 1)
    end
  end)

  test.it("recognizes a linewise multiline selection ending at the next line", function(context)
    local view, doc = new_view(context, "  one\n  two\nnext")

    type_over_selection(view, 1, 1, 3, 1, "[")

    test.equal(document_text(doc), "  [\n    one\n    two\n  ]\nnext\n")
    test.equal(selection_text(doc), "one\n    two")
  end)

  test.it("uses ordinary edge surrounding when multiline boundary content is only partially selected", function(context)
    local view, doc = new_view(context, "prefix one\n two suffix")

    type_over_selection(view, 1, 8, 2, 5, "[")

    test.equal(document_text(doc), "prefix [one\n two] suffix\n")
    test.equal(selection_text(doc), "one\n two")
  end)

  test.it("does not block-format multiline quote or angle surrounds", function(context)
    local cases = {
      { "<", "<one\ntwo>\n" },
      { "\"", "\"one\ntwo\"\n" },
      { "'", "'one\ntwo'\n" },
    }
    for _, case in ipairs(cases) do
      local view, doc = new_view(context, "one\ntwo")
      type_over_selection(view, 1, 1, 2, 4, case[1])
      test.equal(document_text(doc), case[2])
      test.equal(selection_text(doc), "one\ntwo")
    end
  end)

  test.it("surrounds selections and types normally at collapsed carets in one change", function(context)
    local view, doc = new_view(context, "aa\nbb")
    view:with_selection_state(function()
      doc:set_selection(1, 1, 1, 3)
      doc:set_selections(2, 2, 2, 2, 2, nil, 0)
    end)
    local changes = 0
    function doc:on_text_change() changes = changes + 1 end

    view:with_selection_state(function() view:on_text_input("(") end)

    test.equal(document_text(doc), "(aa)\nb(b\n")
    test.same(doc.selections, {
      1, 2, 1, 4,
      2, 3, 2, 3,
    })
    test.equal(changes, 1)
  end)

  test.it("preserves reversed selection direction", function(context)
    local view, doc = new_view(context, "test")

    type_over_selection(view, 1, 5, 1, 1, "(")

    test.equal(document_text(doc), "(test)\n")
    test.same(doc.selections, { 1, 6, 1, 2 })
  end)
end)
