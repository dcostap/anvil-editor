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
  local previous_options, previous_view

  test.before_each(function()
    previous_options, previous_view = config.plugins.navigation_history, core.active_view
    panes.reset_for_tests()
    config.plugins.navigation_history = {
      enabled = true, far_lines = 5, far_columns = 80,
      near_lines = 2, near_columns = 4,
    }
    navigation_history.reset()
  end)

  test.after_each(function()
    if core.active_view and core.active_view.local_find_input then command.perform("editor:find_close") end
    panes.reset_for_tests()
    config.plugins.navigation_history = previous_options
    navigation_history.reset()
    core.active_view = previous_view
  end)

  test.it("keeps nearby Find results as separate Navigation Places", function()
    local lines = {}
    for i = 1, 22 do lines[i] = "other" end
    lines[20], lines[21] = "NEEDLE", "NEEDLE"
    local buffer = Buffer()
    buffer:insert(1, 1, table.concat(lines, "\n"))
    local pane = panes.create { factory = function() return Editor(buffer) end }
    local view = pane.current_view
    local function selection()
      return view:with_selection_state(function()
        local line1, col1, line2, col2 = buffer:get_selection(true)
        return { line1, col1, line2, col2 }
      end)
    end
    core.set_active_view(view)
    view:with_selection_state(function() buffer:set_selection(10, 1) end)

    test.ok(command.perform("editor:find"))
    core.root_panel:on_text_input("NEEDLE")
    test.same(selection(), { 20, 1, 20, 7 })

    test.ok(command.perform("editor:repeat_find"))
    test.same(selection(), { 21, 1, 21, 7 })
    test.ok(command.perform("core:navigate_back"))
    test.same(selection(), { 20, 1, 20, 7 })
  end)

  test.it("keeps repeated Find result cycles distinct", function()
    local buffer = Buffer()
    buffer:insert(1, 1, "hit\nhit\n")
    local pane = panes.create { factory = function() return Editor(buffer) end }
    local view = pane.current_view
    core.set_active_view(view)

    test.ok(command.perform("editor:find"))
    core.root_panel:on_text_input("hit")
    for _ = 1, 3 do test.ok(command.perform("editor:repeat_find")) end

    test.equal(panes.back(pane), view)
    test.equal(view:get_selection_state().selections[1], 1)
    test.equal(panes.back(pane), view)
    test.equal(view:get_selection_state().selections[1], 2)
  end)
end)
