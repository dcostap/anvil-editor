local native_text = require "native_text"
local test = require "core.test"

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"

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

      local valid = command.get_all_valid()
      test.contains(valid, "native-editor:toggle-line-ending")
      for _, name in ipairs(valid) do
        test.not_equal(name, "native-text-sandbox:toggle-line-ending")
      end
    end)
    core.active_view = original_active_view
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
      test.ok(view:on_mouse_pressed("left", x, y, 1))
      test.same(view.editor:cursor(), { cursor = 6 })

      x, y = view:line_col_to_screen(0, 7)
      test.ok(view:on_mouse_pressed("left", x, y, 2))
      test.equal(view.editor:copy_selection(), "beta")

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
