local core = require "core"
local card = require "core.card"
local config = require "core.config"
local style = require "core.style"
local test = require "core.test"
local autocomplete = require "plugins.autocomplete"
local Editor = require "core.editor"
local panes = require "core.panes"

-- Seam: real input events through core.on_event over a drawn autocomplete popup. The cards that the popup draws
-- give the points to use, so the test does not repeat the popup's layout.

local window

-- Draws the popup and returns its cards: the list, then the description of the selected suggestion.
local function draw(view)
  local ww, wh = system.get_window_size(core.window)
  window = window or renwindow.create("autocomplete-pointer", ww, wh)
  local cards = {}
  local draw_card = card.draw
  card.draw = function(x, y, w, h, ...)
    cards[#cards + 1] = { x = x, y = y, w = w, h = h }
    return draw_card(x, y, w, h, ...)
  end
  local old_clip = core.clip_rect_stack[1]
  renderer.begin_frame(window)
  core.clip_rect_stack[1] = { 0, 0, ww, wh }
  renderer.set_clip_rect(0, 0, ww, wh)
  local ok, err = pcall(autocomplete.draw, view)
  renderer.end_frame()
  core.clip_rect_stack[1] = old_clip
  card.draw = draw_card
  if not ok then error(err, 0) end
  return cards
end

-- The middle of a list row. Rows have the Editor's line height and start half a padding below the card's top.
local function row_point(view, list, row)
  local row_h = view:get_font():get_height() + style.padding.y
  return list.x + list.w / 2, list.y + style.padding.y / 2 + (row - 0.5) * row_h
end

local function move(x, y) core.on_event("mousemoved", x, y, 0, 0) end
local function click(x, y)
  core.on_event("mousepressed", "left", x, y, 1)
  core.on_event("mousereleased", "left", x, y)
end

local function open_popup(context, count)
  local buffer = core.open_buffer()
  context.buffer = buffer
  buffer:text_input("test")
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  context.view = view
  core.root_panel:update()
  local ww, wh = system.get_window_size(core.window)
  view.position.x, view.position.y = ww / 4, wh / 10
  view.size.x, view.size.y = ww / 2, wh * 0.8
  local items = {}
  for i = 1, count do
    local name = string.format("test%02d", i)
    items[i] = { text = name, info = "field", desc = name .. ": the description of this field" }
  end
  autocomplete.add_provider("test-popup-pointer", function(active_view)
    if active_view ~= view then return nil end
    local line, col = buffer:get_selection()
    return { query = "test", line = line, query_col = col - 4, items = items }
  end)
  autocomplete.trigger()
  test.ok(autocomplete.is_open())
  return view, buffer
end

test.describe("autocomplete popup pointer input", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.centered = config.plugins.centered_editor.enabled
    config.plugins.centered_editor.enabled = false
  end)

  test.after_each(function(context)
    autocomplete.close()
    autocomplete.remove_provider("test-popup-pointer")
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

  test.it("selects the suggestion under the pointer and keeps the caret", function(context)
    local view, buffer = open_popup(context, 5)
    local list = draw(view)[1]
    move(row_point(view, list, 3))
    test.equal(autocomplete.get_selected_suggestion().text, "test03")
    test.same({ buffer:get_selection() }, { 1, 5, 1, 5 })
    test.ok(autocomplete.is_open())
  end)

  test.it("inserts a clicked suggestion at the caret", function(context)
    local view, buffer = open_popup(context, 5)
    local list = draw(view)[1]
    click(row_point(view, list, 2))
    test.equal(buffer.lines[1], "test02\n")
    test.same({ buffer:get_selection() }, { 1, 7, 1, 7 })
    test.not_ok(autocomplete.is_open())
    test.equal(core.active_view, view)
  end)

  test.it("scrolls a long list under the pointer without scrolling the Editor", function(context)
    local view = open_popup(context, 30)
    local list = draw(view)[1]
    local x, y = row_point(view, list, 1)
    move(x, y)
    test.equal(autocomplete.get_selected_suggestion().text, "test01")
    local scroll = view.scroll.to.y
    for _ = 1, 3 do core.on_event("mousewheel", -1, 0) end
    draw(view)
    move(x, y)
    local first = tonumber(autocomplete.get_selected_suggestion().text:match("%d+"))
    test.ok(first > 1, "the wheel did not scroll the list")
    test.equal(view.scroll.to.y, scroll)
    test.ok(autocomplete.is_open())
  end)

  test.it("keeps the popup and the caret for a press on the description", function(context)
    local view, buffer = open_popup(context, 5)
    local cards = draw(view)
    local description = test.not_nil(cards[2], "the selected suggestion has no description card")
    click(description.x + description.w / 2, description.y + description.h / 2)
    test.ok(autocomplete.is_open())
    test.same({ buffer:get_selection() }, { 1, 5, 1, 5 })
  end)

  test.it("closes for a press outside the popup, which still reaches the Editor", function(context)
    local view, buffer = open_popup(context, 5)
    draw(view)
    local x, y = view:get_line_screen_position(1, 2)
    click(x + 1, y + view:get_line_height() / 2)
    core.root_panel:update()
    test.not_ok(autocomplete.is_open())
    test.same({ buffer:get_selection() }, { 1, 2, 1, 2 })
  end)

  -- A click on the Project Sidebar takes the keyboard from the Project.
  test.it("closes when the Project loses the keyboard", function(context)
    local view = open_popup(context, 5)
    draw(view)
    core.on_event("focuslost")
    core.root_panel:update()
    test.not_ok(autocomplete.is_open())
  end)
end)
