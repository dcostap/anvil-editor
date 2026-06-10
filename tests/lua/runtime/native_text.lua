local native_text = require "native_text"
local test = require "core.test"

local core = require "core"

local function tmp_file(name)
  return core.temp_filename(name or "native-text-test")
end

test.describe("native_text API bridge", function()
  test.it("edits a native Buffer through an Editor", function()
    local buffer = native_text.new_buffer("abc")
    local editor = buffer:new_editor()

    test.equal(buffer:text(), "abc")
    test.equal(buffer:len(), 3)
    test.equal(buffer:line_count(), 1)
    test.equal(buffer:line(0), "abc")
    test.same(buffer:visible_lines(0, 0), {
      { line = 0, start_offset = 0, end_offset = 3, text = "abc" }
    })
    test.same(buffer:offset_to_line_col(2), { line = 0, col = 2 })
    test.equal(buffer:line_col_to_offset(0, 2), 2)

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

  test.it("returns walker-backed visible lines", function()
    local buffer = native_text.new_buffer("aa\nbb\n")
    test.same(buffer:visible_lines(0, 2), {
      { line = 0, start_offset = 0, end_offset = 3, text = "aa\n" },
      { line = 1, start_offset = 3, end_offset = 6, text = "bb\n" },
      { line = 2, start_offset = 6, end_offset = 6, text = "" },
    })
    test.same(buffer:visible_lines(1, 99), {
      { line = 1, start_offset = 3, end_offset = 6, text = "bb\n" },
      { line = 2, start_offset = 6, end_offset = 6, text = "" },
    })
  end)

  test.it("loads, saves, and reports file-backed Buffer state", function()
    local path = tmp_file("native-text-load-save")
    local saved = tmp_file("native-text-save-as")
    local fp = assert(io.open(path, "wb"))
    fp:write("aa\r\nbb")
    fp:close()

    local buffer = native_text.new_buffer()
    test.ok(buffer:load_file(path))
    test.equal(buffer:path(), path)
    test.equal(buffer:text(), "aa\r\nbb")
    test.not_ok(buffer:is_dirty())

    local editor = buffer:new_editor()
    test.ok(editor:set_cursor(2))
    test.ok(editor:insert("XX"))
    test.ok(buffer:is_dirty())
    test.ok(buffer:save_file(saved))
    test.equal(buffer:path(), saved)
    test.not_ok(buffer:is_dirty())

    local rf = assert(io.open(saved, "rb"))
    local data = rf:read("*a")
    rf:close()
    test.equal(data, "aaXX\r\nbb")

    os.remove(path)
    os.remove(saved)
  end)

  test.it("exposes native literal Buffer search", function()
    local buffer = native_text.new_buffer("Alpha beta alpha BETA")

    local start_offset, end_offset = buffer:find_literal("beta")
    test.equal(start_offset, 6)
    test.equal(end_offset, 10)

    start_offset, end_offset = buffer:find_literal("beta", 10, { case_sensitive = false })
    test.equal(start_offset, 17)
    test.equal(end_offset, 21)

    start_offset, end_offset = buffer:find_literal("alpha", buffer:len(), { case_sensitive = false, backwards = true })
    test.equal(start_offset, 11)
    test.equal(end_offset, 16)

    test.equal(buffer:find_literal("missing"), nil)
  end)

  test.it("exposes native literal replace-all as one undoable transaction", function()
    local buffer = native_text.new_buffer("one two one TWO")
    local editor = buffer:new_editor()

    test.equal(buffer:replace_all_literal("one", "1"), 2)
    test.equal(buffer:text(), "1 two 1 TWO")
    test.ok(editor:undo())
    test.equal(buffer:text(), "one two one TWO")

    test.equal(buffer:replace_all_literal("two", "2", { case_sensitive = false }), 2)
    test.equal(buffer:text(), "one 2 one 2")
    test.equal(buffer:replace_all_literal("missing", "x"), 0)
  end)

  test.it("exposes native selection and clipboard primitives", function()
    local buffer = native_text.new_buffer("alpha beta\ngamma")
    local editor = buffer:new_editor()

    test.ok(editor:set_cursor(8))
    test.ok(editor:select_word())
    test.same(editor:cursor(), { cursor = 10, selection = 6 })
    test.equal(editor:copy_selection(), "beta")

    test.ok(editor:select_all())
    test.same(editor:cursor(), { cursor = 16, selection = 0 })
    test.equal(editor:copy_selection(), "alpha beta\ngamma")

    test.ok(editor:set_cursor(12))
    test.ok(editor:select_line())
    test.equal(editor:copy_selection(), "gamma")
    test.equal(editor:cut_selection(), "gamma")
    test.equal(buffer:text(), "alpha beta\n")

    test.ok(editor:paste("delta"))
    test.equal(buffer:text(), "alpha beta\ndelta")
  end)

  test.it("exposes native line and word editing primitives", function()
    local buffer = native_text.new_buffer("one two\nthree")
    local editor = buffer:new_editor()

    test.ok(editor:set_cursor(7))
    test.ok(editor:backspace_word())
    test.equal(buffer:text(), "one \nthree")

    test.ok(editor:delete_word())
    test.equal(buffer:text(), "one ")

    buffer = native_text.new_buffer("one\ntwo")
    editor = buffer:new_editor()
    test.ok(editor:set_cursor(5))
    test.ok(editor:open_line_above())
    test.equal(buffer:text(), "one\n\ntwo")
    test.ok(editor:insert("inserted"))
    test.equal(buffer:text(), "one\ninserted\ntwo")

    test.ok(editor:delete_line())
    test.equal(buffer:text(), "one\ntwo")

    test.ok(editor:set_cursor(0))
    test.ok(editor:duplicate_line())
    test.equal(buffer:text(), "one\none\ntwo")
    test.ok(editor:undo())
    test.equal(buffer:text(), "one\ntwo")

    test.ok(editor:set_cursor(0))
    test.ok(editor:tab())
    test.equal(buffer:text(), "\tone\ntwo")
    test.ok(editor:untab())
    test.equal(buffer:text(), "one\ntwo")
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

  test.it("exposes native word, line-edge, and Buffer-edge movement", function()
    local buffer = native_text.new_buffer("foo bar\n  baz")
    local editor = buffer:new_editor()

    test.ok(editor:set_cursor(0))
    test.ok(editor:word_right(false))
    test.same(editor:cursor(), { cursor = 3 })
    test.ok(editor:word_right(true))
    test.same(editor:cursor(), { cursor = 7, selection = 3 })
    test.ok(editor:home_toggle_of_line(false))
    test.same(editor:cursor(), { cursor = 0 })

    test.ok(editor:set_cursor(11))
    test.ok(editor:home_toggle_of_line(false))
    test.same(editor:cursor(), { cursor = 10 })
    test.ok(editor:home_toggle_of_line(false))
    test.same(editor:cursor(), { cursor = 8 })
    test.ok(editor:end_of_line(true))
    test.same(editor:cursor(), { cursor = 13, selection = 8 })

    test.ok(editor:start_of_buffer(false))
    test.same(editor:cursor(), { cursor = 0 })
    test.ok(editor:end_of_buffer(true))
    test.same(editor:cursor(), { cursor = 13, selection = 0 })
  end)

  test.it("exposes native Tree-sitter parsing and highlights", function()
    local buffer = native_text.new_buffer("int main(void) {\n  return 1;\n}\n")
    test.equal(native_text.tree_sitter_language_for_filename("foo.c"), "c")
    test.equal(native_text.tree_sitter_language_for_filename("foo.txt"), nil)

    test.ok(buffer:enable_tree_sitter("c"))
    test.not_ok(buffer:tree_sitter_is_dirty())
    test.equal(buffer:tree_sitter_language(), "c")
    test.equal(buffer:tree_sitter_root_kind(), "translation_unit")

    local function has_highlight(capture, text)
      for _, span in ipairs(buffer:tree_sitter_highlights()) do
        if span.capture == capture and span.style and span.priority and buffer:text():sub(span.start_offset + 1, span.end_offset) == text then
          return true
        end
      end
      return false
    end

    test.ok(has_highlight("type", "int"))
    test.ok(has_highlight("function", "main"))
    test.ok(has_highlight("keyword", "return"))

    local editor = buffer:new_editor()
    test.ok(editor:set_cursor(0))
    test.ok(editor:insert("static "))
    test.ok(buffer:tree_sitter_is_dirty())
    test.ok(buffer:schedule_tree_sitter_reparse())
    test.ok(buffer:tree_sitter_parse_pending())
    for _ = 1, 500 do
      if buffer:poll_tree_sitter_reparse() then break end
      coroutine.yield(0.001)
    end
    test.not_ok(buffer:tree_sitter_is_dirty())
    test.not_ok(buffer:tree_sitter_parse_pending())
    test.ok(has_highlight("keyword", "static"))
  end)

  test.it("round-trips native sandbox view state", function()
    local NativeTextSandboxView = require "plugins.native_text_sandbox"
    local view = NativeTextSandboxView("abc\nxyz")
    view.editor:set_cursor(2)
    view.editor:add_cursor(6)
    view.scroll.x = 3
    view.scroll.y = 7
    view.scroll.to.x = 5
    view.scroll.to.y = 11

    local restored = NativeTextSandboxView.from_state(view:get_state())
    test.equal(restored.buffer:text(), "abc\nxyz")
    test.same(restored.editor:cursor(1), { cursor = 2 })
    test.same(restored.editor:cursor(2), { cursor = 6 })
    test.equal(restored.scroll.x, 3)
    test.equal(restored.scroll.y, 7)
    test.equal(restored.scroll.to.x, 5)
    test.equal(restored.scroll.to.y, 11)
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
