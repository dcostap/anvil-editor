local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local MessageBox = require "widget.messagebox"
local LineWrapping = require "core.linewrapping"
local Editor = require "core.editor"
local panes = require "core.panes"

require "plugins.intellij_find"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local buffer = track(context, "buffers", core.open_buffer())
  if text and text ~= "" then buffer:text_input(text) end
  local view = track(context, "views", panes.place(function() return Editor(buffer) end,
    { placement = "new", focus = true }))
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 360, 180
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  return view, buffer
end

local function selection_range(view)
  return view:with_selection_state(function()
    local line1, col1, line2, col2 = view.buffer:get_selection(true)
    return { line1, col1, line2, col2 }
  end)
end

local function assert_selection(view, line1, col1, line2, col2)
  test.same({ line1, col1, line2, col2 }, selection_range(view))
end

local function active_find_input_for(owner_view)
  local view = core.active_view
  test.ok(view and view.local_find_input, "expected a local find input to be focused")
  test.equal(view.local_find_state and view.local_find_state.owner_view, owner_view)
  return view
end

local function type_into_active_view(text)
  core.root_panel:on_text_input(text)
end

test.describe("TextView Prompt Bar find", function()
  test.after_each(function(context)
    if core.active_view and core.active_view.local_find_input then
      command.perform("editor:find_close")
    end

    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers or {}) do
      if buffer:is_dirty() then buffer:clean() end
      remove_buffer(buffer)
    end
  end)

  test.it("refines incremental input from the search origin instead of preserving a global match ordinal", function(context)
    local prefix = {}
    for i = 1, 12 do prefix[#prefix + 1] = "i before\n" end
    local origin_line = #prefix + 1
    local view, buffer = open_editor(
      context,
      table.concat(prefix) .. "cursor input middle\n" .. "cursor input last\n"
    )
    view:with_selection_state(function()
      buffer:set_selection(origin_line, 1, origin_line, 1)
    end)

    test.ok(command.perform("editor:find"))
    core.root_panel:on_text_input("i")
    core.root_panel:on_text_input("n")

    assert_selection(view, origin_line, 8, origin_line, 10)
  end)

  test.it("opens on the currently selected match when the caret is at the selection end", function(context)
    local view, buffer = open_editor(context, "input first\ninput second\n")
    view:with_selection_state(function() buffer:set_selection(1, 6, 1, 1) end)

    test.ok(command.perform("editor:find"))

    assert_selection(view, 1, 1, 1, 6)
  end)

  test.it("returns Local Focus Cycle commands from find input to its Text View", function(context)
    local view = open_editor(context, "alpha beta alpha\n")
    local sibling_buffer = track(context, "buffers", core.open_buffer())
    panes.split(panes.pane_for_view(view), "right", {
      factory = function() return track(context, "views", Editor(sibling_buffer)) end,
      focus = false,
    })

    test.ok(command.perform("editor:replace"))
    active_find_input_for(view)
    test.ok(command.perform("pane:focus_local_next"))
    test.equal(core.active_view, view)

    test.ok(command.perform("editor:replace"))
    active_find_input_for(view)
    test.ok(command.perform("pane:focus_local_previous"))
    test.equal(core.active_view, view)
  end)

  test.it("find navigation treats matches near the bottom edge as not already visible", function(context)
    local lines = {}
    for i = 1, 30 do lines[i] = "line " .. i end
    lines[1] = "NEEDLE first"
    lines[12] = "NEEDLE bottom edge"
    local view, buffer = open_editor(context, table.concat(lines, "\n"))
    view:with_selection_state(function() buffer:set_selection(1, 1, 1, 1) end)

    test.ok(command.perform("editor:find"))
    type_into_active_view("NEEDLE")
    assert_selection(view, 1, 1, 1, 7)

    local lh = view:get_line_height()
    local target_line = 12
    local start_scroll = math.max(0, (target_line - 1) * lh + style.padding.y - view.size.y)
    view.scroll.y, view.scroll.to.y = start_scroll, start_scroll
    local _, maxline = view:get_visible_line_range()
    test.equal(maxline, target_line)

    test.ok(command.perform("editor:repeat_find"))

    assert_selection(view, target_line, 1, target_line, 7)
    test.ok(view.scroll.to.y > start_scroll, "expected bottom-edge match navigation to scroll with context")
  end)

  test.it("replace all batches local find matches into one text change", function(context)
    local view, buffer = open_editor(context, "alpha beta alpha\nalpha\n")
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("editor:replace"))
    active_find_input_for(view)
    type_into_active_view("alpha")
    test.ok(command.perform("editor:find_toggle_replace_field"))
    active_find_input_for(view)
    type_into_active_view("omega")

    local warning = MessageBox.warning
    MessageBox.warning = function(title, message, callback)
      callback(nil, 1)
    end
    test.ok(command.perform("editor:find_replace_all_confirm"))
    MessageBox.warning = warning

    test.equal(table.concat(buffer.lines), "omega beta omega\nomega\n\n")
    test.equal(changes, 1)
  end)

  test.it("does not draw competing highlights over local find matches", function(context)
    local view = open_editor(context, "pl pl\n")
    test.ok(command.perform("editor:find"))
    type_into_active_view("pl")
    view:prepare_line_body_draw_cache(1, 1)

    local selection_highlights = 0
    local current_line_highlights = 0
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.selectionhighlight then
        selection_highlights = selection_highlights + 1
      elseif color == style.line_highlight then
        current_line_highlights = current_line_highlights + 1
      end
    end
    renderer.draw_text = function(font, text, x)
      return x + font:get_width(text)
    end
    renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w)
      return x + w
    end
    local ok, err = pcall(view.draw_line_body, view, 1, 0, 0)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    if not ok then error(err, 0) end

    test.equal(selection_highlights, 0)
    test.equal(current_line_highlights, 0)
  end)

  test.it("splits find highlights across Wrapped Visual Rows", function(context)
    local view = open_editor(context, "xxxxxxNEEDLE")
    local wrapping = config.plugins.linewrapping
    local previous = {
      mode = wrapping.mode,
      width_override = wrapping.width_override,
      indent = wrapping.indent,
      wrapping_indent = wrapping.wrapping_indent,
      require_tokenization = wrapping.require_tokenization,
    }
    wrapping.mode = "letter"
    wrapping.width_override = view:get_font():get_width("xxxxxxxx")
    wrapping.indent = false
    wrapping.wrapping_indent = 0
    wrapping.require_tokenization = false
    view:set_wrapping_enabled(true)
    LineWrapping.update_textview_breaks(view)

    local rects = {}
    local old_draw_rect = renderer.draw_rect
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.search_selection_secondary then
        rects[#rects + 1] = { x = x, y = y, w = w, h = h }
      end
    end
    local ok, err = pcall(view.draw_search_match_background, view, 1, 7, 13, false)
    renderer.draw_rect = old_draw_rect
    wrapping.mode = previous.mode
    wrapping.width_override = previous.width_override
    wrapping.indent = previous.indent
    wrapping.wrapping_indent = previous.wrapping_indent
    wrapping.require_tokenization = previous.require_tokenization
    if not ok then error(err, 0) end

    test.equal(#rects, 2)
    test.ok(rects[2].y > rects[1].y)
  end)
end)
