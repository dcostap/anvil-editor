local Buffer = require "core.buffer"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local navigation_history = require "core.navigation_history"
local panes = require "core.panes"
local test = require "core.test"

local function make_editor()
  local buffer = Buffer(nil, nil, true)
  buffer.lines = {}
  for index = 1, 100 do buffer.lines[index] = "line\n" end
  return Editor(buffer)
end

local function move_one_line_at_a_time(view, target)
  local state = view:get_selection_state()
  local line = state.selections[1]
  local step = target < line and -1 or 1
  while line ~= target do
    line = line + step
    view:set_selection_state { selections = { line, 1, line, 1 }, last_selection = 1 }
  end
end

test.describe("automatic Editor Navigation History", function()
  local old_options
  local old_active_view

  test.before_each(function()
    panes.reset_for_tests()
    old_options = config.plugins.navigation_history
    old_active_view = core.active_view
    config.plugins.navigation_history = {
      enabled = true,
      sample_interval = 1,
      dwell_time = 4,
      far_lines = 5,
      far_columns = 10,
      near_lines = 2,
      near_columns = 4,
      feedback = true,
      feedback_duration = 0.25,
    }
    navigation_history.reset()
  end)

  test.after_each(function()
    navigation_history.reset()
    config.plugins.navigation_history = old_options
    panes.reset_for_tests()
    core.active_view = old_active_view
  end)

  test.it("records a distant place after the caret dwells near it", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    move_one_line_at_a_time(view, 10)

    navigation_history.update(view, 100, true)
    navigation_history.update(view, 103, true)
    test.equal(panes.history_length(pane), 1)

    navigation_history.update(view, 104, true)
    test.equal(panes.history_length(pane), 2)
    test.equal(panes.back(pane), view)
    test.equal(view:get_selection_state().selections[1], 1)
  end)

  test.it("restarts dwell timing when the caret leaves the near area", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    move_one_line_at_a_time(view, 10)

    navigation_history.update(view, 100, true)
    move_one_line_at_a_time(view, 13)
    navigation_history.update(view, 103, true)
    navigation_history.update(view, 106, true)
    test.equal(panes.history_length(pane), 1)

    navigation_history.update(view, 107, true)
    test.equal(panes.history_length(pane), 2)
  end)

  test.it("records both ends of a start or end Buffer command immediately", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view

    test.ok(command.perform("core:move_to_end_of_buffer"))

    test.equal(panes.history_length(pane), 2)
    test.equal(panes.back(pane), view)
    test.equal(view:get_selection_state().selections[1], 1)
    test.equal(panes.forward(pane), view)
    test.equal(view:get_selection_state().selections[1], 100)
    test.equal(panes.history_length(pane), 2)
  end)

  test.it("does not add a nearby origin before a start or end Buffer command", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view
    view:set_selection_state { selections = { 2, 1, 2, 1 }, last_selection = 1 }

    test.ok(command.perform("core:move_to_end_of_buffer"))

    test.equal(panes.history_length(pane), 2)
    panes.back(pane)
    test.equal(view:get_selection_state().selections[1], 1)
  end)

  test.it("does not treat an ordinary Selection State update as a radical command", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view

    view:set_selection_state { selections = { 50, 1, 50, 1 }, last_selection = 1 }

    test.equal(panes.history_length(pane), 1)
  end)

  test.it("does not treat a column change on another line as horizontal distance", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    view.buffer.lines[2] = string.rep("x", 200) .. "\n"
    view:set_selection_state { selections = { 2, 100, 2, 100 }, last_selection = 1 }

    navigation_history.update(view, 100, true)
    navigation_history.update(view, 104, true)

    test.equal(panes.history_length(pane), 1)
  end)
end)
