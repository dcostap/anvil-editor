local config = require "core.config"
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
  test.after_each(function(context)
    config.plugins.diffview.ignore_whitespace = context.ignore_whitespace
    if context.view then context.view:on_close() end
  end)

  test.it("ignores formatting by default and updates an open comparison when the preference changes", function(context)
    context.ignore_whitespace = config.plugins.diffview.ignore_whitespace
    local before = "before\n    loading = false\n    value = oldValue\nend"
    local after = "before\n        loading=false  \n    value = newValue\nend"
    local view = diffview.string_to_string(before, after, "Before", "After", true)
    context.view = view
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 2), "equal")
    test.equal(view:diff_points_of_interest(false)[1].line, 3)

    config.plugins.diffview.ignore_whitespace = false
    view:update()
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 2), "modify")

    config.plugins.diffview.ignore_whitespace = true
    view:update()
    wait_for_diff(view)
    test.equal(view.diff_model:line_state("b", 2), "equal")
    test.equal(table.concat(view.buffer_view_a.buffer.lines), before .. "\n")
    test.equal(table.concat(view.buffer_view_b.buffer.lines), after .. "\n")
  end)
end)
