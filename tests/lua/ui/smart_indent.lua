local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local syntax = require "core.syntax"
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

  test.it("ends Lua comments without applying block-word indentation", function(context)
    local buffer, view = new_editor(context, "-- if ok then", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(1, #"-- if ok then" + 1, 1, #"-- if ok then" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "-- if ok then\n\n")
    test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
  end)

  test.it("ends Python comments without applying colon indentation", function(context)
    local buffer, view = new_editor(context, "# if ok:", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(1, #"# if ok:" + 1, 1, #"# if ok:" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "# if ok:\n\n")
    test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
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

  test.it("pasting a block copied from after its indentation keeps the block's shape", function(context)
    local buffer, view = new_editor(context, "f {\n  e {\n    v,\n  }\n\n  \n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 4, 4)
    test.ok(command.perform("core:copy"))
    buffer:set_selection(6, 3, 6, 3)

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  e {\n    v,\n  }\n\n  e {\n    v,\n  }\n}\n")
  end)

  test.it("pasting a copied block at column one removes its source indentation", function(context)
    local buffer, view = new_editor(context, "f {\n  e {\n    v,\n  }\n}\n", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 4, 4)
    test.ok(command.perform("core:copy"))
    buffer:set_selection(6, 1, 6, 1)

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  e {\n    v,\n  }\n}\ne {\n  v,\n}\n")
  end)

  test.it("external block paste aligns its closing line with its first line", function(context)
    local buffer, view = new_editor(context, "f {\n  \n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 2, 3)
    system.set_clipboard("e {\n      v,\n    }")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  e {\n    v,\n  }\n}\n")
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

  test.it("multi-cursor copies pasted at one caret each start at the caret's indentation", function(context)
    local buffer, view = new_editor(context, "f {\n  a := 1\n  if x {\n    b := 2\n  }\n  \n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 2, 9)
    buffer:add_selection(4, 5, 4, 11)
    test.ok(command.perform("core:copy"))
    buffer:set_selection(6, 3, 6, 3)

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  a := 1\n  if x {\n    b := 2\n  }\n  a := 1\n  b := 2\n}\n")
    test.same(view:get_selection_state().selections, { 6, 9, 6, 9, 7, 9, 7, 9 })
  end)

  test.it("a pasted whole line takes the indentation of its new brace block", function(context)
    local buffer, view = new_editor(context, "f {\n  g {\n    x()\n  }\n  y()\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(3, 5, 3, 5)
    test.ok(command.perform("core:copy"))
    buffer:set_selection(5, 3, 5, 3)

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  g {\n    x()\n  }\n  x()\n  y()\n}\n")
  end)

  test.it("a pasted whole line takes the indentation that a new line there shows", function(context)
    local buffer, view = new_editor(context, "if a then\n  if b then\n    x()\n  end\nend", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(3, 5, 3, 5)
    test.ok(command.perform("core:copy"))
    buffer:set_selection(5, 1, 5, 1)

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "if a then\n  if b then\n    x()\n  end\n  x()\nend\n")
  end)

  test.it("pasted whole lines from several carets keep their shape", function(context)
    local buffer, view = new_editor(context, "if x {\n  y()\n}\nf {\n  g {\n  }\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(1, 1, 1, 1)
    buffer:add_selection(2, 1, 2, 1)
    buffer:add_selection(3, 1, 3, 1)
    test.ok(command.perform("core:copy"))
    buffer:set_selection(6, 3, 6, 3)

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "if x {\n  y()\n}\nf {\n  g {\n    if x {\n      y()\n    }\n  }\n}\n")
  end)

  test.it("complete lines pasted at column one take the indentation of their new block", function(context)
    local buffer, view = new_editor(context, "f {\n  g {\n    y()\n  }\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(3, 1, 3, 1)
    system.set_clipboard("x()\n  z()\n")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  g {\n    x()\n      z()\n    y()\n  }\n}\n")
  end)

  test.it("complete lines pasted in a line's indentation keep the indentation of its text", function(context)
    local buffer, view = new_editor(context, "f {\n  y()\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 2, 3)
    system.set_clipboard("x()\n")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  x()\n  y()\n}\n")
  end)

  test.it("external text with one line for each caret pastes one line at each caret", function(context)
    local buffer, view = new_editor(context, "a\nb\nc", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(3, 2, 3, 2)
    buffer:add_selection(1, 2, 1, 2)
    buffer:add_selection(2, 2, 2, 2)
    system.set_clipboard("1\n2\n3\n")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "a1\nb2\nc3\n")
  end)

  test.it("leaves the comment at its end, including trailing whitespace", function(context)
    for _, case in ipairs({
      { "-- hello", "sample.lua", 9 },
      { "// hello", "sample.odin", 9 },
      { "# hello", "sample.py", 8 },
      { "// hello \t", "sample.odin", 9 },
      { "//", "sample.odin", 3 },
    }) do
      local buffer, view = new_editor(context, case[1], case[2])
      core.set_active_view(view)
      buffer:set_selection(1, case[3])

      test.ok(command.perform("core:newline"))

      test.equal(text(buffer), case[1]:sub(1, case[3] - 1) .. "\n" .. case[1]:sub(case[3]) .. "\n")
      test.same(view:get_selection_state().selections, { 2, 1, 2, 1 })
      buffer:clean()
    end
  end)

  test.it("types at the same indentation after leaving a comment", function(context)
    local buffer, view = new_editor(context, "  // hello", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(1, #"  // hello" + 1)

    test.ok(command.perform("core:newline"))
    view:update()
    test.equal(text(buffer), "  // hello\n\n")
    test.ok(view:on_text_input("next"))

    test.equal(text(buffer), "  // hello\n  next\n")
  end)

  for _, case in ipairs({
    { "Lua", "sample.lua", "-- hello| world", "-- hello\n-- world\n", 4 },
    { "Python", "sample.py", "# hello| world", "# hello\n# world\n", 3 },
    { "existing spacing", "sample.odin", "  //  hello|   world", "  //  hello\n  //  world\n", 7 },
    { "the comment marker", "sample.odin", "//|hello", "//\n// hello\n", 4 },
    { "another marker", "sample.odin", "// hello| //world", "// hello\n// world\n", 4 },
    { "a trailing comment", "sample.odin", "value := 1 // hello| world", "value := 1 // hello\n// world\n", 1 },
  }) do
    test.it("keeps the split text commented after " .. case[1], function(context)
      local col = assert(case[3]:find("|", 1, true))
      local buffer, view = new_editor(context, case[3]:gsub("|", ""), case[2])
      core.set_active_view(view)
      buffer:set_selection(1, col)

      test.ok(command.perform("core:newline"))

      test.equal(text(buffer), case[4])
      test.same(view:get_selection_state().selections, { 2, case[5], 2, case[5] })
    end)
  end

  test.it("does not treat a Lua block comment as a line comment", function(context)
    local buffer, view = new_editor(context, "--[[ hello world ]]", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(1, #"--[[ hello" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "--[[ hello\n world ]]\n")
  end)

  test.it("splits one comment and leaves another with multiple carets in one undo step", function(context)
    local buffer, view = new_editor(context, "-- hello world\n-- done", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(1, #"-- hello" + 1)
    buffer:add_selection(2, #"-- done" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "-- hello\n-- world\n-- done\n\n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4, 4, 1, 4, 1 })
    buffer:undo()
    test.equal(text(buffer), "-- hello world\n-- done\n")
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

  test.it("removes empty nested Markdown prefixes before changing indentation", function(context)
    local buffer, view = new_editor(context, "- parent\n  - [ ] \nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(2, 9, 2, 9)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "- parent\n  - \nafter\n")
    test.same(view:get_selection_state().selections, { 2, 5, 2, 5 })

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "- parent\n  \nafter\n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("continues lists in an Untitled Buffer with Markdown Language Mode", function(context)
    local buffer, view = new_editor(context, "- item")
    buffer:set_language_mode("Markdown")
    core.set_active_view(view)
    buffer:set_selection(1, #"- item" + 1, 1, #"- item" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "- item\n- \n")
    test.same(view:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("removes an empty top-level Markdown task marker before its list marker", function(context)
    local buffer, view = new_editor(context, "- [ ] \nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, 7, 1, 7)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "- \nafter\n")
    test.same(view:get_selection_state().selections, { 1, 3, 1, 3 })

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "\nafter\n")
    test.same(view:get_selection_state().selections, { 1, 1, 1, 1 })
  end)

  test.it("removes a marker-only Markdown task without a physical gap on Backspace", function(context)
    local buffer, view = new_editor(context, "- [ ]\nafter", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, 6, 1, 6)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "- \nafter\n")
    test.same(view:get_selection_state().selections, { 1, 3, 1, 3 })

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

  test.it("Join Lines makes one comment of joined line comments", function(context)
    local buffer, view = new_editor(context, "x = 1 -- a  \n  --  b", "sample.lua")
    core.set_active_view(view)
    buffer:set_selection(1, 1)

    test.ok(command.perform("editor:join_lines"))

    test.equal(text(buffer), "x = 1 -- a b\n")
  end)

  test.it("Join Lines puts no space inside brackets", function(context)
    local buffer, view = new_editor(context, "f(\n  a,\n  b\n)", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(1, 1, 4, 2)

    test.ok(command.perform("editor:join_lines"))

    test.equal(text(buffer), "f(a, b)\n")
  end)

  test.it("Move Lines gives moved lines the indentation of the block that they enter", function(context)
    local original = "f {\n  x()\n  g {\n    y()\n  }\n}"
    local buffer, view = new_editor(context, original, "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 4)

    test.ok(command.perform("editor:move_lines_down"))
    test.equal(text(buffer), "f {\n  g {\n    x()\n    y()\n  }\n}\n")
    test.same(view:get_selection_state().selections, { 3, 6, 3, 6 })
    test.ok(command.perform("core:undo"))
    test.equal(text(buffer), original .. "\n")

    test.ok(command.perform("editor:move_lines_down"))
    test.ok(command.perform("editor:move_lines_down"))
    test.equal(text(buffer), "f {\n  g {\n    y()\n    x()\n  }\n}\n")

    test.ok(command.perform("editor:move_lines_down"))
    test.equal(text(buffer), "f {\n  g {\n    y()\n  }\n  x()\n}\n")
  end)

  test.it("Move Lines moves a closing brace with the line that it passes", function(context)
    local buffer, view = new_editor(context, "if a {\n}\nx()", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 1)

    test.ok(command.perform("editor:move_lines_down"))

    test.equal(text(buffer), "if a {\n  x()\n}\n")
  end)

  test.it("Auto-Indent Lines moves selected lines to their block and keeps their shape", function(context)
    local buffer, view = new_editor(context, "f {\n      if x {\n          y()\n      }\nz()\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 1, 4, 8)
    buffer:add_selection(5, 1, 5, 1)

    test.ok(command.perform("editor:auto_indent_lines"))

    test.equal(text(buffer), "f {\n  if x {\n      y()\n  }\n  z()\n}\n")
  end)

  test.it("continues Markdown list items ending in a colon", function(context)
    local buffer, view = new_editor(context, "- item:", "sample.md")
    core.set_active_view(view)
    buffer:set_selection(1, #"- item:" + 1, 1, #"- item:" + 1)

    test.ok(command.perform("core:newline"))

    test.equal(text(buffer), "- item:\n- \n")
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
  test.it("typing a closing brace on a blank line aligns it with its opener", function(context)
    local buffer, view = new_editor(context, "f {\n  x\n      ", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(3, 7, 3, 7)

    test.ok(view:on_text_input("}"))

    test.equal(text(buffer), "f {\n  x\n}\n")
    test.same(view:get_selection_state().selections, { 3, 2, 3, 2 })
  end)

  test.it("typing a closing brace after code leaves the line's indentation alone", function(context)
    local buffer, view = new_editor(context, "f {\n      x ", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 9, 2, 9)

    test.ok(view:on_text_input("}"))

    test.equal(text(buffer), "f {\n      x }\n")
  end)

  test.it("Backspace on an over-indented blank line goes to the block's indentation", function(context)
    local buffer, view = new_editor(context, "f {\n  x\n      \n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(3, 7, 3, 7)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "f {\n  x\n  \n}\n")
    test.same(view:get_selection_state().selections, { 3, 3, 3, 3 })
  end)

  test.it("Backspace on a blank line at the block's indentation removes the line", function(context)
    local buffer, view = new_editor(context, "f {\n  x\n  \n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(3, 3, 3, 3)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "f {\n  x\n}\n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("Backspace at a correctly indented line's indentation joins it to the previous line", function(context)
    local buffer, view = new_editor(context, "x := [\n  1,\n  2,\n]", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(3, 3, 3, 3)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "x := [\n  1, 2,\n]\n")
    test.same(view:get_selection_state().selections, { 2, 6, 2, 6 })
  end)

  test.it("Backspace in indentation without block structure still removes one indent level", function(context)
    local buffer, view = new_editor(context, "if ok:\n    x\n    ", "sample.py")
    core.set_active_view(view)
    buffer:set_selection(3, 5, 3, 5)

    test.ok(command.perform("core:backspace"))

    test.equal(text(buffer), "if ok:\n    x\n  \n")
  end)

  test.it("End on a blank line moves to the block's indentation", function(context)
    local buffer, view = new_editor(context, "f {\n  g {\n    x\n \n  }\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(4, 1, 4, 1)

    test.ok(command.perform("core:move_to_end_of_line"))

    test.equal(text(buffer), "f {\n  g {\n    x\n    \n  }\n}\n")
    test.same(view:get_selection_state().selections, { 4, 5, 4, 5 })
  end)

  test.it("End on a line with text still moves to the line end", function(context)
    local buffer, view = new_editor(context, "f {\n  x\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 1, 2, 1)

    test.ok(command.perform("core:move_to_end_of_line"))

    test.equal(text(buffer), "f {\n  x\n}\n")
    test.same(view:get_selection_state().selections, { 2, 4, 2, 4 })
  end)

  test.it("multi-line paste inside a line comment keeps every line commented", function(context)
    local buffer, view = new_editor(context, "f {\n  // note: \n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 12, 2, 12)
    system.set_clipboard("first\n  second\n\nthird\n")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  // note: first\n  //   second\n  //\n  // third\n}\n")
  end)

  test.it("a pasted list item replaces the empty Markdown list item at the caret", function(context)
    local buffer, view = new_editor(context, "- [ ] first\n- [ ] ", "notes.md")
    core.set_active_view(view)
    buffer:set_selection(2, 7, 2, 7)
    system.set_clipboard("    - [ ] usar Anvil como editor?")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "- [ ] first\n- [ ] usar Anvil como editor?\n")
    test.same(view:get_selection_state().selections, { 2, 30, 2, 30 })
  end)

  test.it("a pasted list keeps its own markers and nesting at the empty item's indentation", function(context)
    local buffer, view = new_editor(context, "- a\n  - ", "notes.md")
    core.set_active_view(view)
    buffer:set_selection(2, 5, 2, 5)
    system.set_clipboard("    - [x] b\n        - c\n    - d")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "- a\n  - [x] b\n      - c\n  - d\n")
  end)

  test.it("pasted text without a list marker fills the empty Markdown list item", function(context)
    local buffer, view = new_editor(context, "1. ", "notes.md")
    core.set_active_view(view)
    buffer:set_selection(1, 4, 1, 4)
    system.set_clipboard("plain")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "1. plain\n")
  end)

  test.it("paste inside a string literal escapes quotes and backslashes", function(context)
    local buffer, view = new_editor(context, 'p := ""', "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(1, 7, 1, 7)
    system.set_clipboard('say "hi" C:\\tmp')
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), 'p := "say \\"hi\\" C:\\\\tmp"\n')
  end)

  test.it("text copied from inside a string pastes into another string unchanged", function(context)
    local buffer, view = new_editor(context, 'a := "x\\"y"\nb := ""', "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(1, 7, 1, 11)
    test.ok(command.perform("core:copy"))
    buffer:set_selection(2, 7, 2, 7)

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), 'a := "x\\"y"\nb := "x\\"y"\n')
  end)

  test.it("paste escapes inside strings of a language whose syntax declares backslash escapes", function(context)
    syntax.add {
      name = "Paste Escape Test Language",
      files = { "%.pasteesc$" },
      patterns = {
        { pattern = { '"', '"', '\\' }, type = "string" },
        { pattern = { "'", "'" }, type = "string" },
      },
      symbols = {},
    }
    local buffer, view = new_editor(context, "a = \"\"\nb = ''", "sample.pasteesc")
    core.set_active_view(view)
    system.set_clipboard('x"\\y')
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}
    buffer:set_selection(1, 6, 1, 6)
    test.ok(command.perform("core:paste"))
    buffer:set_selection(2, 6, 2, 6)
    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "a = \"x\\\"\\\\y\"\nb = 'x\"\\y'\n")
  end)

  test.it("paste inside a triple-quoted string does not escape", function(context)
    local buffer, view = new_editor(context, 'x = """', "sample.py")
    core.set_active_view(view)
    buffer:set_selection(1, 8, 1, 8)
    system.set_clipboard('say "hi"')
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), 'x = """say "hi"\n')
  end)

  test.it("paste outside a string literal does not escape", function(context)
    local buffer, view = new_editor(context, "p := ", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(1, 6, 1, 6)
    system.set_clipboard('"a\\b"')
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), 'p := "a\\b"\n')
  end)

  test.it("multi-line paste converts space indentation to the Buffer's tabs", function(context)
    config.tab_type = "hard"
    config.indent_size = 4
    local buffer, view = new_editor(context, "f {\n\t\n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 2, 2, 2)
    system.set_clipboard("g {\n    x\n}")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n\tg {\n\t\tx\n\t}\n}\n")
  end)

  test.it("multi-line paste converts tab indentation to the Buffer's spaces", function(context)
    local buffer, view = new_editor(context, "f {\n  \n}", "sample.odin")
    core.set_active_view(view)
    buffer:set_selection(2, 3, 2, 3)
    system.set_clipboard("g {\n\tx\n}")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    test.ok(command.perform("core:paste"))

    test.equal(text(buffer), "f {\n  g {\n    x\n  }\n}\n")
  end)
end)
