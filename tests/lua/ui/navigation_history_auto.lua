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
      edit_debounce = 1,
      edit_near_lines = 1,
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

  test.it("keeps dwell timing when nearby movement crosses the original distance boundary", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    move_one_line_at_a_time(view, 6)

    navigation_history.update(view, 100, true)
    move_one_line_at_a_time(view, 5)
    navigation_history.update(view, 103, true)
    test.equal(panes.history_length(pane), 1)

    navigation_history.update(view, 104, true)
    test.equal(panes.history_length(pane), 2)
    test.equal(panes.back(pane), view)
    test.equal(view:get_selection_state().selections[1], 1)
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

  test.it("records the edit place captured before the debounce expires", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view
    view:set_selection_state { selections = { 10, 1, 10, 1 }, last_selection = 1 }

    local edited_at = system.get_time()
    test.ok(view:on_text_input("x"))
    view:set_selection_state { selections = { 50, 1, 50, 1 }, last_selection = 1 }
    navigation_history.update(view, edited_at + 2, true)

    test.equal(panes.history_length(pane), 2)
    test.equal(panes.back(pane), view)
    test.equal(view:get_selection_state().selections[1], 10)
    test.equal(panes.back(pane), view)
    test.equal(view:get_selection_state().selections[1], 1)
  end)

  test.it("flushes the captured edit place before Back navigation", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view
    view:set_selection_state { selections = { 10, 1, 10, 1 }, last_selection = 1 }

    test.ok(view:on_text_input("x"))
    view:set_selection_state { selections = { 50, 1, 50, 1 }, last_selection = 1 }

    test.ok(command.perform("core:navigate_back"))
    test.equal(panes.history_length(pane), 2)
    test.equal(view:get_selection_state().selections[1], 10)
  end)

  test.it("replaces a pending edit place with the latest edit", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view
    view:set_selection_state { selections = { 10, 1, 10, 1 }, last_selection = 1 }

    local edited_at = system.get_time()
    test.ok(view:on_text_input("a"))
    view:set_selection_state { selections = { 13, 1, 13, 1 }, last_selection = 1 }
    test.ok(view:on_text_input("b"))
    view:set_selection_state { selections = { 60, 1, 60, 1 }, last_selection = 1 }
    navigation_history.update(view, edited_at + 2, true)

    test.equal(panes.history_length(pane), 2)
    panes.back(pane)
    test.equal(view:get_selection_state().selections[1], 13)
  end)

  test.it("merges edit places only on the same or adjacent line", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view
    local now = system.get_time()

    view:set_selection_state { selections = { 10, 1, 10, 1 }, last_selection = 1 }
    test.ok(view:on_text_input("a"))
    navigation_history.update(view, now + 2, true)

    view:set_selection_state { selections = { 11, 1, 11, 1 }, last_selection = 1 }
    test.ok(view:on_text_input("b"))
    navigation_history.update(view, now + 4, true)
    test.equal(panes.history_length(pane), 2)

    view:set_selection_state { selections = { 14, 1, 14, 1 }, last_selection = 1 }
    test.ok(view:on_text_input("c"))
    navigation_history.update(view, now + 6, true)
    test.equal(panes.history_length(pane), 3)
  end)

  test.it("gives an edit place priority over a nearby movement place", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view
    local now = system.get_time()

    view:set_selection_state { selections = { 10, 1, 10, 1 }, last_selection = 1 }
    test.ok(panes.record_location(pane))
    view:set_selection_state { selections = { 11, 1, 11, 1 }, last_selection = 1 }
    test.ok(view:on_text_input("a"))
    navigation_history.update(view, now + 2, true)
    test.equal(panes.history_length(pane), 2)

    view:set_selection_state { selections = { 13, 1, 13, 1 }, last_selection = 1 }
    test.ok(view:on_text_input("b"))
    navigation_history.update(view, now + 4, true)
    test.equal(panes.history_length(pane), 3)
  end)

  test.it("returns to an edit place that replaced the initial nearby place", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view
    view:set_selection_state { selections = { 2, 1, 2, 1 }, last_selection = 1 }

    local edited_at = system.get_time()
    test.ok(view:on_text_input("x"))
    navigation_history.update(view, edited_at + 2, true)
    test.equal(panes.history_length(pane), 1)

    view:set_selection_state { selections = { 20, 1, 20, 1 }, last_selection = 1 }
    test.ok(command.perform("core:navigate_back"))
    test.equal(view:get_selection_state().selections[1], 2)
  end)

  test.it("creates one edit place for the scroll-focused cursor", function()
    local pane = panes.create { factory = make_editor, focus = false }
    local view = pane.current_view
    core.active_view = view
    view:set_selection_state {
      selections = { 10, 1, 10, 1, 30, 1, 30, 1 },
      last_selection = 2,
    }

    local edited_at = system.get_time()
    test.ok(view:on_text_input("x"))
    navigation_history.update(view, edited_at + 2, true)

    test.equal(panes.history_length(pane), 2)
    panes.back(pane)
    panes.forward(pane)
    local state = view:get_selection_state()
    test.equal(#state.selections, 8)
    test.equal(state.last_selection, 2)
    test.equal(state.selections[5], 30)
  end)
end)
