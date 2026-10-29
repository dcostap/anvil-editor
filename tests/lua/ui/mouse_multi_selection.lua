local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

require "core.commands.text"

local function point(view, line, col)
  local x, y = view:get_line_screen_position(line, col)
  return x + 1, y + view:get_line_height() / 2
end

local function press(view, name, line, col, clicks)
  local x, y = point(view, line, col)
  test.ok(command.perform(name, x, y, clicks or 1))
end

local function drag(view, line, col)
  local x, y = point(view, line, col)
  view:on_mouse_moved(x, y, 0, 0)
end

local function release(view)
  view:on_mouse_released("left", 0, 0)
end

local function selections(view)
  local state = view:get_selection_state()
  return state.selections, state.last_selection
end

test.describe("Mouse multi-selection", function()
  test.before_each(function(context)
    context.previous = core.active_view
    context.ctrl = keymap.modkeys.ctrl
    context.buffer = Buffer()
    context.buffer:insert(1, 1, "alpha beta\ngamma delta\nepsilon")
    context.view = TextView(context.buffer)
    context.view.position.x, context.view.position.y = 0, 0
    context.view.size.x, context.view.size.y = 600, 300
    core.set_active_view(context.view)
  end)

  test.after_each(function(context)
    keymap.modkeys.ctrl = context.ctrl
    if context.previous then core.set_active_view(context.previous) end
    context.buffer:on_close()
  end)

  test.it("drags the added selection and keeps the other selections", function(context)
    local view, buffer = context.view, context.buffer
    buffer:set_selection(1, 1, 1, 1)
    keymap.modkeys.ctrl = true
    press(view, "core:split_cursor", 2, 1)
    drag(view, 2, 6)
    release(view)
    local list, last = selections(view)
    test.same(list, { 1, 1, 1, 1, 2, 6, 2, 1 })
    test.equal(last, 2)
  end)

  test.it("keeps adding when Ctrl is released during the drag", function(context)
    local view, buffer = context.view, context.buffer
    buffer:set_selection(1, 1, 1, 1)
    keymap.modkeys.ctrl = true
    press(view, "core:split_cursor", 2, 7)
    keymap.modkeys.ctrl = false
    drag(view, 2, 3)
    release(view)
    test.same((selections(view)), { 1, 1, 1, 1, 2, 3, 2, 7 })
  end)

  test.it("merges selections that the drag covers and restores them when it leaves", function(context)
    local view, buffer = context.view, context.buffer
    buffer:set_selection(1, 3, 1, 3)
    press(view, "core:split_cursor", 1, 1)
    drag(view, 1, 8)
    test.same((selections(view)), { 1, 8, 1, 1 })
    drag(view, 1, 2)
    release(view)
    test.same((selections(view)), { 1, 2, 1, 1, 1, 3, 1, 3 })
  end)

  test.it("adds a word on double-click and drags by words", function(context)
    local view, buffer = context.view, context.buffer
    buffer:set_selection(3, 1, 3, 1)
    press(view, "core:split_cursor", 1, 2, 1)
    press(view, "core:split_cursor", 1, 2, 2)
    test.same((selections(view)), { 1, 6, 1, 1, 3, 1, 3, 1 })
    drag(view, 1, 8)
    release(view)
    test.same((selections(view)), { 1, 11, 1, 1, 3, 1, 3, 1 })
  end)

  test.it("removes a clicked caret and keeps it removed through pointer jitter", function(context)
    local view, buffer = context.view, context.buffer
    buffer:set_selection_list({ 1, 1, 1, 1, 2, 3, 2, 3 }, 2)
    press(view, "core:split_cursor", 2, 3)
    drag(view, 2, 3)
    release(view)
    test.same((selections(view)), { 1, 1, 1, 1 })
  end)

  test.it("makes a column selection with the column command", function(context)
    local view, buffer = context.view, context.buffer
    buffer:set_selection(3, 1, 3, 1)
    press(view, "core:set_cursor_column", 1, 2)
    drag(view, 2, 4)
    release(view)
    test.same((selections(view)), { 1, 4, 1, 2, 2, 4, 2, 2 })
  end)
end)
