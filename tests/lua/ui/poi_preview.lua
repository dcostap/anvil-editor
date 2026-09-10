local core = require "core"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

test.describe("POI previews", function()
  test.it("shows an unsaved file excerpt without changing either caret or focus", function()
    local preview = require "core.poi_preview"
    local source = TextView(Buffer())
    source.buffer:insert(1, 1, "reference\n")
    source.buffer:set_selection(1, 1)
    local target = Buffer()
    target:insert(1, 1, "one\nunsaved two\nthree\n")
    target:set_selection(3, 2)
    local focused = core.active_view
    test.ok(preview.location(source, { line = 1, target_buffer = target, target_line = 2 }))
    local content = preview.for_view(source)
    test.equal(content.line, 1)
    test.contains(table.concat(content.lines, "\n"), "unsaved two")
    test.equal(target:get_selection(), 3)
    test.equal(source.buffer:get_selection(), 1)
    test.equal(core.active_view, focused)
    test.equal(source:get_visual_row_entry(2).type, "provider")
    test.ok(preview.dismiss(source))
    test.equal(preview.for_view(source), nil)
    test.not_equal(source:get_visual_row_entry(2).type, "provider")
    source.buffer:on_close()
    target:on_close()
  end)
end)

test.describe("Git change POIs", function()
  test.it("previews a local Git change without replacing the remote source", function()
    local Editor = require "core.editor"
    local gitdiff = require "plugins.gitdiff_highlight"
    local poi = require "core.poi"
    local preview = require "core.poi_preview"
    local editor = Editor(Buffer())
    editor.size.x, editor.size.y = 800, 600
    editor.buffer:insert(1, 1, "unchanged\nnew\n")
    editor.buffer:set_selection(1, 1)
    gitdiff._set_state_for_tests(editor.buffer, {
      is_in_repo = true, base_lines = { "unchanged\n", "old\n" },
      ranges = {{ type = "modification", current_start = 2, current_end = 3, base_start = 2, base_end = 3 }},
      line_index = {},
    })
    local remote = poi.get_remote_source()
    test.ok(poi.navigate(editor, 1))
    local content = test.not_nil(preview.for_view(editor))
    test.same(content.lines, { "old\n" })
    local entry = editor:get_visual_row_entry(3)
    test.equal(entry.type, "provider")
    test.equal(poi.get_remote_source(), remote)
    test.ok(poi.activate(editor))
    preview.dismiss(editor)
    editor.buffer:on_close()
  end)

  test.it("navigates pure additions without showing a preview", function()
    local Editor = require "core.editor"
    local gitdiff = require "plugins.gitdiff_highlight"
    local poi = require "core.poi"
    local preview = require "core.poi_preview"
    local editor = Editor(Buffer())
    editor.buffer:insert(1, 1, "unchanged\nadded\n")
    gitdiff._set_state_for_tests(editor.buffer, {
      is_in_repo = true, base_lines = { "unchanged\n" },
      ranges = {{ type = "addition", current_start = 2, current_end = 3, base_start = 2, base_end = 2 }},
      line_index = {},
    })
    editor.buffer:set_selection(1, 1)
    test.ok(poi.navigate(editor, 1))
    test.equal(editor.buffer:get_selection(), 2)
    test.equal(preview.for_view(editor), nil)
    preview.dismiss(editor)
    editor.buffer:on_close()
  end)
end)
