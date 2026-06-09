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
    test.ok(buffer:enable_tree_sitter("c"))
    test.not_ok(buffer:tree_sitter_is_dirty())
    test.equal(buffer:tree_sitter_language(), "c")
    test.equal(buffer:tree_sitter_root_kind(), "translation_unit")

    local function has_highlight(capture, text)
      for _, span in ipairs(buffer:tree_sitter_highlights()) do
        if span.capture == capture and buffer:text():sub(span.start_offset + 1, span.end_offset) == text then
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
    test.ok(buffer:reparse_tree_sitter())
    test.not_ok(buffer:tree_sitter_is_dirty())
    test.ok(has_highlight("keyword", "static"))
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
