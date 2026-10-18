local Buffer = require "core.buffer"
local command = require "core.command"
local config = require "core.config"
local core = require "core"
local Editor = require "core.editor"
local navigation_history = require "core.navigation_history"
local panes = require "core.panes"
local test = require "core.test"

require "plugins.intellij_find"

test.describe("Local Find Navigation History", function()
  local previous_options, previous_view, view, pane

  local function selection()
    return view:with_selection_state(function()
      local line1, col1, line2, col2 = view.buffer:get_selection(true)
      return { line1, col1, line2, col2 }
    end)
  end

  test.before_each(function()
    previous_options, previous_view = config.plugins.navigation_history, core.active_view
    panes.reset_for_tests()
    config.plugins.navigation_history = {
      enabled = true, far_lines = 5, far_columns = 80,
      near_lines = 2, near_columns = 4, dwell_time = 1,
    }
    navigation_history.reset()
    local lines = {}
    for i = 1, 30 do lines[i] = "other" end
    lines[20], lines[21], lines[30] = "NEEDLE", "NEEDLE", "NEEDLE"
    local buffer = Buffer()
    buffer:insert(1, 1, table.concat(lines, "\n"))
    pane = panes.create { factory = function() return Editor(buffer) end }
    view = pane.current_view
    core.set_active_view(view)
    view:with_selection_state(function() buffer:set_selection(10, 1) end)
  end)

  test.after_each(function()
    core.set_active_view(view)
    command.perform("editor:find_close")
    panes.reset_for_tests()
    config.plugins.navigation_history = previous_options
    navigation_history.reset()
    core.active_view = previous_view
  end)

  local function open_find()
    test.ok(command.perform("editor:find"))
    core.active_view:set_text("NEEDLE")
  end

  test.it("does not record result browsing, even after a pause", function()
    local count = panes.history_length(pane)
    open_find()
    test.same(selection(), { 20, 1, 20, 7 })
    test.ok(command.perform("editor:find_field_next"))
    test.same(selection(), { 21, 1, 21, 7 })
    test.ok(command.perform("editor:find_field_previous"))
    test.same(selection(), { 20, 1, 20, 7 })
    core.set_active_view(view)
    navigation_history.sample(view, 100)
    navigation_history.sample(view, 102)
    test.equal(panes.history_length(pane), count)
  end)

  test.it("records only the final match on close and returns directly to the origin", function()
    open_find()
    for _ = 1, 4 do test.ok(command.perform("editor:repeat_find")) end
    test.same(selection(), { 21, 1, 21, 7 })
    test.ok(command.perform("editor:find_close"))
    test.equal(core.active_view, view)
    test.equal(panes.history_length(pane), 3)
    test.equal(panes.back(pane), view)
    test.same(selection(), { 10, 1, 10, 1 })
    test.equal(panes.forward(pane), view)
    test.same(selection(), { 21, 1, 21, 7 })
  end)

  test.it("keeps the original departure when Find is focused again", function()
    open_find()
    core.set_active_view(view)
    test.ok(command.perform("editor:find"))
    test.ok(command.perform("editor:repeat_find"))
    test.ok(command.perform("editor:find_close"))
    test.equal(panes.back(pane), view)
    test.same(selection(), { 10, 1, 10, 1 })
  end)

  test.it("records a nearby final match as a distinct destination", function()
    view:with_selection_state(function() view.buffer:set_selection(19, 1) end)
    open_find()
    test.ok(command.perform("editor:find_close"))
    test.equal(panes.back(pane), view)
    test.same(selection(), { 19, 1, 19, 1 })
    test.equal(panes.forward(pane), view)
    test.same(selection(), { 20, 1, 20, 7 })
  end)

  test.it("does not add a place when a search has no match", function()
    view:with_selection_state(function() view.buffer:set_selection(10, 6, 10, 1) end)
    local count = panes.history_length(pane)
    test.ok(command.perform("editor:find"))
    core.active_view:set_text("missing")
    test.ok(command.perform("editor:find_close"))
    test.equal(panes.history_length(pane), count)
    test.same(selection(), { 10, 1, 10, 6 })
  end)
end)
