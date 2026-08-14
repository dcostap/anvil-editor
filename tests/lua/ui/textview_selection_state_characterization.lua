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

local function new_shared_views(context, text)
  local buffer = Buffer()
  set_text(buffer, text)
  local main = TextView(buffer)
  local side = TextView(buffer)
  context.buffers = context.buffers or {}
  context.views = context.views or {}
  context.buffers[#context.buffers + 1] = buffer
  context.views[#context.views + 1] = main
  context.views[#context.views + 1] = side
  main.__test_name = "main characterization TextView"
  side.__test_name = "side characterization TextView"
  return buffer, main, side
end

local function set_view_selection(view, line1, col1, line2, col2)
  view:with_selection_state(function()
    view.buffer:set_selection(line1, col1, line2, col2)
  end)
end

local function set_view_selections(view, selections, last_selection)
  view:with_selection_state(function()
    local buffer = view.buffer
    buffer.selections = {}
    for i = 1, #selections, 4 do
      buffer:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, i == 1 and nil or 0)
    end
    buffer.last_selection = last_selection or 1
  end)
end

local function selection(view)
  return view:get_selection_state().selections
end

local function text(buffer)
  return table.concat(buffer.lines)
end

test.describe("Text View Selection State edit characterization", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
    context.previous_clipboard = system.get_clipboard()
    context.previous_cursor_clipboard = core.cursor_clipboard
    context.previous_cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
    context.previous_tab_type = config.tab_type
    context.previous_indent_size = config.indent_size
    context.previous_keep_newline_whitespace = config.keep_newline_whitespace
    config.tab_type = "soft"
    config.indent_size = 2
  end)

  test.after_each(function(context)
    config.tab_type = context.previous_tab_type
    config.indent_size = context.previous_indent_size
    config.keep_newline_whitespace = context.previous_keep_newline_whitespace
    system.set_clipboard(context.previous_clipboard or "")
    core.cursor_clipboard = context.previous_cursor_clipboard
    core.cursor_clipboard_whole_line = context.previous_cursor_clipboard_whole_line
    if context.previous_active_view then
      core.set_active_view(context.previous_active_view)
    end
    for _, buffer in ipairs(context.buffers or {}) do
      buffer:on_close()
    end
  end)

  test.it("an insert in one Text View moves inactive Selection States through the same buffer change", function(context)
    local buffer, main, side = new_shared_views(context, "alpha\nbeta")
    set_view_selection(main, 1, 1, 1, 1)
    set_view_selection(side, 2, 2, 2, 2)

    main:with_selection_state(function()
      buffer:text_input("new\n")
    end)

    test.equal(text(buffer), "new\nalpha\nbeta\n")
    test.same(selection(main), { 2, 1, 2, 1 })
    test.same(selection(side), { 3, 2, 3, 2 })
  end)

  test.it("a remove in one Text View moves inactive Selection States upward", function(context)
    local buffer, main, side = new_shared_views(context, "alpha\nbeta")
    set_view_selection(main, 1, 1, 1, 1)
    set_view_selection(side, 2, 3, 2, 3)

    main:with_selection_state(function()
      buffer:remove(1, 1, 2, 1)
    end)

    test.equal(text(buffer), "beta\n")
    test.same(selection(main), { 1, 1, 1, 1 })
    test.same(selection(side), { 1, 3, 1, 3 })
  end)

  test.it("undo from another Text View does not restore the edit owner's selection into the active view", function(context)
    local buffer, main, side = new_shared_views(context, "abc")
    set_view_selection(main, 1, 2, 1, 2)
    set_view_selection(side, 1, 4, 1, 4)

    main:with_selection_state(function()
      buffer:text_input("X")
    end)
    test.equal(text(buffer), "aXbc\n")
    test.same(selection(main), { 1, 3, 1, 3 })
    test.same(selection(side), { 1, 5, 1, 5 })

    side:with_selection_state(function()
      buffer:undo()
    end)

    test.equal(text(buffer), "abc\n")
    test.same(selection(side), { 1, 4, 1, 4 })
    test.same(selection(main), { 1, 2, 1, 2 })
  end)

  test.it("paste inserts one external clipboard payload at each collapsed caret", function(context)
    local buffer, main = new_shared_views(context, "ab\ncd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
    core.cursor_clipboard = { full = "" }
    core.cursor_clipboard_whole_line = {}
    system.set_clipboard("X")
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "aXb\ncXd\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 3, 2, 3,
    })
  end)

  test.it("paste inserts matching per-caret clipboard payloads", function(context)
    local buffer, main = new_shared_views(context, "ab\ncd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
    core.cursor_clipboard = {
      [1] = "A",
      [2] = "B",
      full = "A\nB",
    }
    core.cursor_clipboard_whole_line = {
      [1] = false,
      [2] = false,
    }
    system.set_clipboard("A\nB")

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "aAb\ncBd\n")
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 3, 2, 3,
    })
  end)

  test.it("batch paste undo restores every original caret", function(context)
    local buffer, main = new_shared_views(context, "ab\ncd")
    core.set_active_view(main)
    local original = {
      1, 2, 1, 2,
      2, 2, 2, 2,
    }
    set_view_selections(main, original)
    core.cursor_clipboard = {
      [1] = "X\nY",
      [2] = "P\nQ",
      full = "X\nY\nP\nQ",
    }
    core.cursor_clipboard_whole_line = {
      [1] = false,
      [2] = false,
    }
    system.set_clipboard("X\nY\nP\nQ")

    test.ok(command.perform("text:paste"))
    main:with_selection_state(function() buffer:undo() end)

    test.equal(text(buffer), "ab\ncd\n")
    test.same(selection(main), original)
  end)

  test.it("internal paste inserts every normal clipboard payload at one caret when counts differ", function(context)
    local buffer, main = new_shared_views(context, "ab")
    core.set_active_view(main)
    set_view_selection(main, 1, 2, 1, 2)
    core.cursor_clipboard = {
      [1] = "X",
      [2] = "Y",
      full = "X\nY",
    }
    core.cursor_clipboard_whole_line = {
      [1] = false,
      [2] = false,
    }
    system.set_clipboard("X\nY")
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "aXYb\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 3, 1, 3,
      1, 4, 1, 4,
    })
  end)

  test.it("internal paste inserts one normal clipboard payload at every caret when counts differ", function(context)
    local buffer, main = new_shared_views(context, "ab\ncd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
    core.cursor_clipboard = {
      [1] = "X",
      full = "X",
    }
    core.cursor_clipboard_whole_line = {
      [1] = false,
    }
    system.set_clipboard("X")
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "aXb\ncXd\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 3, 2, 3,
    })
  end)

  test.it("internal paste inserts every whole-line clipboard payload at one caret when counts differ", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb")
    core.set_active_view(main)
    set_view_selection(main, 2, 1, 2, 1)
    core.cursor_clipboard = {
      [1] = "XX",
      [2] = "YY",
      full = "XX\nYY\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
      [2] = true,
    }
    system.set_clipboard("XX\nYY\n")
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "aa\nXX\nYY\nbb\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      4, 1, 4, 1,
    })
  end)

  test.it("internal paste inserts one whole-line clipboard payload at every caret when counts differ", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })
    core.cursor_clipboard = {
      [1] = "XX",
      full = "XX\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
    }
    system.set_clipboard("XX\n")
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "XX\naa\nXX\nbb\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })
  end)

  test.it("whole-line paste over a linewise selection replaces it before inserting the copied line", function(context)
    local buffer, main = new_shared_views(context, "source\nreplace me\nafter")
    core.set_active_view(main)
    set_view_selection(main, 2, 1, 3, 1)
    core.cursor_clipboard = {
      [1] = "source",
      full = "source\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
    }
    system.set_clipboard("source\n")

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "source\nsource\nafter\n")
    test.same(selection(main), { 3, 1, 3, 1 })
  end)

  test.it("whole-line paste over a partial selection matches delete then whole-line paste", function(context)
    local buffer, main = new_shared_views(context, "top\nabcXYZdef\nbottom")
    core.set_active_view(main)
    set_view_selection(main, 2, 4, 2, 7)
    core.cursor_clipboard = {
      [1] = "LINE",
      full = "LINE\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
    }
    system.set_clipboard("LINE\n")

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "top\nLINE\nabcdef\nbottom\n")
    test.same(selection(main), { 3, 4, 3, 4 })
  end)

  test.it("whole-line paste handles disjoint selections on the same line atomically", function(context)
    local buffer, main = new_shared_views(context, "abXXcdYYef")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 3, 1, 5,
      1, 7, 1, 9,
    })
    core.cursor_clipboard = {
      [1] = "LINE",
      full = "LINE\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
    }
    system.set_clipboard("LINE\n")
    local changes = 0
    function buffer:on_text_change() changes = changes + 1 end

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "LINE\nLINE\nabcdef\n")
    test.same(selection(main), {
      3, 3, 3, 3,
      3, 5, 3, 5,
    })
    test.equal(changes, 1)
  end)

  test.it("overlapping whole-line paste plans a local transaction", function(context)
    local buffer, main = new_shared_views(context, "before\nabXXcdYYef\nafter")
    core.set_active_view(main)
    set_view_selections(main, {
      2, 3, 2, 5,
      2, 7, 2, 9,
    })
    core.cursor_clipboard = {
      [1] = "LINE",
      full = "LINE\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
    }
    system.set_clipboard("LINE\n")
    local transaction
    function buffer:on_text_change(_, tx) transaction = tx end

    test.ok(command.perform("text:paste"))

    transaction = test.not_nil(transaction)
    test.equal(#transaction.changed_ranges, 1)
    test.equal(transaction.changed_ranges[1].old_line1, 2)
    test.equal(transaction.changed_ranges[1].old_line2, 2)
  end)

  test.it("whole-line paste preserves a payload inserted at another selection endpoint", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 2, 1,
      2, 1, 2, 1,
    })
    core.cursor_clipboard = {
      [1] = "X",
      [2] = "Y",
      full = "X\nY\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
      [2] = true,
    }
    system.set_clipboard("X\nY\n")

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "X\naY\nbb\ncc\n")
  end)

  test.it("whole-line paste associates payloads by selection index regardless of spatial order", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      3, 1, 3, 1,
      1, 1, 1, 1,
    })
    core.cursor_clipboard = {
      [1] = "THREE",
      [2] = "ONE",
      full = "THREE\nONE\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
      [2] = true,
    }
    system.set_clipboard("THREE\nONE\n")

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "ONE\naa\nbb\nTHREE\ncc\n")
    test.same(selection(main), {
      5, 1, 5, 1,
      2, 1, 2, 1,
    })
  end)

  test.it("whole-line paste preserves selection-index payload order on the same line", function(context)
    local buffer, main = new_shared_views(context, "abcdef\nnext")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 3, 1, 3,
      1, 6, 1, 6,
    })
    core.cursor_clipboard = {
      [1] = "A",
      [2] = "B",
      full = "A\nB\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
      [2] = true,
    }
    system.set_clipboard("A\nB\n")

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "A\nB\nabcdef\nnext\n")
    test.same(selection(main), {
      3, 3, 3, 3,
      3, 6, 3, 6,
    })
  end)

  test.it("cut removes whole lines at multiple carets in one buffer change", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:cut"))

    test.equal(text(buffer), "bb\ndd\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })
    test.equal(system.get_clipboard(), "aa\ncc\n")
  end)

  test.it("cut reports only the removed line ranges", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selection(main, 3, 1, 3, 1)
    local transaction
    function buffer:on_text_change(_, tx) transaction = tx end

    test.ok(command.perform("text:cut"))

    transaction = test.not_nil(transaction)
    test.equal(#transaction.changed_ranges, 1)
    test.equal(transaction.changed_ranges[1].old_line1, 3)
    test.equal(transaction.changed_ranges[1].old_line2, 4)
  end)

  test.it("newline removes whitespace-only selected lines and inserts indentation", function(context)
    local buffer, main = new_shared_views(context, "aa\n  \n  cc")
    core.set_active_view(main)
    config.keep_newline_whitespace = false
    set_view_selections(main, {
      2, 2, 2, 2,
      3, 3, 3, 3,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "aa\n\n \n  \n  cc\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      3, 2, 3, 2,
      5, 3, 5, 3,
    })
  end)

  test.it("newline cleans a whitespace-only line with a targeted edit", function(context)
    local buffer, main = new_shared_views(context, "aa\n  \nbb")
    core.set_active_view(main)
    config.keep_newline_whitespace = false
    set_view_selection(main, 2, 2, 2, 2)
    local transaction
    function buffer:on_text_change(_, tx)
      transaction = tx
    end

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "aa\n\n \nbb\n")
    test.ok(transaction)
    test.equal(#transaction.edits, 1)
    test.equal(transaction.edits[1].line1, 2)
    test.equal(transaction.edits[1].line2, 2)
    test.same(selection(main), { 3, 2, 3, 2 })
  end)

  test.it("newline coalesces multiple carets on the same whitespace-only line", function(context)
    local buffer, main = new_shared_views(context, "aa\n    \nbb")
    core.set_active_view(main)
    config.keep_newline_whitespace = false
    set_view_selections(main, {
      2, 2, 2, 2,
      2, 4, 2, 4,
    })
    local transaction
    function buffer:on_text_change(_, tx)
      transaction = tx
    end

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "aa\n\n \nbb\n")
    test.ok(transaction)
    test.equal(#transaction.edits, 1)
    test.same(selection(main), { 3, 2, 3, 2 })
  end)

  test.it("newline maps active selection to the owner when coalescing whitespace-only carets", function(context)
    local buffer, main = new_shared_views(context, "aa\n    \nbb")
    core.set_active_view(main)
    config.keep_newline_whitespace = false
    set_view_selections(main, {
      1, 2, 1, 2,
      2, 2, 2, 2,
      2, 4, 2, 4,
    }, 3)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "a\na\n\n \nbb\n")
    test.same(selection(main), {
      2, 1, 2, 1,
      4, 2, 4, 2,
    })
    test.equal(main:get_selection_state().last_selection, 2)
  end)

  test.it("newline falls back to normal text input instead of no-oping overlapping selections", function(context)
    local buffer, main = new_shared_views(context, "aa\n    \nbb")
    core.set_active_view(main)
    config.keep_newline_whitespace = false
    set_view_selections(main, {
      2, 2, 2, 2,
      2, 1, 2, 3,
    })
    local before = text(buffer)
    local transaction
    function buffer:on_text_change(_, tx)
      transaction = tx
    end

    test.ok(command.perform("text:newline"))

    test.ok(transaction and transaction.changed)
    test.ok(text(buffer) ~= before)
  end)

  test.it("newline between paired delimiters indents inside and moves the closer to its own line", function(context)
    local buffer, main = new_shared_views(context, "fun test() {\n}")
    core.set_active_view(main)
    set_view_selection(main, 1, 10, 1, 10)
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "fun test(\n  \n) {\n}\n")
    test.equal(changes, 1)
    test.same(selection(main), { 2, 3, 2, 3 })
  end)

  test.it("newline between paired delimiters keeps the closer at the opener line indentation", function(context)
    local buffer, main = new_shared_views(context, "  call()")
    core.set_active_view(main)
    set_view_selection(main, 1, 8, 1, 8)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "  call(\n    \n  )\n")
    test.same(selection(main), { 2, 5, 2, 5 })
  end)

  test.it("newline between spaced paired delimiters cleans the interior spacing", function(context)
    local buffer, main = new_shared_views(context, "  call(   )")
    core.set_active_view(main)
    set_view_selection(main, 1, 10, 1, 10)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "  call(\n    \n  )\n")
    test.same(selection(main), { 2, 5, 2, 5 })
  end)

  test.it("newline after an unmatched opening brace inserts an indented line and closing brace", function(context)
    local buffer, main = new_shared_views(context, "if (x) {")
    core.set_active_view(main)
    set_view_selection(main, 1, 9, 1, 9)
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "if (x) {\n  \n}\n")
    test.equal(changes, 1)
    test.same(selection(main), { 2, 3, 2, 3 })
  end)

  test.it("newline after an opening delimiter indents without synthesizing an already matched brace", function(context)
    local buffer, main = new_shared_views(context, "if (x) {\n  y()\n}")
    core.set_active_view(main)
    set_view_selection(main, 1, 9, 1, 9)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "if (x) {\n  \n  y()\n}\n")
    test.same(selection(main), { 2, 3, 2, 3 })
  end)

  test.it("newline after a nested unmatched brace does not mistake the outer closer for its match", function(context)
    local buffer, main = new_shared_views(context, "if outer {\n  {\n}")
    core.set_active_view(main)
    set_view_selection(main, 2, 4, 2, 4)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "if outer {\n  {\n    \n  }\n}\n")
    test.same(selection(main), { 3, 5, 3, 5 })
  end)

  test.it("newline replacing multiline block contents matches delete then smart newline", function(context)
    local cases = {
      { "main {", "}" },
      { "call(", ")" },
      { "items[", "]" },
    }
    for _, case in ipairs(cases) do
      local buffer, main = new_shared_views(context, case[1] .. "\n  first\n  second\n" .. case[2])
      core.set_active_view(main)
      set_view_selection(main, 1, #case[1] + 1, 4, 1)

      test.ok(command.perform("text:newline"))

      test.equal(text(buffer), case[1] .. "\n  \n" .. case[2] .. "\n")
      test.same(selection(main), { 2, 3, 2, 3 })
    end
  end)

  test.it("newline replacing selected text after an opening brace keeps smart indentation", function(context)
    local buffer, main = new_shared_views(context, "fun test() {selected_word\n}")
    core.set_active_view(main)
    set_view_selection(main, 1, 13, 1, 26)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "fun test() {\n  \n}\n")
    test.same(selection(main), { 2, 3, 2, 3 })
  end)

  test.it("newline replacing selected text between paired delimiters keeps smart indentation", function(context)
    local buffer, main = new_shared_views(context, "call(selected_word)")
    core.set_active_view(main)
    set_view_selection(main, 1, 6, 1, 19)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "call(\n  \n)\n")
    test.same(selection(main), { 2, 3, 2, 3 })
  end)

  test.it("smart newline ignores a closing brace inside replaced selected text", function(context)
    local buffer, main = new_shared_views(context, "if (x) {selected_}")
    core.set_active_view(main)
    set_view_selection(main, 1, 9, 1, 19)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "if (x) {\n  \n}\n")
    test.same(selection(main), { 2, 3, 2, 3 })
  end)

  test.it("smart newline ignores delimiters inside strings", function(context)
    local buffer, main = new_shared_views(context, "printf(\"(\");")
    buffer:set_filename("smart_newline.c", "smart_newline.c")
    core.set_active_view(main)
    set_view_selection(main, 1, 10, 1, 10)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "printf(\"(\n\");\n")
    test.same(selection(main), { 2, 1, 2, 1 })
  end)

  test.it("smart newline ignores delimiters inside comments", function(context)
    local buffer, main = new_shared_views(context, "// {")
    buffer:set_filename("smart_newline.c", "smart_newline.c")
    core.set_active_view(main)
    set_view_selection(main, 1, 5, 1, 5)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "// {\n// \n")
    test.same(selection(main), { 2, 4, 2, 4 })
  end)

  test.it("unmatched brace detection ignores closing braces inside strings and comments", function(context)
    local buffer, main = new_shared_views(context, "if (x) {\n  printf(\"}\");\n  // } ignored")
    buffer:set_filename("smart_newline.c", "smart_newline.c")
    core.set_active_view(main)
    set_view_selection(main, 1, 9, 1, 9)

    test.ok(command.perform("text:newline"))

    test.equal(text(buffer), "if (x) {\n  \n}\n  printf(\"}\");\n  // } ignored\n")
    test.same(selection(main), { 2, 3, 2, 3 })
  end)

  test.it("delete trims trailing whitespace before deleting the line break", function(context)
    local buffer, main = new_shared_views(context, "aa   \nbb   \ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 3, 1, 3,
      2, 3, 2, 3,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:delete"))

    test.equal(text(buffer), "aabbcc\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 3, 1, 3,
      1, 5, 1, 5,
    })
  end)

  test.it("backspace removes indentation stops and previous characters together", function(context)
    local buffer, main = new_shared_views(context, "    aa\nbb")
    core.set_active_view(main)
    config.indent_size = 2
    set_view_selections(main, {
      1, 5, 1, 5,
      2, 2, 2, 2,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:backspace"))

    test.equal(text(buffer), "  aa\nb\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 1, 2, 1,
    })
  end)

  test.it("backspace in leading spaces deletes to the previous partial tab stop", function(context)
    local buffer, main = new_shared_views(context, "      aa")
    core.set_active_view(main)
    config.indent_size = 4
    set_view_selection(main, 1, 7, 1, 7)

    test.ok(command.perform("text:backspace"))

    test.equal(text(buffer), "    aa\n")
    test.same(selection(main), { 1, 5, 1, 5 })
  end)

  test.it("backspace in short leading spaces deletes all indentation to the previous stop", function(context)
    local buffer, main = new_shared_views(context, "   aa")
    core.set_active_view(main)
    config.indent_size = 4
    set_view_selection(main, 1, 4, 1, 4)

    test.ok(command.perform("text:backspace"))

    test.equal(text(buffer), "aa\n")
    test.same(selection(main), { 1, 1, 1, 1 })
  end)

  test.it("backspace in mixed leading indentation deletes to the previous visual tab stop", function(context)
    local buffer, main = new_shared_views(context, "\t  aa")
    core.set_active_view(main)
    config.indent_size = 4
    set_view_selection(main, 1, 4, 1, 4)

    test.ok(command.perform("text:backspace"))

    test.equal(text(buffer), "\taa\n")
    test.same(selection(main), { 1, 2, 1, 2 })
  end)

  test.it("backspace coalesces overlapping smart indentation deletions", function(context)
    local buffer, main = new_shared_views(context, "\t  aa")
    core.set_active_view(main)
    config.indent_size = 4
    set_view_selections(main, {
      1, 3, 1, 3,
      1, 4, 1, 4,
    })
    local transaction
    function buffer:on_text_change(_, tx)
      transaction = tx
    end

    test.ok(command.perform("text:backspace"))

    test.ok(transaction and transaction.changed)
    test.equal(text(buffer), "\taa\n")
    test.same(selection(main), { 1, 2, 1, 2 })
  end)

  test.it("join-lines joins multiple collapsed carets", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:join-lines"))

    test.equal(text(buffer), "aa bb\ncc dd\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 6, 1, 6,
      2, 6, 2, 6,
    })
  end)

  test.it("newline below inserts below multiple carets in one buffer change", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:newline-below"))

    test.equal(text(buffer), "aa\n\nbb\ncc\n\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      2, 1, 2, 1,
      5, 1, 5, 1,
    })
  end)

  test.it("newline above inserts above multiple carets in one buffer change", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:newline-above"))

    test.equal(text(buffer), "\naa\nbb\n\ncc\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 1, 1, 1,
      4, 1, 4, 1,
    })
  end)

  test.it("whole-line paste inserts each payload at the start of each caret line", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })
    core.cursor_clipboard = {
      [1] = "XX",
      [2] = "YY",
      full = "XX\nYY\n",
    }
    core.cursor_clipboard_whole_line = {
      [1] = true,
      [2] = true,
    }
    system.set_clipboard("XX\nYY\n")

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "XX\naa\nYY\nbb\n")
    test.same(selection(main), {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })
  end)

  test.it("duplicate-lines duplicates a final-line selection", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb")
    core.set_active_view(main)
    set_view_selection(main, 2, 1, 2, 1)
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:duplicate-lines"))

    test.equal(text(buffer), "aa\nbb\nbb\n")
    test.equal(changes, 1)
    test.same(selection(main), { 3, 1, 3, 1 })
  end)

  test.it("duplicate-lines edits only the final selected line", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selection(main, 4, 1, 4, 1)
    local transaction
    function buffer:on_text_change(_, tx) transaction = tx end

    test.ok(command.perform("text:duplicate-lines"))

    transaction = test.not_nil(transaction)
    test.equal(#transaction.changed_ranges, 1)
    test.equal(transaction.changed_ranges[1].old_line1, 4)
  end)

  test.it("duplicate-lines coalesces multiple carets on the same line", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      2, 1, 2, 1,
      2, 2, 2, 2,
    })
    local changes = 0
    function buffer:on_text_change() changes = changes + 1 end

    test.ok(command.perform("text:duplicate-lines"))

    test.equal(text(buffer), "aa\nbb\nbb\ncc\n")
    test.same(selection(main), {
      3, 1, 3, 1,
      3, 2, 3, 2,
    })
    test.equal(changes, 1)
  end)

  test.it("duplicate-lines handles selections supplied in reverse spatial order", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      3, 1, 3, 1,
      1, 1, 1, 1,
    })

    test.ok(command.perform("text:duplicate-lines"))

    test.equal(text(buffer), "aa\naa\nbb\ncc\ncc\n")
    test.same(selection(main), {
      5, 1, 5, 1,
      2, 1, 2, 1,
    })
  end)

  test.it("delete-lines deletes a final-line selection", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb")
    core.set_active_view(main)
    set_view_selection(main, 2, 1, 2, 1)
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:delete-lines"))

    test.equal(text(buffer), "aa\n")
    test.equal(changes, 1)
    test.same(selection(main), { 1, 1, 1, 1 })
  end)

  test.it("move-lines-up handles a boundary selection while moving later lines", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:move-lines-up"))

    test.equal(text(buffer), "aa\ncc\nbb\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })
  end)

  test.it("move-lines-down handles a boundary selection while moving earlier lines", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("text:move-lines-down"))

    test.equal(text(buffer), "bb\naa\ncc\n")
    test.equal(changes, 1)
    test.same(selection(main), {
      2, 1, 2, 1,
      3, 1, 3, 1,
    })
  end)

  test.it("boundary line moves use localized transactions", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      4, 1, 4, 1,
    })
    local transaction
    function buffer:on_text_change(_, tx) transaction = tx end

    test.ok(command.perform("text:move-lines-up"))

    transaction = test.not_nil(transaction)
    test.equal(#transaction.changed_ranges, 1)
    test.equal(transaction.changed_ranges[1].old_line1, 3)
    test.equal(transaction.changed_ranges[1].old_line2, 5)
  end)

  test.it("duplicate-lines preserves independent multi-line selections after duplication", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      3, 2, 4, 2,
    })

    test.ok(command.perform("text:duplicate-lines"))

    test.equal(text(buffer), "aa\naa\nbb\ncc\ndd\ncc\ndd\n")
    test.same(selection(main), {
      2, 2, 2, 2,
      6, 2, 7, 2,
    })
  end)

  test.it("delete-lines removes each selected line block and leaves carets at removal points", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      3, 1, 4, 2,
    })

    test.ok(command.perform("text:delete-lines"))

    test.equal(text(buffer), "bb\nee\n")
    test.same(selection(main), {
      1, 2, 1, 2,
      2, 1, 2, 1,
    })
  end)

  test.it("delete-lines handles selections supplied in reverse spatial order", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      3, 1, 3, 1,
      1, 1, 1, 1,
    })

    test.ok(command.perform("text:delete-lines"))

    test.equal(text(buffer), "bb\n")
  end)

  test.it("join-lines joins each selected line range with spaces", function(context)
    local buffer, main = new_shared_views(context, "aa\n  bb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 3, 1,
    })

    test.ok(command.perform("text:join-lines"))

    test.equal(text(buffer), "aa bb cc\n")
    test.same(selection(main), {
      1, 9, 1, 9,
      1, 9, 1, 9,
    })
  end)

  test.it("join-lines coalesces overlapping ranges into one transaction", function(context)
    local buffer, main = new_shared_views(context, "aa\n  bb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 3, 1,
    })
    local changes = 0
    function buffer:on_text_change() changes = changes + 1 end

    test.ok(command.perform("text:join-lines"))

    test.equal(changes, 1)
  end)

  test.it("join-lines batches independent selected line ranges", function(context)
    local buffer, main = new_shared_views(context, "aa\n  bb\ncc\n  dd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 2, 1,
      4, 1, 5, 1,
    })

    test.ok(command.perform("text:join-lines"))

    test.equal(text(buffer), "aa bb\ncc\n  dd ee\n")
    test.same(selection(main), {
      1, 6, 1, 6,
      3, 8, 3, 8,
    })
  end)

  test.it("move-lines-up moves selected line blocks upward", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selections(main, {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })

    test.ok(command.perform("text:move-lines-up"))

    test.equal(text(buffer), "bb\naa\ndd\ncc\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
  end)

  test.it("move-lines-down moves selected line blocks downward", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })

    test.ok(command.perform("text:move-lines-down"))

    test.equal(text(buffer), "bb\naa\ndd\ncc\n")
    test.same(selection(main), {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })
  end)

  test.it("move-lines-up batches independent non-final selected lines", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })

    test.ok(command.perform("text:move-lines-up"))

    test.equal(text(buffer), "bb\naa\ndd\ncc\nee\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
  end)

  test.it("move-lines-up handles selections supplied in reverse spatial order", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      4, 1, 4, 1,
      2, 1, 2, 1,
    })

    test.ok(command.perform("text:move-lines-up"))

    test.equal(text(buffer), "bb\naa\ndd\ncc\nee\n")
    test.same(selection(main), {
      3, 1, 3, 1,
      1, 1, 1, 1,
    })
  end)

  test.it("move-lines-down batches independent non-final selected lines", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })

    test.ok(command.perform("text:move-lines-down"))

    test.equal(text(buffer), "bb\naa\ndd\ncc\nee\n")
    test.same(selection(main), {
      2, 1, 2, 1,
      4, 1, 4, 1,
    })
  end)

  test.it("move-lines-down handles selections supplied in reverse spatial order", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc\ndd\nee")
    core.set_active_view(main)
    set_view_selections(main, {
      3, 1, 3, 1,
      1, 1, 1, 1,
    })

    test.ok(command.perform("text:move-lines-down"))

    test.equal(text(buffer), "bb\naa\ndd\ncc\nee\n")
    test.same(selection(main), {
      4, 1, 4, 1,
      2, 1, 2, 1,
    })
  end)

  test.it("toggle-block-comments wraps and unwraps a selected range", function(context)
    local buffer, main = new_shared_views(context, "aa")
    buffer.syntax.block_comment = { "/*", "*/" }
    core.set_active_view(main)
    set_view_selection(main, 1, 1, 1, 3)

    test.ok(command.perform("text:toggle-block-comments"))
    test.equal(text(buffer), "/* aa */\n")
    test.same(selection(main), { 1, 1, 1, 9 })

    test.ok(command.perform("text:toggle-block-comments"))
    test.equal(text(buffer), "aa\n")
    test.same(selection(main), { 1, 1, 1, 3 })
  end)

  test.it("toggle-line-comments comments and uncomments multiple selected line ranges", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    buffer.syntax.comment = "//"
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 3, 1,
    })

    test.ok(command.perform("text:toggle-line-comments"))
    test.equal(text(buffer), "// aa\n// bb\ncc\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      2, 1, 2, 6,
    })

    test.ok(command.perform("text:toggle-line-comments"))
    test.equal(text(buffer), "aa\nbb\ncc\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      2, 1, 2, 3,
    })
  end)

  test.it("indent at a collapsed caret in leading whitespace indents the line and jumps to text", function(context)
    local buffer, main = new_shared_views(context, "  aa")
    core.set_active_view(main)
    set_view_selection(main, 1, 2, 1, 2)

    test.ok(command.perform("text:indent"))

    test.equal(text(buffer), "    aa\n")
    test.same(selection(main), { 1, 5, 1, 5 })
  end)

  test.it("indent at a collapsed caret after leading text inserts the stop text", function(context)
    local buffer, main = new_shared_views(context, "aa")
    core.set_active_view(main)
    set_view_selection(main, 1, 2, 1, 2)

    test.ok(command.perform("text:indent"))

    test.equal(text(buffer), "a a\n")
    test.same(selection(main), { 1, 3, 1, 3 })
  end)

  test.it("indent and unindent adjust multiple selected line ranges", function(context)
    local buffer, main = new_shared_views(context, "aa\nbb\ncc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 3, 1,
    })

    test.ok(command.perform("text:indent"))
    test.equal(text(buffer), "  aa\n  bb\ncc\n")
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 3, 2, 5,
    })

    test.ok(command.perform("text:unindent"))
    test.equal(text(buffer), "aa\nbb\ncc\n")
    test.same(selection(main), {
      1, 1, 1, 1,
      2, 1, 2, 3,
    })
  end)

  test.it("movement commands preserve multi-caret state and subsequent text input edits moved selections", function(context)
    local buffer, main = new_shared_views(context, "abcd\nwxyz")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 2, 2, 2,
    })

    test.ok(command.perform("text:move-to-next-char"))
    test.same(selection(main), {
      1, 2, 1, 2,
      2, 3, 2, 3,
    })

    test.ok(command.perform("text:select-to-next-char"))
    test.same(selection(main), {
      1, 3, 1, 2,
      2, 4, 2, 3,
    })

    main:on_text_input("X")

    test.equal(text(buffer), "aXcd\nwxXz\n")
    test.same(selection(main), {
      1, 3, 1, 3,
      2, 4, 2, 4,
    })
  end)

  test.it("previous-char command preserves multi-caret state and clamps at buffer start", function(context)
    local _, main = new_shared_views(context, "abcd\nwxyz")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      1, 3, 1, 3,
      2, 2, 2, 2,
    })

    test.ok(command.perform("text:move-to-previous-char"))

    test.same(selection(main), {
      1, 1, 1, 1,
      1, 2, 1, 2,
      2, 1, 2, 1,
    })
  end)

  test.it("char movement commands collapse selected ranges to sorted endpoints", function(context)
    local _, main = new_shared_views(context, "abcd\nwxyz")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 4, 1, 2,
      2, 2, 2, 5,
    })

    test.ok(command.perform("text:move-to-next-char"))
    test.same(selection(main), {
      1, 4, 1, 4,
      2, 5, 2, 5,
    })

    set_view_selections(main, {
      1, 4, 1, 2,
      2, 2, 2, 5,
    })

    test.ok(command.perform("text:move-to-previous-char"))
    test.same(selection(main), {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
  end)

  test.it("char movement batches cursor updates and merges once", function(context)
    local _, main = new_shared_views(context, "abcdefghij")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      1, 2, 1, 2,
      1, 4, 1, 4,
      1, 6, 1, 6,
      1, 8, 1, 8,
    }, 5)

    local buffer = main.buffer
    local merge_calls = 0
    local original_merge_cursors = buffer.merge_cursors
    local original_move_to_cursor = buffer.move_to_cursor
    buffer.merge_cursors = function(self, ...)
      merge_calls = merge_calls + 1
      return original_merge_cursors(self, ...)
    end
    buffer.move_to_cursor = function()
      error("text:move-to-next-char should not call Buffer:move_to_cursor per caret")
    end

    local ok, err = pcall(function()
      test.ok(command.perform("text:move-to-next-char"))
      test.equal(merge_calls, 1)
      test.same(selection(main), {
        1, 2, 1, 2,
        1, 3, 1, 3,
        1, 5, 1, 5,
        1, 7, 1, 7,
        1, 9, 1, 9,
      })
    end)
    buffer.merge_cursors = original_merge_cursors
    buffer.move_to_cursor = original_move_to_cursor
    if not ok then error(err) end
  end)

  test.it("char movement command merges duplicate carets after batched movement", function(context)
    local _, main = new_shared_views(context, "abc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      1, 2, 1, 2,
    }, 2)

    test.ok(command.perform("text:move-to-previous-char"))

    test.same(selection(main), { 1, 1, 1, 1 })
    test.equal(main:get_selection_state().last_selection, 1)
  end)

  test.it("previous-char command does not skip later carets when earlier movement merges", function(context)
    local _, main = new_shared_views(context, "abc")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      1, 2, 1, 2,
      1, 3, 1, 3,
    }, 3)

    test.ok(command.perform("text:move-to-previous-char"))

    test.same(selection(main), {
      1, 1, 1, 1,
      1, 2, 1, 2,
    })
    test.equal(main:get_selection_state().last_selection, 2)
  end)

  test.it("line movement commands batch cursor updates", function(context)
    local _, main = new_shared_views(context, "aaaa\naaaa\naaaa\naaaa")
    core.set_active_view(main)
    set_view_selections(main, {
      2, 3, 2, 3,
      3, 4, 3, 4,
    }, 2)

    local buffer = main.buffer
    local merge_calls = 0
    local original_merge_cursors = buffer.merge_cursors
    local original_set_selections = buffer.set_selections
    buffer.merge_cursors = function(self, ...)
      merge_calls = merge_calls + 1
      return original_merge_cursors(self, ...)
    end
    buffer.set_selections = function()
      error("line movement should use batched selection replacement")
    end

    local ok, err = pcall(function()
      test.ok(command.perform("text:move-to-previous-line"))
      test.equal(merge_calls, 0)
      test.same(selection(main), {
        1, 3, 1, 3,
        2, 4, 2, 4,
      })
    end)
    buffer.merge_cursors = original_merge_cursors
    buffer.set_selections = original_set_selections
    if not ok then error(err) end
  end)

  test.it("line movement commands clamp at buffer boundaries and merge duplicates", function(context)
    local _, main = new_shared_views(context, "aaaa\naaaa")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    }, 2)

    test.ok(command.perform("text:move-to-previous-line"))

    test.same(selection(main), { 1, 1, 1, 1 })
    test.equal(main:get_selection_state().last_selection, 1)
  end)

  test.it("line endpoint movement commands batch cursor updates", function(context)
    local _, main = new_shared_views(context, "  ab\n    xyz")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 1,
      2, 6, 2, 6,
    }, 2)

    local buffer = main.buffer
    local original_set_selections = buffer.set_selections
    local original_merge_cursors = buffer.merge_cursors
    local merge_calls = 0
    buffer.set_selections = function()
      error("line endpoint movement should use batched selection replacement")
    end
    buffer.merge_cursors = function(self, ...)
      merge_calls = merge_calls + 1
      return original_merge_cursors(self, ...)
    end

    local ok, err = pcall(function()
      test.ok(command.perform("text:move-to-end-of-line"))
      test.equal(merge_calls, 0)
      test.same(selection(main), {
        1, 5, 1, 5,
        2, 8, 2, 8,
      })

      buffer.set_selections = original_set_selections
      set_view_selections(main, {
        1, 1, 1, 1,
        1, 5, 1, 5,
        2, 6, 2, 6,
      }, 3)
      buffer.set_selections = function()
        error("line endpoint movement should use batched selection replacement")
      end
      test.ok(command.perform("text:move-to-start-of-indentation"))
      test.equal(merge_calls, 0)
      test.same(selection(main), {
        1, 3, 1, 3,
        2, 5, 2, 5,
      })
      test.equal(main:get_selection_state().last_selection, 2)
    end)
    buffer.set_selections = original_set_selections
    buffer.merge_cursors = original_merge_cursors
    if not ok then error(err) end
  end)

  test.it("selection extension char and line commands batch cursor updates", function(context)
    local _, main = new_shared_views(context, "abcd\nwxyz\n1234")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 2, 1, 2,
      2, 3, 2, 3,
    }, 2)

    local buffer = main.buffer
    local original_set_selections = buffer.set_selections
    local original_merge_cursors = buffer.merge_cursors
    local merge_calls = 0
    buffer.set_selections = function()
      error("selection extension should use batched selection replacement")
    end
    buffer.merge_cursors = function(self, ...)
      merge_calls = merge_calls + 1
      return original_merge_cursors(self, ...)
    end

    local ok, err = pcall(function()
      test.ok(command.perform("text:select-to-previous-char"))
      test.equal(merge_calls, 0)
      test.same(selection(main), {
        1, 1, 1, 2,
        2, 2, 2, 3,
      })
      test.equal(main:get_selection_state().last_selection, 2)
    end)
    buffer.set_selections = original_set_selections
    if ok then
      set_view_selections(main, {
        2, 2, 2, 2,
        3, 4, 3, 4,
      }, 2)
      buffer.set_selections = function()
        error("selection extension should use batched selection replacement")
      end
      ok, err = pcall(function()
        test.ok(command.perform("text:select-to-previous-line"))
        test.equal(merge_calls, 0)
        test.same(selection(main), {
          1, 2, 2, 2,
          2, 4, 3, 4,
        })
        test.equal(main:get_selection_state().last_selection, 2)
      end)
    end
    buffer.set_selections = original_set_selections
    buffer.merge_cursors = original_merge_cursors
    if not ok then error(err) end
  end)

  test.it("paste handles mixed collapsed carets and selected ranges through the buffer command", function(context)
    local buffer, main = new_shared_views(context, "abc def ghi\none two three")
    core.set_active_view(main)
    set_view_selections(main, {
      1, 1, 1, 4,
      1, 5, 1, 5,
      2, 5, 2, 8,
    })
    core.cursor_clipboard = { full = "" }
    core.cursor_clipboard_whole_line = {}
    system.set_clipboard("P")

    test.ok(command.perform("text:paste"))

    test.equal(text(buffer), "P Pdef ghi\none P three\n")
    test.same(selection(main), {
      1, 2, 1, 2,
      1, 4, 1, 4,
      2, 6, 2, 6,
    })

  end)

  test.it("reapplying an already-normalized Selection State does not resanitize every cursor", function(context)
    local buffer, main = new_shared_views(context, "abc")
    main:set_selection_state({ selections = { 1, 1, 1, 1, 1, 2, 1, 2 }, last_selection = 2 })

    local original_sanitize_position = buffer.sanitize_position
    local calls = 0
    buffer.sanitize_position = function(...)
      calls = calls + 1
      return original_sanitize_position(...)
    end

    main:apply_selection_state()

    buffer.sanitize_position = original_sanitize_position
    test.equal(calls, 0)
    test.same(selection(main), { 1, 1, 1, 1, 1, 2, 1, 2 })
  end)

  test.it("explicit Selection State sanitization still clamps invalid normalized states", function(context)
    local buffer, main = new_shared_views(context, "abc")
    main.selection_state.selections = { 99, 99, 99, 99 }
    main.selection_state.normalized = true

    TextView.sanitize_registered_selection_states(buffer)

    test.same(selection(main), { 1, 4, 1, 4 })
  end)

  test.it("visible caret cache breaks on sorted selection top line, not raw caret line", function(context)
    local lines = {}
    for i = 1, 100 do lines[i] = "x" end
    local buffer, main = new_shared_views(context, table.concat(lines, "\n"))
    main:set_selection_state({
      selections = {
        100, 1, 1, 1,
        50, 1, 50, 1,
      },
      last_selection = 1,
    })

    main:with_selection_state(function()
      main:prepare_line_body_draw_cache(40, 75)
    end)

    test.same(main.__visible_caret_cache, {
      { 50, 1, 50, 1 },
    })
  end)
end)
