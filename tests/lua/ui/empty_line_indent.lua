local core = require "core"
local command = require "core.command"
local config = require "core.config"
local linewrapping = require "core.linewrapping"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local Editor = require "core.editor"
local test = require "core.test"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function text(buffer)
  return table.concat(buffer.lines)
end

local function new_editor(context, content, filename, view_type)
  local buffer = Buffer()
  set_text(buffer, content)
  buffer:set_filename(filename, filename)
  local view = (view_type or TextView)(buffer)
  view.size.x, view.size.y = 800, 600
  context.buffers[#context.buffers + 1] = buffer
  core.set_active_view(view)
  return buffer, view
end

local function caret(view)
  return view:get_selection_state().selections
end

-- Screen x of the caret, relative to the x of column 1 on its line.
local function caret_dx(view, line, col)
  local x = view:get_caret_screen_position(line, col)
  return x - view:get_line_screen_position(line, 1)
end

local function near(actual, expected)
  test.ok(math.abs(actual - expected) < 0.01, ("expected x %.3f but got %.3f"):format(expected, actual))
end

test.describe("empty line indentation", function()
  test.before_each(function(context)
    context.buffers = {}
    context.previous_active_view = core.active_view
    context.previous_clipboard = system.get_clipboard()
    context.previous_cursor_clipboard = core.cursor_clipboard
    context.previous_cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
    context.previous_tab_type = config.tab_type
    context.previous_indent_size = config.indent_size
    context.previous_undo_merge_timeout = config.undo_merge_timeout
    config.tab_type = "soft"
    config.indent_size = 2
    config.undo_merge_timeout = 0
  end)

  test.after_each(function(context)
    config.tab_type = context.previous_tab_type
    config.indent_size = context.previous_indent_size
    config.undo_merge_timeout = context.previous_undo_merge_timeout
    system.set_clipboard(context.previous_clipboard or "")
    core.cursor_clipboard = context.previous_cursor_clipboard
    core.cursor_clipboard_whole_line = context.previous_cursor_clipboard_whole_line
    if context.previous_active_view then core.set_active_view(context.previous_active_view) end
    for _, buffer in ipairs(context.buffers) do buffer:on_close() end
  end)

  test.it("Enter leaves the new line empty and shows the caret at its indentation", function(context)
    local buffer, view = new_editor(context, "if ok then\nend", "sample.lua")
    buffer:set_selection(1, 11, 1, 11)

    test.ok(command.perform("core:newline"))
    view:update()

    test.equal(text(buffer), "if ok then\n\nend\n")
    test.same(caret(view), { 2, 1, 2, 1 })
    near(caret_dx(view, 2, 1), view:get_font():get_width("  "))
  end)

  test.it("selection endpoints on empty lines stay at the text edge in either direction", function(context)
    local buffer, view = new_editor(context, "if ok then\n\n\n\nend", "sample.lua")
    for _, wrapped in ipairs { false, true } do
      view:set_wrapping_enabled(wrapped)
      linewrapping.complete_async_reconstruction(view)
      for _, selection in ipairs { { 4, 1, 2, 1 }, { 2, 1, 4, 1 } } do
        view:set_selection_state { selections = selection }

        near(caret_dx(view, selection[1], 1), 0)
        near(caret_dx(view, selection[3], 1), 0)
        near(view:get_caret_x_offset(selection[1], 1), view:get_col_x_offset(selection[1], 1))
      end

      view:set_selection_state { selections = { 4, 1, 4, 1 } }
      near(caret_dx(view, 4, 1), view:get_font():get_width("  "))
    end
    test.equal(text(buffer), "if ok then\n\n\n\nend\n")
  end)

  test.it("an empty-line selection leaves other carets and Views at their shown indentation", function(context)
    local buffer, view = new_editor(context, "if ok then\n\n\n\nend", "sample.lua")
    local other = TextView(buffer)
    other:set_selection_state { selections = { 2, 1, 2, 1 } }
    view:set_selection_state { selections = { 2, 1, 3, 1, 4, 1, 4, 1 } }

    near(caret_dx(view, 2, 1), 0)
    near(caret_dx(view, 4, 1), view:get_font():get_width("  "))
    near(caret_dx(other, 2, 1), other:get_font():get_width("  "))
  end)

  test.it("typing on an empty line writes its indentation first, and one undo removes both", function(context)
    local buffer, view = new_editor(context, "if ok then\n\nend", "sample.lua")
    buffer:set_selection(2, 1, 2, 1)

    test.ok(view:on_text_input("x"))
    view:update()

    test.equal(text(buffer), "if ok then\n  x\nend\n")
    test.same(caret(view), { 2, 4, 2, 4 })
    buffer:undo()
    test.equal(text(buffer), "if ok then\n\nend\n")
  end)

  test.it("one undo reverts Enter and its cleanup together", function(context)
    local buffer, view = new_editor(context, "if ok then\nend", "sample.lua")
    buffer:set_selection(1, 11, 1, 11)
    command.perform("core:newline")
    view:update()

    buffer:undo()

    test.equal(text(buffer), "if ok then\nend\n")
    buffer:redo()
    test.equal(text(buffer), "if ok then\n\nend\n")
  end)

  test.it("follows the line above after an undo and a different edit", function(context)
    local buffer, view = new_editor(context, "a\n\nb", "notes.txt")
    buffer:set_selection(1, 1, 1, 1)
    test.ok(view:on_text_input("  "))
    near(caret_dx(view, 2, 1), view:get_font():get_width("  "))

    buffer:undo()
    buffer:set_selection(1, 1, 1, 1)
    test.ok(view:on_text_input("x"))

    near(caret_dx(view, 2, 1), 0)
  end)

  test.it("Up and Down keep the goal column through an empty line", function(context)
    local buffer, view = new_editor(context, "abcdefghij\n\nabcdefghij", "notes.txt")
    buffer:set_selection(1, 9, 1, 9)

    command.perform("core:move_to_next_line")
    command.perform("core:move_to_next_line")

    test.same(caret(view), { 3, 9, 3, 9 })
  end)

  test.it("Down from an empty line starts at its indentation", function(context)
    local buffer, view = new_editor(context, "if ok then\n  x = 1\n\n  y = 2\nend", "sample.lua")
    buffer:set_selection(3, 1, 3, 1)

    command.perform("core:move_to_next_line")

    test.same(caret(view), { 4, 3, 4, 3 })
  end)

  test.it("Tab and Shift+Tab on an empty line move its caret by one level without writing whitespace", function(context)
    local buffer, view = new_editor(context, "if ok then\n\nend", "sample.lua")
    buffer:set_selection(2, 1, 2, 1)
    local space = view:get_font():get_width(" ")

    command.perform("core:indent")
    view:update()
    test.equal(text(buffer), "if ok then\n\nend\n")
    near(caret_dx(view, 2, 1), 4 * space)

    command.perform("core:unindent")
    command.perform("core:unindent")
    view:update()
    test.equal(text(buffer), "if ok then\n\nend\n")
    near(caret_dx(view, 2, 1), 0)

    command.perform("core:indent")
    command.perform("core:indent")
    test.ok(view:on_text_input("x"))
    test.equal(text(buffer), "if ok then\n    x\nend\n")
  end)

  test.it("a caret that leaves an empty line forgets its chosen level", function(context)
    local buffer, view = new_editor(context, "if ok then\n\nend", "sample.lua")
    buffer:set_selection(2, 1, 2, 1)

    command.perform("core:indent")
    view:update()
    command.perform("core:move_to_next_line")
    view:update()
    buffer:set_selection(2, 1, 2, 1)
    view:update()

    near(caret_dx(view, 2, 1), view:get_font():get_width("  "))
  end)

  test.it("Backspace on an empty line moves its caret to the block's indentation without writing whitespace", function(context)
    -- The empty line shows the indentation of `b)`, deeper than the block's.
    local buffer, view = new_editor(context, "f {\n  g(a,\n    b)\n\n}", "sample.odin")
    local block = view:get_font():get_width("  ")

    buffer:set_selection(4, 1, 4, 1)
    command.perform("core:backspace")
    view:update()
    test.equal(text(buffer), "f {\n  g(a,\n    b)\n\n}\n")
    near(caret_dx(view, 4, 1), block)

    command.perform("core:backspace")
    test.equal(text(buffer), "f {\n  g(a,\n    b)\n}\n")
  end)

  test.it("a line that an edit leaves holding only whitespace becomes empty, and its caret stays in place", function(context)
    local buffer, view = new_editor(context, "if ok then\n      foo\nend", "sample.lua")
    buffer:set_selection(2, 10, 2, 7)

    command.perform("core:backspace")
    view:update()

    test.equal(text(buffer), "if ok then\n\nend\n")
    test.same(caret(view), { 2, 1, 2, 1 })
    near(caret_dx(view, 2, 1), view:get_font():get_width("      "))
    buffer:undo()
    test.equal(text(buffer), "if ok then\n      foo\nend\n")
  end)

  test.it("Enter on an empty line keeps its caret's chosen level", function(context)
    local buffer, view = new_editor(context, "if ok then\n\nend", "sample.lua")
    buffer:set_selection(2, 1, 2, 1)
    command.perform("core:indent")

    command.perform("core:newline")
    view:update()

    test.equal(text(buffer), "if ok then\n\n\nend\n")
    test.same(caret(view), { 3, 1, 3, 1 })
    near(caret_dx(view, 3, 1), view:get_font():get_width("    "))

    command.perform("core:move_to_start_of_line")
    command.perform("core:newline")
    view:update()
    test.same(caret(view), { 4, 1, 4, 1 })
    near(caret_dx(view, 4, 1), 0)
    test.equal(text(buffer), "if ok then\n\n\n\nend\n")
  end)

  test.it("a line that an edit leaves holding only whitespace becomes empty when the caret leaves it", function(context)
    local buffer, view = new_editor(context, "if ok then\n      foo\nend", "sample.lua")
    buffer:set_selection(2, 10, 2, 7)

    command.perform("core:backspace")
    buffer:set_selection(2, 3, 2, 3)
    view:update()
    test.equal(text(buffer), "if ok then\n      \nend\n")

    command.perform("core:move_to_next_line")
    view:update()
    test.equal(text(buffer), "if ok then\n\nend\n")

    buffer:undo()
    test.equal(text(buffer), "if ok then\n      foo\nend\n")
  end)

  test.it("waits for new edits before it empties a line while redo is available", function(context)
    local buffer, view = new_editor(context, "if ok then\n      foo\nend", "sample.lua")
    buffer:set_selection(2, 10, 2, 7)
    command.perform("core:backspace")
    buffer:set_selection(2, 3, 2, 3)
    view:update()
    buffer:set_selection(3, 4, 3, 4)
    test.ok(view:on_text_input("x"))
    buffer:undo()

    command.perform("core:move_to_previous_line")
    command.perform("core:move_to_previous_line")
    view:update()

    test.equal(text(buffer), "if ok then\n      \nend\n")
    buffer:redo()
    test.equal(text(buffer), "if ok then\n      \nendx\n")
  end)

  test.it("a multi-line paste on an empty line starts at its indentation", function(context)
    local buffer = new_editor(context, "if ok then\n\nend", "sample.lua")
    buffer:set_selection(2, 1, 2, 1)
    system.set_clipboard("a()\nb()")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    command.perform("core:paste")

    test.equal(text(buffer), "if ok then\n  a()\n  b()\nend\n")
    buffer:undo()
    buffer:set_selection(2, 1, 2, 1)
    command.perform("core:move_to_previous_char")
    command.perform("core:paste")
    test.equal(text(buffer), "if ok then\n a()\n b()\nend\n")
  end)

  test.it("End leaves an empty line empty when its caret already shows the block's indentation", function(context)
    local buffer, view = new_editor(context, "f {\n  x\n\n}", "sample.odin")
    buffer:set_selection(3, 1, 3, 1)

    command.perform("core:move_to_end_of_line")
    view:update()

    test.equal(text(buffer), "f {\n  x\n\n}\n")
    test.same(caret(view), { 3, 1, 3, 1 })
  end)

  test.it("keeps whitespace-only lines that no edit touched", function(context)
    local buffer, view = new_editor(context, "if ok then\n  \nend", "sample.lua")
    buffer:set_selection(2, 3, 2, 3)

    view:update()
    command.perform("core:move_to_next_line")
    view:update()

    test.equal(text(buffer), "if ok then\n  \nend\n")
  end)

  test.it("keeps the margin on a blank line after a Markdown list item", function(context)
    local buffer, view = new_editor(context, "  - a\n\n- b", "notes.md")
    buffer:set_selection(2, 1, 2, 1)

    near(caret_dx(view, 2, 1), 0)
    test.ok(view:on_text_input("x"))
    test.equal(text(buffer), "  - a\nx\n- b\n")
  end)

  test.it("moving to an empty line's start places its caret at the margin before typing", function(context)
    for _, filename in ipairs { "notes.md", "notes.txt" } do
      for _, wrapped in ipairs { false, true } do
        for _, name in ipairs { "core:move_to_start_of_line", "core:move_to_start_of_indentation" } do
          local buffer, view = new_editor(context, "    tipoArquillas\n\n\nnext",
            "line-start-" .. #context.buffers .. "-" .. filename)
          view:set_wrapping_enabled(wrapped)
          linewrapping.complete_async_reconstruction(view)
          buffer:set_selection(2, 1, 2, 1)
          test.ok(caret_dx(view, 2, 1) > 0)

          test.ok(command.perform(name), name .. " in " .. filename .. " wrapped=" .. tostring(wrapped)
            .. " active=" .. tostring(core.active_view))
          view:update()

          near(caret_dx(view, 2, 1), 0)
          test.equal(buffer.lines[2], "\n")
          test.ok(view:on_text_input("x"))
          test.equal(text(buffer), "    tipoArquillas\nx\n\nnext\n")
        end
      end
    end
  end)

  test.it("Home and End move between the edges of the same shown indentation", function(context)
    for _, case in ipairs {
      { filename = "home-end.txt", content = "    text\n\nnext", line = 2 },
      { filename = "home-end.md", content = "- item\n    text\n\nnext", line = 3 },
      { filename = "home-end.odin", content = "f {\n  g(a,\n    b)\n\n}", line = 4 },
    } do
      local buffer, view = new_editor(context, case.content, case.filename, Editor)
      buffer:set_selection(case.line, 1, case.line, 1)
      local initial = view:get_caret_screen_position(case.line, 1)
      for _ = 1, 2 do
        test.ok(command.perform("core:move_to_start_of_line"))
        near(caret_dx(view, case.line, 1), 0)
        test.ok(command.perform("core:move_to_end_of_line"))
        near(view:get_caret_screen_position(case.line, 1), initial)
      end
      test.equal(text(buffer), case.content .. "\n")

      command.perform("core:indent")
      local deeper = view:get_caret_screen_position(case.line, 1)
      test.ok(deeper > initial)
      command.perform("core:move_to_start_of_indentation")
      command.perform("core:move_to_end_of_line")
      near(view:get_caret_screen_position(case.line, 1), deeper)
      command.perform("core:unindent")
      near(view:get_caret_screen_position(case.line, 1), initial)
      command.perform("core:move_to_start_of_line")
      command.perform("core:move_to_end_of_line")
      near(view:get_caret_screen_position(case.line, 1), initial)
      test.ok(view:on_text_input("x"))
      test.equal(buffer.lines[case.line], "    x\n")
    end
  end)

  test.it("Left and Right move through shown indentation without editing the line", function(context)
    for _, case in ipairs {
      { indent = "    ", left_columns = 3, typed = "  x\n" },
      { indent = "\t\t", left_columns = 2, typed = "x\n" },
    } do
      for _, wrapped in ipairs { false, true } do
        local content = case.indent .. "text\n\nnext"
        local buffer, view = new_editor(context, content, "arrows-" .. #context.buffers .. ".txt")
        view:set_wrapping_enabled(wrapped)
        linewrapping.complete_async_reconstruction(view)
        buffer:set_selection(2, 1, 2, 1)
        local space = view:get_font():get_width(" ")

        command.perform("core:move_to_previous_char")
        near(caret_dx(view, 2, 1), case.left_columns * space)
        test.same(caret(view), { 2, 1, 2, 1 })
        test.equal(text(buffer), content .. "\n")
        command.perform("core:move_to_next_char")
        near(caret_dx(view, 2, 1), 4 * space)
        command.perform("core:move_to_previous_char")
        command.perform("core:move_to_previous_char")
        test.ok(view:on_text_input("x"))
        test.equal(buffer.lines[2], case.typed)
        buffer:undo()
        test.equal(text(buffer), content .. "\n")

        buffer:set_selection(2, 1, 2, 1)
        command.perform("core:move_to_start_of_line")
        command.perform("core:move_to_previous_char")
        test.same(caret(view), { 1, #buffer.lines[1], 1, #buffer.lines[1] })
        command.perform("core:move_to_next_char")
        near(caret_dx(view, 2, 1), 0)
        for _ = 1, #case.indent do command.perform("core:move_to_next_char") end
        near(caret_dx(view, 2, 1), 4 * space)
        command.perform("core:move_to_next_char")
        test.same(caret(view), { 3, 1, 3, 1 })
      end
    end
  end)

  test.it("a click chooses a position within shown indentation for typing", function(context)
    local buffer, view = new_editor(context, "    text\n\nnext", "click.txt")
    local space = view:get_font():get_width(" ")
    local x, y = view:get_line_screen_position(2, 1)

    test.ok(command.perform("core:set_cursor", x + 2 * space, y + view:get_line_height() / 2))
    view:on_mouse_released("left", x + 2 * space, y)
    near(caret_dx(view, 2, 1), 2 * space)
    test.equal(buffer.lines[2], "\n")
    test.ok(view:on_text_input("x"))
    test.equal(text(buffer), "    text\n  x\nnext\n")

    buffer:undo()
    test.ok(command.perform("core:set_cursor", x + 10 * space, y + view:get_line_height() / 2))
    near(caret_dx(view, 2, 1), 4 * space)
    view:on_mouse_moved(x, y + view:get_line_height() / 2, 0, 0)
    view:on_mouse_released("left", x, y)
    near(caret_dx(view, 2, 1), 0)
    test.ok(view:on_text_input("x"))
    test.equal(buffer.lines[2], "x\n")
  end)

  test.it("Views keep separate chosen positions on the same empty line", function(context)
    local buffer, view = new_editor(context, "    text\n\nnext", "views.txt")
    buffer:set_selection(2, 1, 2, 1)
    local other = TextView(buffer)
    other:set_selection_state { selections = { 2, 1, 2, 1 } }

    command.perform("core:move_to_previous_char")

    near(caret_dx(view, 2, 1), 3 * view:get_font():get_width(" "))
    near(caret_dx(other, 2, 1), 4 * other:get_font():get_width(" "))
    core.set_active_view(other)
    command.perform("core:move_to_start_of_line")
    near(caret_dx(other, 2, 1), 0)
    near(caret_dx(view, 2, 1), 3 * view:get_font():get_width(" "))
  end)

  test.it("Markdown clicks and arrows use the same shown positions with or without wrapping", function(context)
    for _, wrapped in ipairs { false, true } do
      local buffer, view = new_editor(context, "- item\n    tipoArquillas\n\nnext",
        "markdown-caret-" .. tostring(wrapped) .. ".md", Editor)
      view:set_wrapping_enabled(wrapped)
      linewrapping.complete_async_reconstruction(view)
      buffer:set_selection(3, 1, 3, 1)
      local initial = view:get_caret_screen_position(3, 1)
      command.perform("core:move_to_previous_char")
      local x, y = view:get_caret_screen_position(3, 1)
      test.ok(x < initial)
      command.perform("core:move_to_start_of_line")
      test.ok(command.perform("core:set_cursor", x, y + view:get_line_height() / 2))
      view:on_mouse_released("left", x, y)
      near(view:get_caret_screen_position(3, 1), x)
      test.equal(buffer.lines[3], "\n")
      test.ok(view:on_text_input("x"))
      test.equal(buffer.lines[3], "   x\n")
    end
  end)

  test.it("line-start selection clears shown indentation without selecting nonexistent spaces", function(context)
    local buffer, view = new_editor(context, "    text\n\nnext", "selection.txt")
    buffer:set_selection(2, 1, 2, 1)
    command.perform("core:move_to_previous_char")

    command.perform("core:select_to_start_of_line")

    near(caret_dx(view, 2, 1), 0)
    test.same(caret(view), { 2, 1, 2, 1 })
    test.equal(text(buffer), "    text\n\nnext\n")
    command.perform("core:select_to_previous_char")
    test.equal(buffer:get_selection_text(), "\n")
    command.perform("core:move_to_next_char")
    near(caret_dx(view, 2, 1), 0)
    test.ok(view:on_text_input("x"))
    test.equal(buffer.lines[2], "x\n")
  end)

  test.it("vertical movement uses the chosen position after a horizontal move", function(context)
    for _, wrapped in ipairs { false, true } do
      local buffer, view = new_editor(context, "    text\n\nabcdefgh", "goal-" .. tostring(wrapped) .. ".txt")
      view:set_wrapping_enabled(wrapped)
      linewrapping.complete_async_reconstruction(view)
      buffer:set_selection(3, 5, 3, 5)
      command.perform("core:move_to_previous_line")
      command.perform("core:move_to_previous_char")
      command.perform("core:move_to_next_line")
      test.same(caret(view), { 3, 4, 3, 4 })
    end
  end)

  test.it("Enter carries separate chosen positions for several empty-line carets", function(context)
    local buffer, view = new_editor(context, "  a\n\n b\n\nlast", "several-carets.txt")
    buffer:set_selection_list { 2, 1, 2, 1, 4, 1, 4, 1 }
    command.perform("core:move_to_previous_char")

    command.perform("core:newline")
    view:update()

    test.same(caret(view), { 3, 1, 3, 1, 6, 1, 6, 1 })
    near(caret_dx(view, 3, 1), view:get_font():get_width(" "))
    near(caret_dx(view, 6, 1), 0)
    test.equal(text(buffer), "  a\n\n\n b\n\n\nlast\n")
    buffer:undo()
    test.equal(text(buffer), "  a\n\n b\n\nlast\n")
  end)
end)
