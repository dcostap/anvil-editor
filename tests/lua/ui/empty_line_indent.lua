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
  buffer:set_filename(filename, filename)
  local view = TextView(buffer)
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
    test.equal(caret_dx(view, 2, 1), view:get_font():get_width("  "))
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

  test.it("Tab on an empty line indents one level past its indentation", function(context)
    local buffer, view = new_editor(context, "if ok then\n\nend", "sample.lua")
    buffer:set_selection(2, 1, 2, 1)

    command.perform("core:indent")
    view:update()

    test.equal(text(buffer), "if ok then\n    \nend\n")
    test.same(caret(view), { 2, 5, 2, 5 })
  end)

  test.it("a multi-line paste on an empty line starts at its indentation", function(context)
    local buffer = new_editor(context, "if ok then\n\nend", "sample.lua")
    buffer:set_selection(2, 1, 2, 1)
    system.set_clipboard("a()\nb()")
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}

    command.perform("core:paste")

    test.equal(text(buffer), "if ok then\n  a()\n  b()\nend\n")
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

    test.equal(caret_dx(view, 2, 1), 0)
    test.ok(view:on_text_input("x"))
    test.equal(text(buffer), "  - a\nx\n- b\n")
  end)
end)
