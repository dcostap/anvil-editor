local core = require "core"
local test = require "core.test"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local panes = require "core.panes"
require "plugins.intellij_actions"

test.describe("Add Next Occurrence streaming search", function()
  test.before_each(function(context)
    context.no_case = config.select_add_next_no_case
  end)
  test.after_each(function(context)
    config.select_add_next_no_case = context.no_case
    if context.buffer then context.buffer:clean() end
    panes.reset_for_tests()
  end)
  local function open(context, text)
    local buffer = core.open_buffer()
    context.buffer = buffer
    buffer:text_input(text)
    local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
    view.size.x, view.size.y = 800, 600
    view:set_wrapping_enabled(false)
    return view, buffer
  end
  local function active(view)
    return view:with_selection_state(function()
      local l1, c1, l2, c2 = view.buffer:get_selection_idx(view.buffer.last_selection, true)
      return { l1, c1, l2, c2 }
    end)
  end
  test.it("matches a case-insensitive selection across Buffer lines", function(context)
    local view, buffer = open(context, "Ab\nCd gap\naB\ncD tail\n")
    config.select_add_next_no_case = true
    view:with_selection_state(function() buffer:set_selection(2, 3, 1, 1) end)
    test.ok(command.perform("editor:add_selection_next_occurrence"))
    test.same(active(view), { 3, 1, 4, 3 })
  end)
  test.it("arms wrapping before selecting an earlier unselected range", function(context)
    local view, buffer = open(context, "hit hit hit\n")
    config.select_add_next_no_case = false
    view:with_selection_state(function()
      buffer:set_selection(1, 8, 1, 5)
      buffer:add_selection(1, 12, 1, 9)
    end)
    test.ok(command.perform("editor:add_selection_next_occurrence"))
    test.same(active(view), { 1, 9, 1, 12 })
    test.ok(command.perform("editor:add_selection_next_occurrence"))
    test.same(active(view), { 1, 1, 1, 4 })
    test.ok(command.perform("editor:add_selection_next_occurrence"))
    test.same(active(view), { 1, 1, 1, 4 }, "selected occurrences must not be added again")
  end)
end)
