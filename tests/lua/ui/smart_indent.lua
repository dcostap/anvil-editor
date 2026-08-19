local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

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

local function text(buffer)
  return table.concat(buffer.lines)
end

local function new_editor(context, content, filename)
  local buffer = Buffer()
  set_text(buffer, content)
  if filename then buffer:set_filename(filename, filename) end
  local view = TextView(buffer)
  context.buffers = context.buffers or {}
  context.buffers[#context.buffers + 1] = buffer
  return buffer, view
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
    for _, buffer in ipairs(context.buffers or {}) do buffer:on_close() end
  end)

  test.it("indents after Lua block openers on Enter", function(context)
    local buffer, view = new_editor(context, "if ok then\nend", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(1, #"if ok then" + 1, 1, #"if ok then" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "if ok then\n  \nend\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("indents after Python colon block openers on Enter", function(context)
    local buffer, view = new_editor(context, "if ok:\npass", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(1, #"if ok:" + 1, 1, #"if ok:" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "if ok:\n  \npass\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("indents after lowercase SQL begin on Enter", function(context)
    local buffer, view = new_editor(context, "begin\nselect 1", "sample.sql")
    core.set_active_view(view)
    buffer:set_selection(1, #"begin" + 1, 1, #"begin" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "begin\n  \nselect 1\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("continues Lua comments without applying block-word indentation", function(context)
    local buffer, view = new_editor(context, "-- if ok then", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(1, #"-- if ok then" + 1, 1, #"-- if ok then" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "-- if ok then\n-- \n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("continues Python comments without applying colon indentation", function(context)
    local buffer, view = new_editor(context, "# if ok:", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(1, #"# if ok:" + 1, 1, #"# if ok:" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "# if ok:\n# \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("does not indent after ordinary Ruby statements", function(context)
    local buffer, view = new_editor(context, "puts value", "sample.rb")
    core.set_active_view(view)
    buffer:set_selection(1, #"puts value" + 1, 1, #"puts value" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "puts value\n\n")
    test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
  end)

  test.it("ignores line-comment markers inside strings for continuation indentation", function(context)
    local buffer, view = new_editor(context, "const url = \"http://example.com\" +", "sample.js")
    core.set_active_view(view)
    buffer:set_selection(1, #"const url = \"http://example.com\" +" + 1, 1, #"const url = \"http://example.com\" +" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "const url = \"http://example.com\" +\n  \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("tab repairs an under-indented Python block line", function(context)
    local buffer, view = new_editor(context, "if ok:\npass", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(2, 1, 2, 1)
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("core:indent"))

    test.equal(text(buffer), "if ok:\n  pass\n")
    test.equal(changes, 1)
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("tab repairs an over-indented Python block line", function(context)
    local buffer, view = new_editor(context, "if ok:\n    pass", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(2, 1, 2, 1)

    test.ok(command.perform("core:indent"))

    test.equal(text(buffer), "if ok:\n  pass\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("tab coalesces same-line smart indentation repairs", function(context)
    local buffer, view = new_editor(context, "if ok:\n    pass", "sample.py")
    core.set_active_view(view)
    view:with_selection_state(function()
      buffer.selections = {}
      buffer:set_selections(1, 2, 1, 2, 1)
      buffer:set_selections(2, 2, 3, 2, 3, nil, 0)
      buffer.last_selection = 2
    end)

    test.ok(command.perform("core:indent"))

    test.equal(text(buffer), "if ok:\n  pass\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("tab maps active selection through coalesced smart indentation repairs", function(context)
    local buffer, view = new_editor(context, "if a:\n    one\nif b:\n    two", "sample.py")
    core.set_active_view(view)
    view:with_selection_state(function()
      buffer.selections = {}
      buffer:set_selections(1, 2, 1, 2, 1)
      buffer:set_selections(2, 2, 3, 2, 3, nil, 0)
      buffer:set_selections(3, 4, 1, 4, 1, nil, 0)
      buffer.last_selection = 2
    end)

    test.ok(command.perform("core:indent"))

    test.equal(text(buffer), "if a:\n  one\nif b:\n  two\n")
    test.same(view:get_selection_state().selections, {
      2, 3, 2, 3,
      4, 3, 4, 3,
    })
    test.equal(view:get_selection_state().last_selection, 1)
  end)

  test.it("external multi-line paste aligns relative indentation to the insertion line", function(context)
    local buffer, view = new_editor(context, "if ok:\n  ", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 2, 3)
    system.set_clipboard("a\n  b")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "if ok:\n  a\n    b\n")
    test.same(view:get_selection_state().selections, { 3, 6, 3, 6 })
  end)

  test.it("multi-line paste at column one remains unchanged", function(context)
    local buffer, view = new_editor(context, "", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(1, 1, 1, 1)
    system.set_clipboard("  a\n    b")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "  a\n    b\n")
  end)

  test.it("primary-selection multi-line paste uses the same indentation alignment", function(context)
    if not system.set_primary_selection then return end
    local buffer, view = new_editor(context, "if ok:\n  ", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 2, 3)
    system.set_primary_selection("a\n  b")

    test.ok(command.perform("core:paste_primary_selection"))

    test.equal(text(buffer), "if ok:\n  a\n    b\n")
  end)

  test.it("matching internal multi-line paste uses sorted replacement start indentation", function(context)
    local buffer, view = new_editor(context, "aa\n    bb\ncc", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(2, 5, 1, 1)
    system.set_clipboard("payload")
    core.cursor_clipboard = { full = "payload", [1] = "x\n  y" }
    core.cursor_clipboard_whole_line = { false }

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "x\n  ybb\ncc\n")
  end)

  test.it("continues Lua line comments on Enter", function(context)
    local buffer, view = new_editor(context, "-- hello", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(1, #"-- hello" + 1, 1, #"-- hello" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "-- hello\n-- \n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("continues Markdown unordered lists on Enter", function(context)
    local buffer, view = new_editor(context, "- item", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, #"- item" + 1, 1, #"- item" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "- item\n- \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("continues Markdown ordered lists on Enter", function(context)
    local buffer, view = new_editor(context, "1. item", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, #"1. item" + 1, 1, #"1. item" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "1. item\n2. \n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("continues Markdown task lists on Enter with a fresh task marker", function(context)
    local buffer, view = new_editor(context, "- [ ] item", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, #"- [ ] item" + 1, 1, #"- [ ] item" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "- [ ] item\n- [ ] \n")
    test.same(view:get_selection_state().selections, { 2, 7, 2, 7 })
  end)

  test.it("continues Markdown parenthesized ordered lists on Enter", function(context)
    local buffer, view = new_editor(context, "3) item", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, #"3) item" + 1, 1, #"3) item" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "3) item\n4) \n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("indents a Markdown bullet from the item content start", function(context)
    local buffer, view = new_editor(context, "- first\n- second", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 2, 3)

    test.ok(command.perform("core:indent"))

    test.equal(text(buffer), "- first\n    - second\n")
    test.same(view:get_selection_state().selections, { 2, 7, 2, 7 })
  end)

  test.it("indents an empty Markdown task item from after its checkbox", function(context)
    local buffer, view = new_editor(context, "- [ ] parent\n- [ ] ", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 7, 2, 7)

    test.ok(command.perform("core:indent"))

    test.equal(text(buffer), "- [ ] parent\n    - [ ] \n")
    test.same(view:get_selection_state().selections, { 2, 11, 2, 11 })
  end)

  test.it("keeps nested Markdown indentation as spaces in hard-tab Buffers", function(context)
    config.tab_type = "hard"
    config.indent_size = 4
    local buffer, view = new_editor(
      context,
      "- [ ] parent\n    - [ ] branch\n    - [ ] ",
      "sample.md"
    )
    core.set_active_view(view)
    buffer:set_selection(3, 11, 3, 11)

    test.ok(command.perform("core:indent"))

    test.equal(
      text(buffer),
      "- [ ] parent\n    - [ ] branch\n        - [ ] \n"
    )
    test.same(view:get_selection_state().selections, { 3, 15, 3, 15 })
  end)

  test.it("does not over-indent a nested Markdown item without a preceding sibling", function(context)
    config.indent_size = 4
    local source = "- [ ] parent\n    - [ ] \n    - [ ] sibling"
    local buffer, view = new_editor(context, source, "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 11, 2, 11)

    test.ok(command.perform("core:indent"))

    test.equal(text(buffer), source .. "\n")
    test.same(view:get_selection_state().selections, { 2, 11, 2, 11 })
  end)

  test.it("does not over-indent from the start of an invalid Markdown list prefix", function(context)
    config.indent_size = 4
    local source = "- [ ] parent\n    - [ ] \n    - [ ] sibling"
    local buffer, view = new_editor(context, source, "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 5, 2, 5)

    for _ = 1, 3 do
      test.ok(command.perform("core:indent"))
    end

    test.equal(text(buffer), source .. "\n")
    test.same(view:get_selection_state().selections, { 2, 5, 2, 5 })
  end)

  test.it("removes an empty Markdown list marker on the next Enter", function(context)
    local buffer, view = new_editor(context, "- item\nnext", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, #"- item" + 1, 1, #"- item" + 1)
    test.ok(command.perform("core:newline"))

    buffer:set_selection(2, #buffer.lines[2], 2, #buffer.lines[2])
    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "- item\n\nnext\n")
    test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
  end)

  test.it("does not leave a stray list marker after repeating Enter at a split boundary", function(context)
    local buffer, view = new_editor(
      context, "- [ ] task text\n  continuation\nafter", "sample.md"
    )
    core.set_active_view(view)
    buffer:set_selection(1, 7)
    test.ok(command.perform("core:newline"))

    buffer:set_selection(2, 3)
    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "- [ ] \ntask text\n  continuation\nafter\n")
    test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
  end)

  test.it("removes a nested Markdown list marker at the content start", function(context)
    local buffer, view = new_editor(context, "- parent\n  - child\nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 5, 2, 5)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "- parent\n  child\nafter\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("removes a Markdown task marker before removing its list marker", function(context)
    local buffer, view = new_editor(context, "- parent\n  - [ ] child\nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 9, 2, 9)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "- parent\n  - child\nafter\n")
    test.same(view:get_selection_state().selections, { 2, 5, 2, 5 })

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "- parent\n  child\nafter\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("outdents an empty nested Markdown list item on Backspace", function(context)
    local buffer, view = new_editor(context, "- parent\n  - \nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 5, 2, 5)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "- parent\n- \nafter\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("removes an empty top-level Markdown task marker on Backspace", function(context)
    local buffer, view = new_editor(context, "- [ ] \nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, 7, 1, 7)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "\nafter\n")
    test.same(view:get_selection_state().selections, { 1, 1, 1, 1 })
  end)

  test.it("removes a marker-only Markdown task without a physical gap on Backspace", function(context)
    local buffer, view = new_editor(context, "- [ ]\nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, 6, 1, 6)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "\nafter\n")
    test.same(view:get_selection_state().selections, { 1, 1, 1, 1 })
  end)

  test.it("exits a marker-only Markdown task without a physical gap on Enter", function(context)
    local buffer, view = new_editor(context, "- [ ]\nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, 6, 1, 6)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "\nafter\n")
    test.same(view:get_selection_state().selections, { 1, 1, 1, 1 })
  end)

  test.it("joins adjacent Markdown list items cleanly on Delete", function(context)
    local buffer, view = new_editor(context, "- first\n- second\nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, #buffer.lines[1])

    test.ok(command.perform("core:delete"))

    test.equal(text(buffer), "- first second\nafter\n")
  end)

  test.it("removes the list marker gap when deleting a nested Markdown marker", function(context)
    local buffer, view = new_editor(context, "- parent\n  - child\nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 3)

    test.ok(command.perform("core:delete"))

    test.equal(text(buffer), "- parent\n  child\nafter\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("removes the following marker when joining adjacent Markdown list items", function(context)
    local buffer, view = new_editor(context, "- first\n- second\nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, 5)

    test.ok(command.perform("editor:join_lines"))

    test.equal(text(buffer), "- first second\nafter\n")
  end)

  test.it("indents Markdown list items ending in a colon instead of continuing the marker", function(context)
    local buffer, view = new_editor(context, "- item:", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, #"- item:" + 1, 1, #"- item:" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "- item:\n  \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("does not continue shebangs as hash comments", function(context)
    local buffer, view = new_editor(context, "#!/usr/bin/env python3", "script.py")
    core.set_active_view(view)
    buffer:set_selection(1, #"#!/usr/bin/env python3" + 1, 1, #"#!/usr/bin/env python3" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "#!/usr/bin/env python3\n\n")
    test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
  end)

  test.it("indents Odin brace blocks on Enter", function(context)
    local buffer, view = new_editor(context, "main :: proc() {\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(1, #"main :: proc() {" + 1, 1, #"main :: proc() {" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "main :: proc() {\n  \n}\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("globally inserts an unmatched paren block without a language rule", function(context)
    local buffer, view = new_editor(context, "plain(", "notes.txt")
    core.set_active_view(view)
    buffer:set_selection(1, #"plain(" + 1, 1, #"plain(" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "plain(\n  \n)\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("globally inserts an unmatched bracket block without a language rule", function(context)
    local buffer, view = new_editor(context, "items [", "notes.txt")
    core.set_active_view(view)
    buffer:set_selection(1, #"items [" + 1, 1, #"items [" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "items [\n  \n]\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("globally indents between bracket pairs without a language rule", function(context)
    local buffer, view = new_editor(context, "[]", "notes.txt")
    core.set_active_view(view)
    buffer:set_selection(1, 2, 1, 2)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "[\n  \n]\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("globally inserts an unmatched brace block without a language rule", function(context)
    local buffer, view = new_editor(context, "section {", "notes.txt")
    core.set_active_view(view)
    buffer:set_selection(1, #"section {" + 1, 1, #"section {" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "section {\n  \n}\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("keeps existing bracket-pair smart newline behavior", function(context)
    local buffer, view = new_editor(context, "call()", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(1, #"call(" + 1, 1, #"call(" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "call(\n  \n)\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)
end)
