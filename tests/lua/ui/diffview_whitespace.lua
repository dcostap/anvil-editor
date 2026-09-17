local config = require "core.config"
local core = require "core"
local command = require "core.command"
local test = require "core.test"
local diffview = require "plugins.diffview"

local function wait_for_diff(view)
  local deadline = system.get_time() + 2
  while view.updater_idx do
    test.ok(system.get_time() < deadline, "diff computation did not finish")
    coroutine.yield(0.01)
  end
end

test.describe("Diff View whitespace preference", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.whitespace_mode = config.plugins.diffview.whitespace_mode
  end)

  test.after_each(function(context)
    core.active_view = context.active_view
    config.plugins.diffview.whitespace_mode = context.whitespace_mode
    if context.view then context.view:on_close() end
  end)

  test.it("cycles whitespace comparison modes from a Diff Side", function(context)
    config.plugins.diffview.whitespace_mode = "trim"
    local view = diffview.string_to_string("loading = false", "    loading=false", "Before", "After", true)
    context.view = view
    wait_for_diff(view)

    core.active_view = view.buffer_view_b
    test.equal(command.get_status("diff:cycle_whitespace_mode", view.buffer_view_b), "Trim Whitespace")
    test.equal(command.perform("diff:cycle_whitespace_mode"), true)
    test.equal(command.get_status("diff:cycle_whitespace_mode", view.buffer_view_b), "Ignore All Whitespace")
    view:update()
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 1), "equal")

    test.equal(command.perform("diff:cycle_whitespace_mode"), true)
    test.equal(command.get_status("diff:cycle_whitespace_mode", view), "None")
    view:update()
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 1), "modify")

    test.equal(command.perform("diff:cycle_whitespace_mode"), true)
    test.equal(command.get_status("diff:cycle_whitespace_mode", view), "Trim Whitespace")
    view:update()
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 1), "modify")
  end)

  test.it("trims line edges by default and updates an open comparison when the preference changes", function(context)
    local before = "before\n    loading = false\n    value = oldValue\nend"
    local after = "before\n        loading = false  \n    value = newValue\nend"
    local view = diffview.string_to_string(before, after, "Before", "After", true)
    context.view = view
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 2), "equal")
    test.equal(view:diff_points_of_interest(false)[1].line, 3)

    config.plugins.diffview.whitespace_mode = "none"
    view:update()
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 2), "modify")

    config.plugins.diffview.whitespace_mode = "ignore"
    view:update()
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 2), "equal")
    test.equal(table.concat(view.buffer_view_a.buffer.lines), before .. "\n")
    test.equal(table.concat(view.buffer_view_b.buffer.lines), after .. "\n")
  end)
end)
