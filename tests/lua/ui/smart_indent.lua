local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

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

local function text(doc)
  return table.concat(doc.lines)
end

local function new_editor(context, content, filename)
  local doc = Doc()
  set_text(doc, content)
  if filename then doc:set_filename(filename, filename) end
  local view = DocView(doc)
  context.docs = context.docs or {}
  context.docs[#context.docs + 1] = doc
  return doc, view
end

test.describe("smart indentation", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
    context.previous_clipboard = system.get_clipboard()
    context.previous_primary_selection = system.get_primary_selection and system.get_primary_selection() or nil
    context.previous_cursor_clipboard = core.cursor_clipboard
    context.previous_cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
    context.previous_tab_type = config.tab_type
    context.previous_indent_size = config.indent_size
    config.tab_type = "soft"
    config.indent_size = 2
  end)

  test.after_each(function(context)
    config.tab_type = context.previous_tab_type
    config.indent_size = context.previous_indent_size
    system.set_clipboard(context.previous_clipboard or "")
    if system.set_primary_selection then system.set_primary_selection(context.previous_primary_selection or "") end
    core.cursor_clipboard = context.previous_cursor_clipboard
    core.cursor_clipboard_whole_line = context.previous_cursor_clipboard_whole_line
    if context.previous_active_view then core.set_active_view(context.previous_active_view) end
    for _, doc in ipairs(context.docs or {}) do doc:on_close() end
  end)

  test.it("indents after Lua block openers on Enter", function(context)
    local doc, view = new_editor(context, "if ok then\nend", "sample.lua")
    core.set_active_view(view)
    doc:set_selection(1, #"if ok then" + 1, 1, #"if ok then" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "if ok then\n  \nend\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("indents after Python colon block openers on Enter", function(context)
    local doc, view = new_editor(context, "if ok:\npass", "sample.py")
    core.set_active_view(view)
    doc:set_selection(1, #"if ok:" + 1, 1, #"if ok:" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "if ok:\n  \npass\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("indents after lowercase SQL begin on Enter", function(context)
    local doc, view = new_editor(context, "begin\nselect 1", "sample.sql")
    core.set_active_view(view)
    doc:set_selection(1, #"begin" + 1, 1, #"begin" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "begin\n  \nselect 1\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("continues Lua comments without applying block-word indentation", function(context)
    local doc, view = new_editor(context, "-- if ok then", "sample.lua")
    core.set_active_view(view)
    doc:set_selection(1, #"-- if ok then" + 1, 1, #"-- if ok then" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "-- if ok then\n-- \n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("continues Python comments without applying colon indentation", function(context)
    local doc, view = new_editor(context, "# if ok:", "sample.py")
    core.set_active_view(view)
    doc:set_selection(1, #"# if ok:" + 1, 1, #"# if ok:" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "# if ok:\n# \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("does not indent after ordinary Ruby statements", function(context)
    local doc, view = new_editor(context, "puts value", "sample.rb")
    core.set_active_view(view)
    doc:set_selection(1, #"puts value" + 1, 1, #"puts value" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "puts value\n\n")
    test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
  end)

  test.it("ignores line-comment markers inside strings for continuation indentation", function(context)
    local doc, view = new_editor(context, "const url = \"http://example.com\" +", "sample.js")
    core.set_active_view(view)
    doc:set_selection(1, #"const url = \"http://example.com\" +" + 1, 1, #"const url = \"http://example.com\" +" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "const url = \"http://example.com\" +\n  \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("tab repairs an under-indented Python block line", function(context)
    local doc, view = new_editor(context, "if ok:\npass", "sample.py")
    core.set_active_view(view)
    doc:set_selection(2, 1, 2, 1)
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("doc:indent"))

    test.equal(text(doc), "if ok:\n  pass\n")
    test.equal(changes, 1)
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("tab repairs an over-indented Python block line", function(context)
    local doc, view = new_editor(context, "if ok:\n    pass", "sample.py")
    core.set_active_view(view)
    doc:set_selection(2, 1, 2, 1)

    test.ok(command.perform("doc:indent"))

    test.equal(text(doc), "if ok:\n  pass\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("tab coalesces same-line smart indentation repairs", function(context)
    local doc, view = new_editor(context, "if ok:\n    pass", "sample.py")
    core.set_active_view(view)
    view:with_selection_state(function()
      doc.selections = {}
      doc:set_selections(1, 2, 1, 2, 1)
      doc:set_selections(2, 2, 3, 2, 3, nil, 0)
      doc.last_selection = 2
    end)

    test.ok(command.perform("doc:indent"))

    test.equal(text(doc), "if ok:\n  pass\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("tab maps active selection through coalesced smart indentation repairs", function(context)
    local doc, view = new_editor(context, "if a:\n    one\nif b:\n    two", "sample.py")
    core.set_active_view(view)
    view:with_selection_state(function()
      doc.selections = {}
      doc:set_selections(1, 2, 1, 2, 1)
      doc:set_selections(2, 2, 3, 2, 3, nil, 0)
      doc:set_selections(3, 4, 1, 4, 1, nil, 0)
      doc.last_selection = 2
    end)

    test.ok(command.perform("doc:indent"))

    test.equal(text(doc), "if a:\n  one\nif b:\n  two\n")
    test.same(view:get_selection_state().selections, {
      2, 3, 2, 3,
      4, 3, 4, 3,
    })
    test.equal(view:get_selection_state().last_selection, 1)
  end)

  test.it("external multi-line paste aligns relative indentation to the insertion line", function(context)
    local doc, view = new_editor(context, "if ok:\n  ", "sample.py")
    core.set_active_view(view)
    doc:set_selection(2, 3, 2, 3)
    system.set_clipboard("a\n  b")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("doc:paste"))

    test.equal(text(doc), "if ok:\n  a\n    b\n")
    test.same(view:get_selection_state().selections, { 3, 6, 3, 6 })
  end)

  test.it("multi-line paste at column one remains unchanged", function(context)
    local doc, view = new_editor(context, "", "sample.py")
    core.set_active_view(view)
    doc:set_selection(1, 1, 1, 1)
    system.set_clipboard("  a\n    b")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("doc:paste"))

    test.equal(text(doc), "  a\n    b\n")
  end)

  test.it("primary-selection multi-line paste uses the same indentation alignment", function(context)
    if not system.set_primary_selection then return end
    local doc, view = new_editor(context, "if ok:\n  ", "sample.py")
    core.set_active_view(view)
    doc:set_selection(2, 3, 2, 3)
    system.set_primary_selection("a\n  b")

    test.ok(command.perform("doc:paste-primary-selection"))

    test.equal(text(doc), "if ok:\n  a\n    b\n")
  end)

  test.it("matching internal multi-line paste uses sorted replacement start indentation", function(context)
    local doc, view = new_editor(context, "aa\n    bb\ncc", "sample.py")
    core.set_active_view(view)
    doc:set_selection(2, 5, 1, 1)
    system.set_clipboard("payload")
    core.cursor_clipboard = { full = "payload", [1] = "x\n  y" }
    core.cursor_clipboard_whole_line = { false }

    test.ok(command.perform("doc:paste"))

    test.equal(text(doc), "x\n  ybb\ncc\n")
  end)

  test.it("continues Lua line comments on Enter", function(context)
    local doc, view = new_editor(context, "-- hello", "sample.lua")
    core.set_active_view(view)
    doc:set_selection(1, #"-- hello" + 1, 1, #"-- hello" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "-- hello\n-- \n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("continues Markdown unordered lists on Enter", function(context)
    local doc, view = new_editor(context, "- item", "sample.md")
    core.set_active_view(view)
    doc:set_selection(1, #"- item" + 1, 1, #"- item" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "- item\n- \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("continues Markdown ordered lists on Enter", function(context)
    local doc, view = new_editor(context, "1. item", "sample.md")
    core.set_active_view(view)
    doc:set_selection(1, #"1. item" + 1, 1, #"1. item" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "1. item\n2. \n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("indents Markdown list items ending in a colon instead of continuing the marker", function(context)
    local doc, view = new_editor(context, "- item:", "sample.md")
    core.set_active_view(view)
    doc:set_selection(1, #"- item:" + 1, 1, #"- item:" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "- item:\n  \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("does not continue shebangs as hash comments", function(context)
    local doc, view = new_editor(context, "#!/usr/bin/env python3", "script.py")
    core.set_active_view(view)
    doc:set_selection(1, #"#!/usr/bin/env python3" + 1, 1, #"#!/usr/bin/env python3" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "#!/usr/bin/env python3\n\n")
    test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
  end)

  test.it("indents Odin brace blocks on Enter", function(context)
    local doc, view = new_editor(context, "main :: proc() {\n}", "sample.odin")
    core.set_active_view(view)
    doc:set_selection(1, #"main :: proc() {" + 1, 1, #"main :: proc() {" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "main :: proc() {\n  \n}\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("globally indents after open brackets without a language rule", function(context)
    local doc, view = new_editor(context, "plain(", "notes.txt")
    core.set_active_view(view)
    doc:set_selection(1, #"plain(" + 1, 1, #"plain(" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "plain(\n  \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("globally indents between bracket pairs without a language rule", function(context)
    local doc, view = new_editor(context, "[]", "notes.txt")
    core.set_active_view(view)
    doc:set_selection(1, 2, 1, 2)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "[\n  \n]\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("globally inserts an unmatched brace block without a language rule", function(context)
    local doc, view = new_editor(context, "section {", "notes.txt")
    core.set_active_view(view)
    doc:set_selection(1, #"section {" + 1, 1, #"section {" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "section {\n  \n}\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("keeps existing bracket-pair smart newline behavior", function(context)
    local doc, view = new_editor(context, "call()", "sample.lua")
    core.set_active_view(view)
    doc:set_selection(1, #"call(" + 1, 1, #"call(" + 1)

    test.ok(command.perform("doc:newline"))

    test.equal(text(doc), "call(\n  \n)\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)
end)
