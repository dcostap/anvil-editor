local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local autocomplete = require "plugins.autocomplete"
local Editor = require "core.editor"
local panes = require "core.panes"

local function open_popup(context, count)
  local buffer = core.open_buffer()
  context.buffer = buffer
  buffer:text_input("test")
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  context.view = view
  core.root_panel:update()
  local ww, wh = system.get_window_size(core.window)
  view.position.x, view.position.y = ww / 3, wh / 10
  view.size.x, view.size.y = ww / 2, wh * 0.8
  local items = {}
  for i = 1, count do
    local name = string.format("test%02d", i)
    local preview = "data class " .. name .. "(" .. string.rep("val property: VeryLongTypeName, ", 100) .. ")"
    items[i] = {
      text = name,
      preview_text = preview,
      preview_name_span = { 12, 11 + #name },
    }
  end
  autocomplete.add_provider("test-popup-layout", function(active_view)
    if active_view ~= view then return nil end
    local line, col = buffer:get_selection()
    return { query = "test", line = line, query_col = col - 4, items = items }
  end)
  autocomplete.trigger()
  test.ok(autocomplete.is_open())
  return view, buffer, items
end

local function assert_inside_editor(view, x, y, w, h)
  test.ok(x >= view.position.x, "the popup must not cover the left neighboring Pane or Sidebar")
  test.ok(y >= view.position.y, "the popup must not cover the Editor's header")
  test.ok(x + w <= view.position.x + view.size.x, "the popup must stay inside the Editor's right edge")
  test.ok(y + h <= view.position.y + view.size.y, "the popup must stay inside the Editor's bottom edge")
end

test.describe("autocomplete popup layout", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.centered = config.plugins.centered_editor.enabled
    config.plugins.centered_editor.enabled = false
  end)

  test.after_each(function(context)
    autocomplete.close()
    autocomplete.remove_provider("test-popup-layout")
    config.plugins.centered_editor.enabled = context.centered
    panes.reset_for_tests()
    if context.buffer then
      context.buffer:clean()
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == context.buffer then table.remove(core.buffers, i) end
      end
      context.buffer:on_close()
    end
  end)

  test.it("keeps long declaration previews inside their Editor", function(context)
    local view = open_popup(context, 20)
    local x, y, w, h = autocomplete._test.get_suggestions_rect(view)
    test.ok(w > 0 and h > 0)
    assert_inside_editor(view, x, y, w, h)
  end)

  test.it("limits visible rows without removing remaining suggestions", function(context)
    local count = 12
    local view = open_popup(context, count)
    local _, _, _, _, _, visible = autocomplete._test.get_suggestions_rect(view)
    test.ok(visible > 0 and visible < count, "the popup must show a page, not the entire suggestion list")
    local seen = {}
    for _ = 1, count do
      local name = test.not_nil(autocomplete.get_selected_suggestion()).text
      test.not_ok(seen[name], "navigation must reach each suggestion before wrapping")
      seen[name] = true
      test.ok(command.perform("autocomplete:next"))
    end
    test.equal(autocomplete.get_selected_suggestion().text, "test01")
    test.ok(command.perform("autocomplete:previous"))
    test.equal(autocomplete.get_selected_suggestion().text, "test12")
  end)

  test.it("does not widen the popup for longer declaration signatures", function(context)
    local view, _, items = open_popup(context, 1)
    local long_preview = items[1].preview_text
    items[1].preview_text = "data class test01()"
    autocomplete.trigger()
    local _, _, short_width = autocomplete._test.get_suggestions_rect(view)
    items[1].preview_text = long_preview
    autocomplete.trigger()
    local _, _, long_width = autocomplete._test.get_suggestions_rect(view)
    test.equal(long_width, short_width, "signature length must not determine popup width")
  end)

  test.it("does not widen the popup for longer information beside a symbol", function(context)
    local view, _, items = open_popup(context, 1)
    items[1].preview_text = nil
    items[1].info = "method"
    autocomplete.trigger()
    local _, _, short_width = autocomplete._test.get_suggestions_rect(view)
    items[1].info = string.rep("argument: VeryLongTypeName, ", 100)
    autocomplete.trigger()
    local _, _, long_width = autocomplete._test.get_suggestions_rect(view)
    test.equal(long_width, short_width, "information text must use the width available beside the symbol")
  end)

  test.it("keeps the popup below the caret when a full page fits", function(context)
    local view = open_popup(context, 20)
    local row_y, row_height = view:get_caret_highlight_geometry(1, 5)
    local _, popup_y = autocomplete._test.get_suggestions_rect(view)
    test.ok(popup_y >= row_y + row_height, "the popup must not cover the caret row")
  end)

  test.it("moves the popup above the caret near the Editor's bottom edge", function(context)
    local view, buffer = open_popup(context, 20)
    local lines = math.max(1, math.floor(view.size.y / view:get_line_height()) - 1)
    view:with_selection_state(function()
      buffer:insert(1, 1, string.rep("\n", lines - 1))
      buffer:set_selection(lines, 5)
      autocomplete.trigger()
    end)
    local row_y = view:get_caret_highlight_geometry(lines, 5)
    local x, y, w, h = autocomplete._test.get_suggestions_rect(view)
    test.ok(h > 0)
    test.ok(y + h <= row_y, "the popup must fit above the caret row")
    assert_inside_editor(view, x, y, w, h)
  end)

  test.it("shrinks to fit an Editor narrower than the popup's preferred size", function(context)
    local view = open_popup(context, 1)
    view.size.x = style.padding.x * 4
    local x, y, w, h = autocomplete._test.get_suggestions_rect(view)
    test.ok(w > 0 and h > 0)
    assert_inside_editor(view, x, y, w, h)
  end)

  test.it("hides the popup when no complete suggestion row fits", function(context)
    local view = open_popup(context, 20)
    view.size.y = view:get_font():get_height() / 2
    local _, _, _, height, _, visible = autocomplete._test.get_suggestions_rect(view)
    test.equal(visible, 0, "a tiny Editor must not draw suggestions outside its bounds")
    test.equal(height, 0)
  end)
end)
