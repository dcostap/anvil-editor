local native_text = require "native_text"
local test = require "core.test"

test.describe("native_text API bridge", function()
  test.it("edits a native Buffer through an Editor", function()
    local buffer = native_text.new_buffer("abc")
    local editor = buffer:new_editor()

    test.equal(buffer:text(), "abc")
    test.equal(buffer:len(), 3)
    test.equal(buffer:line_count(), 1)
    test.equal(buffer:line(0), "abc")

    test.ok(editor:set_cursor(1))
    test.ok(editor:insert("XY"))
    test.equal(buffer:text(), "aXYbc")
    test.same(editor:cursor(), { cursor = 3 })

    test.ok(editor:undo())
    test.equal(buffer:text(), "abc")
    test.same(editor:cursor(), { cursor = 1 })

    test.ok(editor:redo())
    test.equal(buffer:text(), "aXYbc")
    test.same(editor:cursor(), { cursor = 3 })
  end)

  test.it("exposes native multi-cursor commands", function()
    local buffer = native_text.new_buffer("a\nb\nc")
    local editor = buffer:new_editor()

    test.ok(editor:set_cursor(1))
    test.ok(editor:dup_cursor_down())
    test.ok(editor:dup_cursor_down())
    test.equal(editor:cursor_count(), 3)
    test.same(editor:cursor(1), { cursor = 1 })
    test.same(editor:cursor(2), { cursor = 3 })
    test.same(editor:cursor(3), { cursor = 5 })
  end)

  test.it("uses Buffer line-ending mode for native newline insertion", function()
    local buffer = native_text.new_buffer("ab")
    local editor = buffer:new_editor()

    test.ok(buffer:set_line_ending_mode("crlf"))
    test.ok(editor:set_cursor(1))
    test.ok(editor:newline())
    test.equal(buffer:text(), "a\r\nb")
  end)
end)
