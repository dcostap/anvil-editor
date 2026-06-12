local native_text = require "native_text"
local test = require "core.test"

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"

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
    test.equal(buffer:line_ending_mode(), "crlf")
    test.not_ok(buffer:is_dirty())

    local editor = buffer:new_editor()
    test.ok(editor:set_cursor(2))
    test.ok(editor:insert("XX"))
    test.ok(buffer:is_dirty())
    test.ok(buffer:set_path(saved))
    test.equal(buffer:path(), saved)
    test.ok(buffer:is_dirty())
    test.ok(buffer:save_file())
    test.equal(buffer:path(), saved)
    test.not_ok(buffer:is_dirty())

    local rf = assert(io.open(saved, "rb"))
    local data = rf:read("*a")
    rf:close()
    test.equal(data, "aaXX\r\nbb")

    os.remove(path)
    os.remove(saved)
  end)

  test.it("reuses registered file-backed Buffers by identity", function()
    local path = tmp_file("native-text-registry")
    local fp = assert(io.open(path, "wb"))
    fp:write("one")
    fp:close()

    local first, reused = native_text.open_file_buffer(path, path)
    test.ok(first)
    test.not_ok(reused)
    local second
    second, reused = native_text.open_file_buffer(path, path)
    test.equal(second, first)
    test.ok(reused)

    local editor = first:new_editor()
    test.ok(editor:set_cursor(3))
    test.ok(editor:insert(" two"))
    test.equal(second:text(), "one two")

    test.ok(native_text.release_file_buffer(path, first))
    second, reused = native_text.open_file_buffer(path, path)
    test.ok(second)
    test.not_ok(reused)
    test.equal(second:text(), "one")

    os.remove(path)
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

    buffer = native_text.new_buffer("α β α")
    editor = buffer:new_editor()
    test.equal(buffer:replace_all_literal("α", "z"), 2)
    test.equal(buffer:text(), "z β z")
    test.ok(editor:undo())
    test.equal(buffer:text(), "α β α")
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

    buffer = native_text.new_buffer("  alpha\nbeta")
    editor = buffer:new_editor()
    test.ok(editor:set_cursor(3))
    test.ok(editor:newline_auto_indent())
    test.equal(buffer:text(), "  a\n  lpha\nbeta")

    buffer = native_text.new_buffer("one\ntwo")
    editor = buffer:new_editor()
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

  test.it("round-trips native editor view state", function()
    local NativeEditorView = require "plugins.native_editor"
    local view = NativeEditorView("abc\nxyz")
    view.editor:set_cursor(2)
    view.editor:add_cursor(6)
    view.scroll.x = 3
    view.scroll.y = 7
    view.scroll.to.x = 5
    view.scroll.to.y = 11

    local restored = NativeEditorView.from_state(view:get_state())
    test.equal(restored.buffer:text(), "abc\nxyz")
    test.same(restored.editor:cursor(1), { cursor = 2 })
    test.same(restored.editor:cursor(2), { cursor = 6 })
    test.equal(restored.scroll.x, 3)
    test.equal(restored.scroll.y, 7)
    test.equal(restored.scroll.to.x, 5)
    test.equal(restored.scroll.to.y, 11)

    view = NativeEditorView("αβ\n中😀")
    view.editor:set_cursor(view.buffer:line_col_to_offset(0, 4), view.buffer:line_col_to_offset(0, 0))
    view.editor:add_cursor(view.buffer:line_col_to_offset(1, 7))
    restored = NativeEditorView.from_state(view:get_state())
    test.equal(restored.buffer:text(), "αβ\n中😀")
    test.same(restored.editor:cursor(1), { cursor = 4, selection = 0 })
    test.same(restored.editor:cursor(2), { cursor = 12 })
    test.equal(restored.editor:copy_selection(), "αβ")
  end)

  test.it("routes native editor commands through the canonical namespace", function()
    local NativeEditorView = require "plugins.native_editor"
    local original_active_view = core.active_view
    local ok, err = pcall(function()
      local view = NativeEditorView("abc")
      core.active_view = view
      test.ok(command.is_valid("native-editor:toggle-line-ending"))
      test.ok(command.is_valid("native-text-sandbox:toggle-line-ending"))
      test.equal(view.buffer:line_ending_mode(), "lf")
      test.ok(command.perform("native-editor:toggle-line-ending"))
      test.equal(view.buffer:line_ending_mode(), "crlf")
      test.ok(command.perform("native-text-sandbox:toggle-line-ending"))
      test.equal(view.buffer:line_ending_mode(), "lf")
      test.ok(command.perform("native-editor:toggle-line-ending"))
      test.equal(view.buffer:line_ending_mode(), "crlf")
      view.editor:set_cursor(1)
      test.ok(command.perform("native-editor:newline"))
      test.equal(view.buffer:text(), "a\r\nbc")
      test.ok(view.editor:undo())
      test.equal(view.buffer:text(), "abc")
      test.not_ok(view.editor:overwrite_mode())
      test.ok(command.perform("native-editor:toggle-overwrite"))
      test.ok(view.editor:overwrite_mode())
      view.editor:set_cursor(1)
      view:on_text_input("X")
      test.equal(view.buffer:text(), "aXc")

      local valid = command.get_all_valid()
      test.contains(valid, "native-editor:toggle-line-ending")
      for _, name in ipairs(valid) do
        test.not_equal(name, "native-text-sandbox:toggle-line-ending")
      end
    end)
    core.active_view = original_active_view
    if not ok then error(err) end
  end)

  test.it("supports native editor select-none and whole-line copy/cut parity", function()
    local NativeEditorView = require "plugins.native_editor"
    local original_active_view = core.active_view
    local ok, err = pcall(function()
      local view = NativeEditorView("one\ntwo\nthree")
      core.active_view = view
      view.editor:set_cursor(5, 4)
      view.editor:add_cursor(9)
      test.ok(view:has_selection())
      test.ok(command.perform("native-editor:select-none"))
      test.same(view.editor:cursor(), { cursor = 5 })
      test.equal(view.editor:cursor_count(), 1)

      view.editor:set_cursor(view.buffer:line_col_to_offset(1, 0))
      test.ok(command.perform("native-editor:copy"))
      test.equal(system.get_clipboard(), "two\n")
      test.equal(core.cursor_clipboard["full"], "two\n")
      test.ok(core.cursor_clipboard_whole_line[1])

      test.ok(command.perform("native-editor:cut"))
      test.equal(system.get_clipboard(), "two\n")
      test.equal(view.buffer:text(), "one\nthree")

      view.editor:set_cursor(view.buffer:line_col_to_offset(1, 0))
      test.ok(command.perform("native-editor:paste"))
      test.equal(view.buffer:text(), "one\ntwo\nthree")
      test.same(view.editor:cursor(), { cursor = view.buffer:line_col_to_offset(2, 0) })

      view = NativeEditorView("α\r\nβ\r\nγ")
      core.active_view = view
      view.editor:set_cursor(view.buffer:line_col_to_offset(0, 0))
      view.editor:add_cursor(view.buffer:line_col_to_offset(2, 0))
      test.equal(view.buffer:line_ending_mode(), "crlf")
      test.ok(command.perform("native-editor:copy"))
      test.equal(tostring(system.get_clipboard()):gsub("\r\n", "\n"), "α\nγ\n")
      test.equal(core.cursor_clipboard["full"], "α\r\nγ\r\n")
      test.ok(core.cursor_clipboard_whole_line[1])
      test.ok(core.cursor_clipboard_whole_line[2])
      view.editor:clear_multi_cursors()
      view.editor:set_cursor(view.buffer:line_col_to_offset(1, 0))
      test.ok(command.perform("native-editor:paste"))
      test.equal(view.buffer:text(), "α\r\nα\r\nγ\r\nβ\r\nγ")

      view = NativeEditorView("one\ntwo\nthree\nfour")
      core.active_view = view
      view.editor:set_cursor(view.buffer:line_col_to_offset(0, 0))
      view.editor:add_cursor(view.buffer:line_col_to_offset(2, 0))
      test.ok(command.perform("native-editor:copy"))
      test.equal(system.get_clipboard(), "one\nthree\n")
      view.editor:clear_multi_cursors()
      view.editor:set_cursor(view.buffer:line_col_to_offset(1, 0))
      view.editor:add_cursor(view.buffer:line_col_to_offset(3, 0))
      test.ok(command.perform("native-editor:paste"))
      test.equal(view.buffer:text(), "one\none\nthree\ntwo\nthree\none\nthree\nfour")
      test.ok(view.editor:undo())
      test.equal(view.buffer:text(), "one\ntwo\nthree\nfour")
    end)
    core.active_view = original_active_view
    if not ok then error(err) end
  end)

  test.it("supports native editor IME composition replacement", function()
    local NativeEditorView = require "plugins.native_editor"
    local original_active_view = core.active_view
    local ok, err = pcall(function()
      local view = NativeEditorView("abc")
      core.active_view = view
      view.editor:set_cursor(1)
      test.ok(view:on_ime_text_editing("xy", 1, 0))
      test.equal(view.buffer:text(), "axybc")
      test.same(view.editor:cursor(), { cursor = 3, selection = 1 })
      test.ok(view.ime_status)
      test.equal(view.ime_selection.from, 1)
      test.ok(view:on_ime_text_editing("xz", 2, 0))
      test.equal(view.buffer:text(), "axzbc")
      test.same(view.editor:cursor(), { cursor = 3, selection = 1 })
      test.ok(view:on_ime_text_editing("", 0, 0))
      test.equal(view.buffer:text(), "abc")
      test.same(view.editor:cursor(), { cursor = 1 })
      test.not_ok(view.ime_status)

      test.ok(view:on_ime_text_editing("xy", 0, 2))
      test.equal(view.buffer:text(), "axybc")
      test.same(view.editor:cursor(), { cursor = 3, selection = 1 })
      test.ok(view:on_text_input("字"))
      test.equal(view.buffer:text(), "a字bc")
      test.same(view.editor:cursor(), { cursor = 4 })
      test.not_ok(view.ime_status)

      view = NativeEditorView("abc")
      core.active_view = view
      view.editor:set_cursor(1)
      view.editor:set_overwrite_mode(true)
      test.ok(view:on_ime_text_editing("é", 1, 0))
      test.equal(view.buffer:text(), "aébc")
      test.same(view.editor:cursor(), { cursor = 3, selection = 1 })
      test.ok(view.editor:overwrite_mode())
    end)
    core.active_view = original_active_view
    if not ok then error(err) end
  end)

  test.it("toggles native editor line comments by file type", function()
    local NativeEditorView = require "plugins.native_editor"
    local original_active_view = core.active_view
    local ok, err = pcall(function()
      local view = NativeEditorView("local x\n  print(x)\n\n")
      view.buffer:set_path("test.lua")
      core.active_view = view
      view.editor:set_cursor(view.buffer:line_col_to_offset(0, 0), view.buffer:line_col_to_offset(2, 0))
      test.ok(command.perform("native-editor:toggle-line-comment"))
      test.equal(view.buffer:text(), "-- local x\n  -- print(x)\n\n")
      test.ok(view.editor:undo())
      test.equal(view.buffer:text(), "local x\n  print(x)\n\n")
      test.ok(view.editor:redo())
      test.equal(view.buffer:text(), "-- local x\n  -- print(x)\n\n")
      view.editor:set_cursor(view.buffer:line_col_to_offset(0, 0), view.buffer:line_col_to_offset(2, 0))
      test.ok(command.perform("native-editor:toggle-line-comment"))
      test.equal(view.buffer:text(), "local x\n  print(x)\n\n")

      view.buffer:set_path("test.c")
      view.editor:set_cursor(view.buffer:line_col_to_offset(1, 2))
      test.ok(command.perform("native-editor:toggle-line-comment"))
      test.equal(view.buffer:text(), "local x\n  // print(x)\n\n")
      test.ok(view.editor:undo())
      test.equal(view.buffer:text(), "local x\n  print(x)\n\n")

      view = NativeEditorView("a\nb\nc\n")
      view.buffer:set_path("test.lua")
      core.active_view = view
      view.editor:set_cursor(view.buffer:line_col_to_offset(1, 0), view.buffer:line_col_to_offset(0, 0))
      test.ok(command.perform("native-editor:toggle-line-comment"))
      test.equal(view.buffer:text(), "-- a\nb\nc\n")
    end)
    core.active_view = original_active_view
    if not ok then error(err) end
  end)

  test.it("computes native editor bracket match rects", function()
    local NativeEditorView = require "plugins.native_editor"
    local view = NativeEditorView("(a[b])\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    view.editor:set_cursor(3)
    view.bracket_match_state = view:compute_bracket_match_state()
    test.same(view.bracket_match_state, { anchor = 2, match = 4 })
    local rects = view:get_bracket_match_rects(0)
    test.equal(#rects, 2)
    test.equal(rects[1].offset, 2)
    test.equal(rects[2].offset, 4)
    test.equal(rects[1].h, view:get_line_height())

    view.editor:set_cursor(6)
    view.bracket_match_state = view:compute_bracket_match_state()
    test.same(view.bracket_match_state, { anchor = 5, match = 0 })
    test.ok(view:move_to_matching_bracket(false))
    test.same(view.editor:cursor(), { cursor = 0 })
    view.editor:set_cursor(3)
    test.ok(view:move_to_matching_bracket(true))
    test.same(view.editor:cursor(), { cursor = 5, selection = 2 })

    view = NativeEditorView("é({x})\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    view.editor:set_cursor(4)
    view.bracket_match_state = view:compute_bracket_match_state()
    test.same(view.bracket_match_state, { anchor = 3, match = 5 })
    test.ok(view:move_to_matching_bracket(false))
    test.same(view.editor:cursor(), { cursor = 5 })
  end)

  test.it("animates native editor caret positions on same-line moves", function()
    local NativeEditorView = require "plugins.native_editor"
    local old_animated = config.animated_caret
    local ok, err = pcall(function()
      config.animated_caret = true
      local view = NativeEditorView("abcdef\nxyz")
      view.position.x, view.position.y = 10, 20
      view.size.x, view.size.y = 500, 300
      local x1, y1 = view:line_col_to_screen(0, 0)
      local ax1, ay1 = view:get_caret_draw_position(1, x1, y1)
      test.same({ ax1, ay1 }, { x1, y1 })

      local x2, y2 = view:line_col_to_screen(0, 5)
      local ax2, ay2 = view:get_caret_draw_position(1, x2, y2)
      test.equal(ay2, y2)
      test.ok(ax2 >= math.min(x1, x2) and ax2 <= math.max(x1, x2))

      local x3, y3 = view:line_col_to_screen(1, 0)
      local ax3, ay3 = view:get_caret_draw_position(1, x3, y3)
      test.same({ ax3, ay3 }, { x3, y3 })
    end)
    config.animated_caret = old_animated
    if not ok then error(err) end
  end)

  test.it("applies centered-editor geometry to native editor helpers", function()
    require "plugins.centered_editor"
    local NativeEditorView = require "plugins.native_editor"
    local old = config.plugins.centered_editor
    local ok, err = pcall(function()
      config.plugins.centered_editor = {
        enabled = true,
        max_width = 1000,
        scale_width = false,
        min_margin = 0,
        main_tabs_only = false,
      }
      local view = NativeEditorView("abc\n")
      view.position.x, view.position.y = 0, 20
      view.size.x, view.size.y = 2000, 300
      local x, y = view:line_col_to_screen(0, 0)
      local expected_lane_x = 500
      test.equal(x, expected_lane_x + view:get_gutter_width() + style.padding.x)
      test.equal(y, 20 + style.padding.y)
      local line, col = view:screen_to_line_col(x, y)
      test.same({ line, col }, { 0, 0 })
      test.ok(core.centered_editor.should_center(view))
    end)
    config.plugins.centered_editor = old
    if not ok then error(err) end
  end)

  test.it("computes native editor selection highlight rects", function()
    local NativeEditorView = require "plugins.native_editor"
    local view = NativeEditorView("foo bar Foo foo\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    local selection_start = view.buffer:line_col_to_offset(0, 0)
    local selection_end = view.buffer:line_col_to_offset(0, 3)
    view.editor:set_cursor(selection_end, selection_start)
    local rects = view:get_selection_highlight_rects(0, 20)
    test.equal(#rects, 2)
    local x_foo_2 = view:line_col_to_screen(0, 8)
    local x_foo_3 = view:line_col_to_screen(0, 12)
    test.equal(rects[1].x, x_foo_2)
    test.equal(rects[2].x, x_foo_3)
    test.equal(rects[1].h, view:get_line_height())

    view.editor:set_cursor(view.buffer:line_col_to_offset(0, 4), view.buffer:line_col_to_offset(0, 5))
    test.equal(#view:get_selection_highlight_rects(0, 20), 0)

    view = NativeEditorView("α beta α\nα\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    view.editor:set_cursor(view.buffer:line_col_to_offset(0, 2), view.buffer:line_col_to_offset(0, 0))
    rects = view:get_selection_highlight_rects(0, 20)
    test.equal(#rects, 1)
    local x_alpha_2 = view:line_col_to_screen(0, 8)
    test.equal(rects[1].x, x_alpha_2)
    test.equal(rects[1].w, select(1, view:line_col_to_screen(0, 10)) - x_alpha_2)
    rects = view:get_selection_highlight_rects(1, 40)
    test.equal(#rects, 1)
    test.equal(rects[1].x, select(1, view:line_col_to_screen(1, 0)))
  end)

  test.it("computes native editor indent guides from indent-guide settings", function()
    require "plugins.indent_guides"
    local NativeEditorView = require "plugins.native_editor"
    local old_enabled = core.indent_guides.enabled
    local old_highlight = core.indent_guides.highlight_active
    local ok, err = pcall(function()
      core.indent_guides.enabled = true
      core.indent_guides.highlight_active = true
      local view = NativeEditorView("if x then\n  if y then\n\n    z()\n  end\nend\n")
      view.position.x, view.position.y = 10, 20
      view.size.x, view.size.y = 500, 300
      view.editor:set_cursor(view.buffer:line_col_to_offset(1, 0))
      local _, indent_size = view:get_indent_info()
      test.equal(indent_size, 2)
      local rects = view:get_indent_guide_rects(3, 40)
      test.equal(#rects, 1)
      test.equal(rects[1].depth, 1)
      test.equal(rects[1].h, view:get_line_height())
      local blank_rects = view:get_indent_guide_rects(2, 80)
      test.equal(#blank_rects, 1)
    end)
    core.indent_guides.enabled = old_enabled
    core.indent_guides.highlight_active = old_highlight
    if not ok then error(err) end
  end)

  test.it("computes native editor whitespace markers from draw-whitespace settings", function()
    require "plugins.drawwhitespace"
    local NativeEditorView = require "plugins.native_editor"
    local old_enabled = core.draw_whitespace.enabled
    local ok, err = pcall(function()
      core.draw_whitespace.enabled = true
      core.draw_whitespace.show_selected_only = false
      local view = NativeEditorView("  a  b\t\n")
      local markers = view:get_whitespace_markers(0)
      test.equal(#markers, 5)
      test.same({ markers[1].col, markers[1].text, markers[1].kind }, { 0, "·", "space" })
      test.same({ markers[2].col, markers[2].text, markers[2].kind }, { 1, "·", "space" })
      test.same({ markers[5].col, markers[5].text, markers[5].kind }, { 6, "→", "tab" })

      view = NativeEditorView("α  β\n")
      markers = view:get_whitespace_markers(0)
      test.equal(#markers, 2)
      test.same({ markers[1].col, markers[1].text, markers[1].kind }, { 2, "·", "space" })
      test.same({ markers[2].col, markers[2].text, markers[2].kind }, { 3, "·", "space" })
    end)
    core.draw_whitespace.enabled = old_enabled
    if not ok then error(err) end
  end)

  test.it("computes native editor column guide rects from existing guide config", function()
    local NativeEditorView = require "plugins.native_editor"
    local old_column_guides = config.plugins.column_guides
    local old_lineguide = config.plugins.lineguide
    local ok, err = pcall(function()
      config.plugins.column_guides = { enabled = true, columns = { 10 } }
      config.plugins.lineguide = { enabled = true, width = 2, rulers = { 20 } }
      local view = NativeEditorView("abc\n")
      view.position.x, view.position.y = 10, 20
      view.size.x, view.size.y = 500, 300
      view.scroll.x, view.scroll.y = 0, 0
      local rects = view:get_column_guide_rects()
      test.equal(#rects, 2)
      test.equal(rects[1].kind, "column-guide")
      test.equal(rects[2].kind, "lineguide")
      local text_x = view.position.x + view:get_gutter_width() + style.padding.x
      local char_w = view:get_font():get_width("n")
      test.equal(rects[1].x, text_x + char_w * 10)
      test.equal(rects[2].x, text_x + char_w * 20)
      test.equal(rects[1].h, view.size.y)
    end)
    config.plugins.column_guides = old_column_guides
    config.plugins.lineguide = old_lineguide
    if not ok then error(err) end
  end)

  test.it("detects native editor indentation for status and tab metrics", function()
    local NativeEditorView = require "plugins.native_editor"
    local old_tab_type, old_indent_size = config.tab_type, config.indent_size
    config.tab_type, config.indent_size = "soft", 4
    local ok, err = pcall(function()
      local soft = NativeEditorView("  one\n    two\n  three\n    four\n")
      local indent_type, indent_size, confirmed = soft:get_indent_info()
      test.equal(indent_type, "soft")
      test.equal(indent_size, 2)
      test.ok(confirmed)

      local hard = NativeEditorView("\tone\n\t\ttwo\n\tthree\n")
      indent_type, indent_size, confirmed = hard:get_indent_info()
      test.equal(indent_type, "hard")
      test.equal(indent_size, 4)
      test.ok(confirmed)
    end)
    config.tab_type, config.indent_size = old_tab_type, old_indent_size
    if not ok then error(err) end
  end)

  test.it("opens file-backed native editor views through the core facade", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-core-open")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = core.open_native_editor_file(path)
    test.ok(core.is_native_editor_view(view))
    test.equal(view.buffer:text(), "abc")
    test.equal(core.open_native_editor_file(path), view)

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
  end)

  test.it("updates native editor Buffer paths after filetree-style renames", function()
    require "plugins.native_editor"
    local old_path = tmp_file("native-editor-rename-old")
    local new_path = tmp_file("native-editor-rename-new")
    local fp = assert(io.open(old_path, "wb"))
    fp:write("abc")
    fp:close()
    os.remove(new_path)

    local view = core.open_native_editor_file(old_path)
    test.ok(os.rename(old_path, new_path))
    test.equal(core.rename_native_editor_buffer_path(old_path, new_path, "file"), 1)
    test.ok(common.path_equals(view.buffer:path(), new_path))

    local key = common.path_compare_key(system.absolute_path(new_path) or new_path)
    local buffer, reused = native_text.open_file_buffer(new_path, key)
    test.equal(buffer, view.buffer)
    test.ok(reused)
    native_text.release_file_buffer(key, buffer)

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(new_path)
  end)

  test.it("keeps native editor hit-testing on UTF-8 codepoint boundaries", function()
    local NativeEditorView = require "plugins.native_editor"

    local function set_view_geometry(view)
      view.position.x, view.position.y = 10, 20
      view.size.x, view.size.y = 500, 300
      view.scroll.x, view.scroll.y = 0, 0
      view.scroll.to.x, view.scroll.to.y = 0, 0
    end

    local samples = {
      { text = "a©b", boundaries = { 0, 1, 3, 4 }, spans = { { 1, 3 } } },
      { text = "a中b", boundaries = { 0, 1, 4, 5 }, spans = { { 1, 4 } } },
      { text = "a😀b", boundaries = { 0, 1, 5, 6 }, spans = { { 1, 5 } } },
      { text = "éx", boundaries = { 0, 1, 3, 4 }, spans = { { 1, 3 } } },
    }

    for _, sample in ipairs(samples) do
      local view = NativeEditorView(sample.text)
      set_view_geometry(view)
      local _, y = view:line_col_to_screen(0, 0)
      local valid = {}
      for _, offset in ipairs(sample.boundaries) do
        valid[offset] = true
        local x = view:line_col_to_screen(0, offset)
        test.equal(view:screen_to_offset(x, y), offset)
      end
      for _, span in ipairs(sample.spans) do
        local before_x = view:get_col_x_offset(1, span[1] + 1)
        local after_x = view:get_col_x_offset(1, span[2] + 1)
        local probes = { before_x, (before_x + after_x) / 2, after_x }
        if after_x > before_x then
          probes[#probes + 1] = before_x + (after_x - before_x) * 0.25
          probes[#probes + 1] = before_x + (after_x - before_x) * 0.75
        end
        for _, probe in ipairs(probes) do
          local col = view:get_x_offset_col(1, probe) - 1
          local offset = view.buffer:line_col_to_offset(0, col)
          test.ok(valid[offset], sample.text .. " hit-test returned interior byte offset " .. tostring(offset))
        end
      end
    end
  end)

  test.it("keeps native editor mouse drag selections on UTF-8 boundaries", function()
    local NativeEditorView = require "plugins.native_editor"
    local keymap = require "core.keymap"
    local view = NativeEditorView("a中b😀c\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    view.scroll.x, view.scroll.y = 0, 0
    view.scroll.to.x, view.scroll.to.y = 0, 0

    local old_ctrl, old_shift = keymap.modkeys["ctrl"], keymap.modkeys["shift"]
    local ok, err = pcall(function()
      keymap.modkeys["ctrl"], keymap.modkeys["shift"] = false, false
      local start_x, y = view:line_col_to_screen(0, 1)
      local end_x = view:line_col_to_screen(0, 9)
      test.ok(view:on_mouse_pressed("left", start_x, y, 1))
      test.ok(view:on_mouse_moved(end_x, y))
      view:on_mouse_released("left", end_x, y)
      test.same(view.editor:cursor(), { cursor = 9, selection = 1 })
      test.equal(view.editor:copy_selection(), "中b😀")
      if system.get_primary_selection then
        test.equal(system.get_primary_selection(), "中b😀")
      end
    end)
    keymap.modkeys["ctrl"], keymap.modkeys["shift"] = old_ctrl, old_shift
    if not ok then error(err) end
  end)

  test.it("keeps native editor gutter line selection on UTF-8 line boundaries", function()
    local NativeEditorView = require "plugins.native_editor"
    local keymap = require "core.keymap"
    local view = NativeEditorView("α one\nβ two\nγ three\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    view.scroll.x, view.scroll.y = 0, 0
    view.scroll.to.x, view.scroll.to.y = 0, 0

    local old_ctrl, old_shift = keymap.modkeys["ctrl"], keymap.modkeys["shift"]
    local ok, err = pcall(function()
      keymap.modkeys["ctrl"], keymap.modkeys["shift"] = false, false
      local x = view.position.x + 1
      local _, y1 = view:line_col_to_screen(0, 0)
      local _, y2 = view:line_col_to_screen(1, 0)
      test.ok(view:on_mouse_pressed("left", x, y1, 1))
      test.ok(view:on_mouse_moved(x, y2))
      view:on_mouse_released("left", x, y2)
      test.same(view.editor:cursor(), { cursor = view.buffer:line_col_to_offset(2, 0), selection = 0 })
      test.equal(view.editor:copy_selection(), "α one\nβ two\n")
      if system.get_primary_selection then
        test.equal(system.get_primary_selection(), "α one\nβ two\n")
      end
    end)
    keymap.modkeys["ctrl"], keymap.modkeys["shift"] = old_ctrl, old_shift
    if not ok then error(err) end
  end)

  test.it("scrolls native editor horizontally to a UTF-8 caret", function()
    local NativeEditorView = require "plugins.native_editor"
    local text = string.rep("abcd ", 30) .. "中😀tail"
    local view = NativeEditorView(text)
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 180, 200
    view.scroll.x, view.scroll.y = 0, 0
    view.scroll.to.x, view.scroll.to.y = 0, 0
    view.editor:set_cursor(#text)
    view:scroll_to_cursor()
    test.ok(view.scroll.to.x > 0)
    view.scroll.x = view.scroll.to.x
    local x = view:line_col_to_screen(0, #text)
    test.ok(x <= view.position.x + view.size.x)
  end)

  test.it("finds UTF-8 literals and wraps without splitting selections", function()
    local NativeEditorView = require "plugins.native_editor"
    local old_case_sensitive = config.find_case_sensitive
    local ok, err = pcall(function()
      config.find_case_sensitive = true
      local view = NativeEditorView("α one\nβ two α\n")
      view.position.x, view.position.y = 10, 20
      view.size.x, view.size.y = 500, 300
      view.editor:set_cursor(0)
      test.ok(view:find_literal("α", false))
      test.same(view.editor:cursor(), { cursor = 2, selection = 0 })
      test.equal(view.editor:copy_selection(), "α")
      test.ok(view:find_literal("α", false))
      test.same(view.editor:cursor(), { cursor = 16, selection = 14 })
      test.equal(view.editor:copy_selection(), "α")
      test.ok(view:find_literal("α", false))
      test.same(view.editor:cursor(), { cursor = 2, selection = 0 })
      test.ok(view:find_literal("β", true))
      test.same(view.editor:cursor(), { cursor = 9, selection = 7 })
      test.equal(view.editor:copy_selection(), "β")
    end)
    config.find_case_sensitive = old_case_sensitive
    if not ok then error(err) end
  end)

  test.it("replaces UTF-8 text through native editor prompt commands as undoable edits", function()
    local NativeEditorView = require "plugins.native_editor"
    local original_active_view = core.active_view
    local original_prompt_bar = core.global_prompt_bar
    local prompts = {}
    local ok, err = pcall(function()
      local view = NativeEditorView("α one α\n")
      core.active_view = view
      core.global_prompt_bar = {
        enter = function(_, title, options)
          prompts[#prompts + 1] = { title = title, options = options }
        end
      }
      test.ok(command.perform("native-editor:replace-all"))
      test.equal(prompts[1].title, "Native Replace All Text")
      prompts[1].options.submit("α")
      test.equal(prompts[2].title, "Native Replace With")
      prompts[2].options.submit("β")
      test.equal(view.buffer:text(), "β one β\n")
      test.ok(view.editor:undo())
      test.equal(view.buffer:text(), "α one α\n")

      prompts = {}
      view.editor:set_cursor(2, 0)
      test.ok(command.perform("native-editor:replace"))
      prompts[1].options.submit("α")
      prompts[2].options.submit("γ")
      test.equal(view.buffer:text(), "γ one α\n")
      test.ok(view.editor:undo())
      test.equal(view.buffer:text(), "α one α\n")
    end)
    core.global_prompt_bar = original_prompt_bar
    core.active_view = original_active_view
    if not ok then error(err) end
  end)

  test.it("selects UTF-8 word ranges through double-click without interior byte offsets", function()
    local NativeEditorView = require "plugins.native_editor"
    local keymap = require "core.keymap"
    local view = NativeEditorView("aa 中😀 bb\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    view.scroll.x, view.scroll.y = 0, 0
    view.scroll.to.x, view.scroll.to.y = 0, 0

    local old_ctrl, old_shift = keymap.modkeys["ctrl"], keymap.modkeys["shift"]
    local ok, err = pcall(function()
      keymap.modkeys["ctrl"], keymap.modkeys["shift"] = false, false
      local x, y = view:line_col_to_screen(0, 3)
      test.ok(view:on_mouse_pressed("left", x, y, 2))
      test.same(view.editor:cursor(), { cursor = 10, selection = 3 })
      test.equal(view.editor:copy_selection(), "中😀")
    end)
    keymap.modkeys["ctrl"], keymap.modkeys["shift"] = old_ctrl, old_shift
    if not ok then error(err) end
  end)

  test.it("keeps UTF-8 mouse shift-click, ctrl-click, and triple-click selections valid", function()
    local NativeEditorView = require "plugins.native_editor"
    local keymap = require "core.keymap"
    local view = NativeEditorView("a中\nb😀\nc\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    view.scroll.x, view.scroll.y = 0, 0
    view.scroll.to.x, view.scroll.to.y = 0, 0

    local old_ctrl, old_shift = keymap.modkeys["ctrl"], keymap.modkeys["shift"]
    local ok, err = pcall(function()
      view.editor:set_cursor(1)
      keymap.modkeys["ctrl"], keymap.modkeys["shift"] = false, true
      local x, y = view:line_col_to_screen(1, 5)
      test.ok(view:on_mouse_pressed("left", x, y, 1))
      test.same(view.editor:cursor(), { cursor = 10, selection = 1 })
      test.equal(view.editor:copy_selection(), "中\nb😀")

      keymap.modkeys["ctrl"], keymap.modkeys["shift"] = true, false
      x, y = view:line_col_to_screen(2, 0)
      test.ok(view:on_mouse_pressed("left", x, y, 1))
      test.equal(view.editor:cursor_count(), 2)
      test.same(view.editor:cursor(2), { cursor = 11 })

      keymap.modkeys["ctrl"], keymap.modkeys["shift"] = false, false
      x, y = view:line_col_to_screen(1, 1)
      test.ok(view:on_mouse_pressed("left", x, y, 3))
      test.same(view.editor:cursor(), { cursor = 11, selection = 5 })
      test.equal(view.editor:copy_selection(), "b😀\n")
    end)
    keymap.modkeys["ctrl"], keymap.modkeys["shift"] = old_ctrl, old_shift
    if not ok then error(err) end
  end)

  test.it("page movement commands keep native editor cursor visible", function()
    local NativeEditorView = require "plugins.native_editor"
    local original_active_view = core.active_view
    local lines = {}
    for i = 1, 80 do lines[#lines + 1] = "line " .. i end
    local view = NativeEditorView(table.concat(lines, "\n"))
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, view:get_line_height() * 6
    view.scroll.x, view.scroll.y = 0, 0
    view.scroll.to.x, view.scroll.to.y = 0, 0

    local ok, err = pcall(function()
      core.active_view = view
      view.editor:set_cursor(0)
      test.ok(command.perform("native-editor:page-down"))
      local line = view:cursor_line_col()
      test.ok(line > 0)
      test.ok(view.scroll.to.y > 0)
      local minline, maxline = view:get_visible_line_range()
      test.ok(line + 1 >= minline and line + 1 <= maxline)
      test.ok(command.perform("native-editor:select-page-up"))
      test.ok(view:has_selection())
      local selected_line = view:cursor_line_col() + 1
      minline, maxline = view:get_visible_line_range()
      test.ok(selected_line >= minline and selected_line <= maxline)
    end)
    core.active_view = original_active_view
    if not ok then error(err) end
  end)

  test.it("supports DocView-like native editor mouse placement and selection", function()
    local NativeEditorView = require "plugins.native_editor"
    local keymap = require "core.keymap"
    local view = NativeEditorView("alpha beta\ngamma\n")
    view.position.x, view.position.y = 10, 20
    view.size.x, view.size.y = 500, 300
    view.scroll.x, view.scroll.y = 0, 0
    view.scroll.to.x, view.scroll.to.y = 0, 0

    local old_ctrl, old_shift = keymap.modkeys["ctrl"], keymap.modkeys["shift"]
    local ok, err = pcall(function()
      keymap.modkeys["ctrl"], keymap.modkeys["shift"] = false, false
      local x, y = view:line_col_to_screen(0, 6)
      test.same({ view:resolve_screen_position(x, y) }, { 1, 7 })
      test.same({ view:get_line_screen_position(1, 7) }, { x, y })
      test.equal(view:get_x_offset_col(1, view:get_col_x_offset(1, 7)), 7)
      local gutter_width, gutter_padding = view:get_gutter_width()
      test.ok(gutter_width > 0)
      test.ok(gutter_padding > 0)
      local hx, hy, hw, hh = view:get_line_highlight_rect(0, y)
      test.equal(hx, view.position.x)
      test.equal(hy, y)
      test.equal(hw, view.size.x)
      test.equal(hh, view:get_line_height())
      test.ok(view:on_mouse_pressed("left", x, y, 1))
      test.same(view.editor:cursor(), { cursor = 6 })

      local unicode = NativeEditorView("a©b")
      unicode.position.x, unicode.position.y = 10, 20
      unicode.size.x, unicode.size.y = 500, 300
      local before_w = unicode:get_col_x_offset(1, 2)
      local after_w = unicode:get_col_x_offset(1, 4)
      test.equal(unicode:get_x_offset_col(1, after_w), 4)
      test.not_equal(unicode:get_x_offset_col(1, (before_w + after_w) / 2 + 0.1), 3)

      x, y = view:line_col_to_screen(0, 7)
      test.ok(view:on_mouse_pressed("left", x, y, 2))
      test.equal(view.editor:copy_selection(), "beta")
      if system.get_primary_selection then
        test.equal(system.get_primary_selection(), "beta")
      end

      if system.set_primary_selection then
        system.set_primary_selection(" MID")
        x, y = view:line_col_to_screen(0, 10)
        test.ok(view:on_mouse_pressed("middle", x, y, 1))
        test.equal(view.buffer:text(), "alpha beta MID\ngamma\n")
      end

      x, y = view.position.x + 1, select(2, view:line_col_to_screen(1, 0))
      test.ok(view:on_mouse_pressed("left", x, y, 2))
      test.equal(view.editor:copy_selection(), "gamma\n")
      test.ok(view:line_has_cursor_or_selection(1))
      view:scroll_to_line(2, true, true)
      test.ok(view.scroll.y >= 0)
      view:scroll_to_make_visible(1, 1, true)
      test.equal(view.scroll.y, 0)
    end)
    keymap.modkeys["ctrl"], keymap.modkeys["shift"] = old_ctrl, old_shift
    if not ok then error(err) end
  end)

  test.it("records and restores native editor edit locations", function()
    require "plugins.native_editor"
    require "plugins.edit_location_history"
    local path_a = tmp_file("native-edit-location-a")
    local path_b = tmp_file("native-edit-location-b")
    local fp = assert(io.open(path_a, "wb"))
    fp:write("alpha")
    fp:close()
    fp = assert(io.open(path_b, "wb"))
    fp:write("beta")
    fp:close()

    local view_a = core.open_native_editor_file(path_a)
    local view_b = core.open_native_editor_file(path_b)
    local original_active_view = core.active_view
    local ok, err = pcall(function()
      core.active_view = view_a
      view_a.editor:set_cursor(2)
      core.record_native_edit_location(view_a)
      core.active_view = view_b
      view_b.editor:set_cursor(4)
      core.record_native_edit_location(view_b)

      test.ok(command.perform("user:navigate-last-edit-location"))
      test.ok(common.path_equals(core.view_file_path(core.active_view), path_a))
      test.same(core.active_view.editor:cursor(1), { cursor = 2, selection = 2 })
    end)
    core.active_view = original_active_view
    for _, view in ipairs({ view_a, view_b }) do
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then node:close_view(core.root_panel.root_node, view) end
    end
    os.remove(path_a)
    os.remove(path_b)
    if not ok then error(err) end
  end)

  test.it("releases native file Buffer registry entries when force-closing all views", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-close-all-release")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = core.open_native_editor_file(path)
    local original_buffer = view.buffer
    core.root_panel:close_all_views()
    local absolute = system.absolute_path(path) or path
    local key = common.path_compare_key(absolute)
    local buffer, reused = native_text.open_file_buffer(path, key)
    test.not_equal(buffer, original_buffer)
    test.not_ok(reused)
    native_text.release_file_buffer(key, buffer)
    os.remove(path)
  end)

  test.it("reloads clean native editor Buffers after external file changes", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-external-reload-clean")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = core.open_native_editor_file(path)
    test.equal(view.buffer:text(), "abc")
    fp = assert(io.open(path, "wb"))
    fp:write("abcdef")
    fp:close()
    view:check_external_file_change()
    test.equal(view.buffer:text(), "abcdef")
    test.same(view.editor:cursor(), { cursor = 0 })
    test.not_ok(view.external_reload_prompting)

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
  end)

  test.it("prompts instead of reloading dirty native editor Buffers after external changes", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-external-reload-dirty")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = core.open_native_editor_file(path)
    view.editor:set_cursor(3)
    view.editor:insert(" local")
    fp = assert(io.open(path, "wb"))
    fp:write("abcdef")
    fp:close()

    local original_nag_view = core.nag_view
    local captured
    local ok, err = pcall(function()
      core.nag_view = {
        show = function(_, title, message, options, callback)
          captured = { title = title, message = message, options = options, callback = callback }
        end
      }
      view:check_external_file_change()
      test.ok(view.external_reload_prompting)
      test.equal(view.buffer:text(), "abc local")
      test.equal(captured.title, "Native Buffer Changed")
      captured.callback({ text = "Ignore" })
      test.not_ok(view.external_reload_prompting)
      test.equal(view.buffer:text(), "abc local")
    end)
    core.nag_view = original_nag_view
    view:reload_from_disk()

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("can reload dirty native editor Buffers from external-change prompt", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-external-reload-dirty-accept")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = core.open_native_editor_file(path)
    view.editor:set_cursor(3)
    view.editor:insert(" local")
    fp = assert(io.open(path, "wb"))
    fp:write("abcdef")
    fp:close()

    local original_nag_view = core.nag_view
    local captured
    local ok, err = pcall(function()
      core.nag_view = {
        show = function(_, title, message, options, callback)
          captured = { title = title, message = message, options = options, callback = callback }
        end
      }
      view:check_external_file_change()
      test.equal(captured.title, "Native Buffer Changed")
      captured.callback({ text = "Reload From Disk" })
      test.equal(view.buffer:text(), "abcdef")
      test.same(view.editor:cursor(), { cursor = 0 })
      test.not_ok(view.external_reload_prompting)
      test.not_ok(core.view_is_dirty(view))
    end)
    core.nag_view = original_nag_view

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("can cancel saving dirty native editor Buffers over external changes", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-save-conflict-cancel")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = core.open_native_editor_file(path)
    local original_active_view = core.active_view
    local original_nag_view = core.nag_view
    local captured
    local ok, err = pcall(function()
      core.active_view = view
      view.editor:set_cursor(3)
      view.editor:insert(" local")
      fp = assert(io.open(path, "wb"))
      fp:write("abcdef external")
      fp:close()
      core.nag_view = {
        show = function(_, title, message, options, callback)
          captured = { title = title, message = message, options = options, callback = callback }
        end
      }
      test.ok(command.perform("native-editor:save"))
      test.ok(view.external_reload_prompting)
      test.equal(captured.title, "Native Buffer Save Conflict")
      captured.callback({ text = "Cancel" })
      test.not_ok(view.external_reload_prompting)
      test.ok(core.view_is_dirty(view))
      fp = assert(io.open(path, "rb"))
      test.equal(fp:read("*a"), "abcdef external")
      fp:close()
    end)
    core.nag_view = original_nag_view
    core.active_view = original_active_view
    view:reload_from_disk()

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("prompts before saving dirty native editor Buffers over external changes", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-save-conflict")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = core.open_native_editor_file(path)
    local original_active_view = core.active_view
    local original_nag_view = core.nag_view
    local captured
    local ok, err = pcall(function()
      core.active_view = view
      view.editor:set_cursor(3)
      view.editor:insert(" local")
      fp = assert(io.open(path, "wb"))
      fp:write("abcdef external")
      fp:close()
      core.nag_view = {
        show = function(_, title, message, options, callback)
          captured = { title = title, message = message, options = options, callback = callback }
        end
      }
      test.ok(command.perform("native-editor:save"))
      test.ok(view.external_reload_prompting)
      test.equal(captured.title, "Native Buffer Save Conflict")
      fp = assert(io.open(path, "rb"))
      test.equal(fp:read("*a"), "abcdef external")
      fp:close()
      captured.callback({ text = "Overwrite disk" })
      test.not_ok(view.external_reload_prompting)
      test.not_ok(core.view_is_dirty(view))
      fp = assert(io.open(path, "rb"))
      test.equal(fp:read("*a"), "abc local")
      fp:close()
    end)
    core.nag_view = original_nag_view
    core.active_view = original_active_view

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("routes core:new-doc to native scratch Buffers when default-open is enabled", function()
    require "plugins.native_editor"
    local native_config = config.plugins.native_editor
    local old_default_open = native_config.default_open
    local original_active_view = core.active_view
    local ok, err = pcall(function()
      native_config.default_open = true
      test.ok(command.perform("core:new-doc"))
      local view = core.active_view
      test.ok(core.is_native_editor_view(view))
      test.equal(view.buffer:path(), nil)
      test.equal(view.buffer:text(), "")
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then node:close_view(core.root_panel.root_node, view) end
    end)
    native_config.default_open = old_default_open
    core.active_view = original_active_view
    if not ok then error(err) end
  end)

  test.it("keeps native scratch Buffers dirty when save-as is cancelled", function()
    require "plugins.native_editor"
    local view = core.open_native_editor_scratch("α")
    local original_active_view = core.active_view
    local original_save_file_dialog = core.save_file_dialog
    local ok, err = pcall(function()
      core.active_view = view
      view.editor:set_cursor(view.buffer:len())
      view.editor:insert("β")
      core.save_file_dialog = function(_, callback)
        callback("cancel")
      end
      test.ok(command.perform("native-editor:save-as"))
      test.equal(view.buffer:path(), nil)
      test.ok(core.view_is_dirty(view))
      test.equal(view.buffer:text(), "αβ")
    end)
    core.save_file_dialog = original_save_file_dialog
    core.active_view = original_active_view
    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:remove_view(core.root_panel.root_node, view) end
    if not ok then error(err) end
  end)

  test.it("saves native scratch Buffers through save-as and registers file identity", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-save-as")
    os.remove(path)
    local view = core.open_native_editor_scratch("αβ")
    local original_active_view = core.active_view
    local original_save_file_dialog = core.save_file_dialog
    local ok, err = pcall(function()
      core.active_view = view
      view.editor:set_cursor(view.buffer:len())
      view.editor:insert("中")
      core.save_file_dialog = function(_, callback, options)
        test.equal(options.filename, nil)
        callback("accept", path)
      end
      test.ok(command.perform("native-editor:save-as"))
      test.ok(common.path_equals(view.buffer:path(), path))
      test.not_ok(core.view_is_dirty(view))
      local fp = assert(io.open(path, "rb"))
      test.equal(fp:read("*a"), "αβ中")
      fp:close()
      test.equal(core.open_native_editor_file(path), view)
    end)
    core.save_file_dialog = original_save_file_dialog
    core.active_view = original_active_view
    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("opens missing files as dirty native editor Buffers", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-new-file")
    os.remove(path)

    local view = core.open_native_editor_file(path)
    test.ok(core.is_native_editor_view(view))
    test.ok(common.path_equals(view.buffer:path(), path))
    test.ok(core.view_is_dirty(view))
    test.ok(command.perform("native-editor:save"))
    test.not_ok(core.view_is_dirty(view))
    test.ok(system.get_file_info(path))

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
  end)

  test.it("autosaves dirty native editor Buffers", function()
    require "plugins.native_editor"
    local autosave_fast = require "plugins.autosave_fast"
    test.skip_if(autosave_fast.enabled == false, "autosave_fast disabled")
    local path = tmp_file("native-editor-autosave")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = core.open_native_editor_file(path)
    view.editor:set_cursor(3)
    view.editor:insert("d")
    test.ok(core.view_is_dirty(view))
    test.ok(autosave_fast.save_all_dirty("native test") >= 1)
    test.not_ok(core.view_is_dirty(view))
    fp = assert(io.open(path, "rb"))
    test.equal(fp:read("*a"), "abcd")
    fp:close()

    local node = core.root_panel.root_node:get_node_for_view(view)
    if node then node:close_view(core.root_panel.root_node, view) end
    os.remove(path)
  end)

  test.it("registers DocView-like native editor status bar items", function()
    local NativeEditorView = require "plugins.native_editor"
    local status_bar = core.status_bar
    test.ok(status_bar:get_item("native:file"))
    test.ok(status_bar:get_item("native:position"))
    test.ok(status_bar:get_item("native:carets"))
    test.ok(status_bar:get_item("native:selected-chars"))
    test.ok(status_bar:get_item("native:selected-lines"))
    test.ok(status_bar:get_item("native:position-percent"))
    test.ok(status_bar:get_item("native:indentation"))
    test.ok(status_bar:get_item("native:lines"))
    test.ok(status_bar:get_item("native:encoding"))
    test.ok(status_bar:get_item("native:line-ending"))

    local function capture_status_draw(item)
      local texts = {}
      local old_draw_text = renderer.draw_text
      renderer.draw_text = function(_, text)
        texts[#texts + 1] = tostring(text)
        return 0
      end
      local ok, err = pcall(function() item.on_draw(0, 0, 20, nil, false) end)
      renderer.draw_text = old_draw_text
      if not ok then error(err) end
      return texts
    end

    local original_active_view = core.active_view
    local ok, err = pcall(function()
      local view = NativeEditorView("a中\nb😀\n")
      core.active_view = view
      view.editor:set_cursor(view.buffer:line_col_to_offset(0, 4))
      test.same(capture_status_draw(status_bar:get_item("native:position")), { "1", ":", "3" })

      view.editor:set_cursor(view.buffer:line_col_to_offset(0, 4), view.buffer:line_col_to_offset(0, 1))
      test.same(capture_status_draw(status_bar:get_item("native:selected-chars")), { "1", " char selected" })
      test.same(capture_status_draw(status_bar:get_item("native:selected-lines")), { "1", " line selected" })
    end)
    core.active_view = original_active_view
    if not ok then error(err) end
  end)

  test.it("routes deferred file drops through native editor default-open", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-file-drop")
    local fp = assert(io.open(path, "wb"))
    fp:write("dropped")
    fp:close()

    local native_config = config.plugins.native_editor
    local old_default_open = native_config.default_open
    local ok, err = pcall(function()
      native_config.default_open = true
      local node = core.root_panel:get_active_node_default()
      local x = (node.position and node.position.x or 0) + 1
      local y = (node.position and node.position.y or 0) + 1
      core.root_panel.defer_open_docs = { { path, x, y } }
      core.root_panel:process_defer_open_docs()
      local view = core.active_view
      test.ok(core.is_native_editor_view(view), "expected dropped file to open as native editor")
      test.ok(common.path_equals(core.view_file_path(view), path))
      node = core.root_panel.root_node:get_node_for_view(view)
      if node then node:close_view(core.root_panel.root_node, view) end
    end)
    native_config.default_open = old_default_open
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("routes core.open_file through native editor when default-open is enabled", function()
    require "plugins.native_editor"
    local path = tmp_file("native-editor-default-open")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local native_config = config.plugins.native_editor
    local old_default_open = native_config.default_open
    local ok, err = pcall(function()
      native_config.default_open = true
      local view = core.open_file(path)
      test.ok(core.is_native_editor_view(view))
      test.equal(view.buffer:text(), "abc")
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then node:close_view(core.root_panel.root_node, view) end
    end)
    native_config.default_open = old_default_open
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("confirms dirty native editor views through generic close helper", function()
    local NativeEditorView = require "plugins.native_editor"
    local view = NativeEditorView("abc")
    view.editor:insert("d")
    local original_nag_view = core.nag_view
    local closed = false
    local captured
    local ok, err = pcall(function()
      core.nag_view = {
        show = function(_, title, text, options, callback)
          captured = { title = title, text = text, options = options, callback = callback }
        end
      }
      core.confirm_close_views({ view }, function() closed = true end)
      test.equal(closed, false)
      test.equal(captured.title, "Unsaved Changes")
      test.contains(captured.text, "Close anyway?")
      captured.callback({ text = "No" })
      test.equal(closed, false)
      captured.callback({ text = "Yes" })
      test.equal(closed, true)
    end)
    core.nag_view = original_nag_view
    if not ok then error(err) end
  end)

  test.it("includes dirty native editor views in close-all-others routing", function()
    require "core.file_context"
    local NativeEditorView = require "plugins.native_editor"
    local keep = NativeEditorView("keep")
    local dirty = NativeEditorView("dirty")
    dirty.editor:insert("!")
    local node = core.root_panel:get_active_node_default()
    node:add_view(dirty)
    node:add_view(keep)
    node:set_active_view(keep)

    local original_nag_view = core.nag_view
    local captured
    local ok, err = pcall(function()
      core.nag_view = {
        show = function(_, title, text, options, callback)
          captured = { title = title, text = text, options = options, callback = callback }
        end
      }
      test.ok(command.perform("root:close-all-others"))
      test.equal(captured.title, "Unsaved Changes")
      test.ok(node:get_view_idx(dirty))
      captured.callback({ text = "Yes" })
      test.not_ok(node:get_view_idx(dirty))
      test.ok(node:get_view_idx(keep))
    end)
    core.nag_view = original_nag_view
    if node:get_view_idx(keep) then node:close_view(core.root_panel.root_node, keep) end
    if node:get_view_idx(dirty) then node:remove_view(core.root_panel.root_node, dirty) end
    if not ok then error(err) end
  end)

  test.it("exposes native editor file paths through generic core view helpers", function()
    local NativeEditorView = require "plugins.native_editor"
    local path = tmp_file("native-editor-core-path")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = NativeEditorView(nil, path)
    local original_active_view = core.active_view
    local ok, err = pcall(function()
      core.active_view = view
      test.ok(common.path_equals(core.view_file_path(view), path))
      test.equal(core.view_is_dirty(view), false)
      view.editor:insert("d")
      test.equal(core.view_is_dirty(view), true)
      test.ok(core.set_view_selection(view, 1, 3))
      test.same({ core.view_cursor_position(view) }, { 1, 3 })

      local unicode = NativeEditorView("αβ\n中😀")
      test.ok(core.set_view_selection(unicode, 1, 1, 2, 8))
      test.same({ core.view_cursor_position(unicode) }, { 2, 8 })
      test.equal(unicode.editor:copy_selection(), "αβ\n中😀")
      local title = core.get_view_title(view)
      test.contains(title, common.basename(path))
      test.contains(title, "*")
      local project = core.current_project()
      test.ok(project and project.path)
    end)
    core.active_view = original_active_view
    local absolute = system.absolute_path(path) or path
    native_text.release_file_buffer(common.path_compare_key(absolute), view.buffer)
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("restores file-backed native editor views through registered Buffer identity", function()
    local NativeEditorView = require "plugins.native_editor"
    local path = tmp_file("native-text-view-state-file")
    local fp = assert(io.open(path, "wb"))
    fp:write("abc")
    fp:close()

    local view = NativeEditorView(nil, path)
    local state = view:get_state()
    local restored = NativeEditorView.from_state(state)
    test.equal(restored.buffer, view.buffer)

    local editor = restored.buffer:new_editor()
    test.ok(editor:set_cursor(3))
    test.ok(editor:insert("def"))
    test.equal(view.buffer:text(), "abcdef")

    local absolute = system.absolute_path(path) or path
    native_text.release_file_buffer(common.path_compare_key(absolute), view.buffer)
    os.remove(path)
  end)

  test.it("uses Buffer line-ending mode for native newline insertion", function()
    local buffer = native_text.new_buffer("ab")
    local editor = buffer:new_editor()

    test.ok(buffer:set_line_ending_mode("crlf"))
    test.equal(buffer:line_ending_mode(), "crlf")
    test.ok(editor:set_cursor(1))
    test.ok(editor:newline())
    test.equal(buffer:text(), "a\r\nb")
  end)
end)
