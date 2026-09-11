local core = require "core"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

test.describe("POI previews", function()
  test.it("renders a linked Markdown heading and body without opening the note", function()
    local preview = require "core.poi_preview"
    local worker_pool = require "core.worker_pool"
    local source = require("core.editor")(Buffer("preview-source.md", nil, true))
    source.size.x, source.size.y = 800, 600
    source.buffer:insert(1, 1, "reference\n")
    require("core.markdown.live_render").attach(source)
    local target = Buffer("linked-preview.md", nil, true)
    target:insert(1, 1, "Before the destination\n\n### Sales series\n\n**Unsaved description**\n- First item\n")
    target:set_selection(1, 2)
    local focused, buffer_count = core.active_view, #core.buffers
    local ok, err = pcall(function()
      test.ok(preview.location(source, { line = 1, target_buffer = target, target_line = 3 }))
      local drawn = {}
      local function draw_preview()
        drawn = {}
        local old_draw_text = renderer.draw_text
        local old_draw_rect, old_set_clip_rect = renderer.draw_rect, renderer.set_clip_rect
        renderer.draw_rect = function() end
        renderer.set_clip_rect = function() end
        renderer.draw_text = function(font, text, x, y, color, opts)
          drawn[#drawn + 1] = text
          return x + font:get_width(text, opts)
        end
        local success, failure = pcall(function()
          for entry in source:iter_visible_visual_rows() do
            if entry.type == "provider" then
              entry.provider_row.draw(source, entry.provider_row, 0, entry.y, 800, entry.height)
            end
          end
        end)
        renderer.draw_text = old_draw_text
        renderer.draw_rect, renderer.set_clip_rect = old_draw_rect, old_set_clip_rect
        if not success then error(failure, 0) end
      end
      local deadline = system.get_time() + 5
      repeat
        local pool = worker_pool.current_system()
        if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
        draw_preview()
        if table.concat(drawn, "\n"):find("\nSales series\n", 1, true) then break end
        system.sleep(0.001)
      until system.get_time() >= deadline
      local text = table.concat(drawn, "\n")
      test.contains(text, "\nSales series\n")
      test.contains(text, "Unsaved description")
      test.equal(text:find("###", 1, true), nil)
      test.equal(text:find("**", 1, true), nil)
      test.equal(text:find("Before the destination", 1, true), nil)
      test.equal(target:get_selection(), 1)
      test.equal(select(2, target:get_selection()), 2)
      test.equal(source.buffer:get_selection(), 1)
      test.equal(core.active_view, focused)
      test.equal(#core.buffers, buffer_count)
      test.ok(preview.dismiss(source))
      test.not_equal(source:get_visual_row_entry(2).type, "provider")
    end)
    preview.dismiss(source)
    source:on_close()
    core.buffer_registry:remove(source.buffer, true)
    target:on_close()
    if not ok then error(err, 0) end
  end)

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
  test.it("highlights changed words on both sides until the preview closes", function()
    local Editor = require "core.editor"
    local gitdiff = require "plugins.gitdiff_highlight"
    local poi = require "core.poi"
    local preview = require "core.poi_preview"
    local editor = Editor(Buffer())
    editor.size.x, editor.size.y = 800, 600
    editor.buffer:insert(1, 1, "unchanged\n\tvalue = new_name + same\n")
    editor.buffer:set_selection(1, 1)
    gitdiff._set_state_for_tests(editor.buffer, {
      is_in_repo = true, base_lines = { "unchanged\n", "\tvalue = old_name + same\n" },
      ranges = {{ type = "modification", current_start = 2, current_end = 3, base_start = 2, base_end = 3 }},
      line_index = {},
    })
    test.ok(poi.navigate(editor, 1))
    local row = editor:get_visual_row_entry(3).provider_row
    test.same(row.inline_ranges, {{ col1 = 10, col2 = 18 }})
    local function current_ranges()
      local result = {}
      for _, entry in ipairs(editor:decoration_provider_entries()) do
        if entry.provider.inline_ranges then
          for _, range in ipairs(entry.provider:inline_ranges(editor, 2) or {}) do
            result[#result + 1] = { col1 = range.col1, col2 = range.col2 }
          end
        end
      end
      return result
    end
    test.same(current_ranges(), {{ col1 = 10, col2 = 18 }})
    preview.dismiss(editor)
    test.same(current_ranges(), {})
    editor.buffer:on_close()
  end)

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
