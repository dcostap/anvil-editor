local core = require "core"
local test = require "core.test"
local config = require "core.config"
local Workload = require "core.perf_workloads"
local diffview = require "plugins.diffview"

test.describe("Diff wheel benchmark actions", function()
  test.it("scrolls both Diff Sides through the wheel handler", function()
    local active = core.active_view
    local fold = config.plugins.diffview.fold_unchanged_by_default
    local layout = config.plugins.diffview.layout
    config.plugins.diffview.fold_unchanged_by_default = false
    local view = diffview.string_to_string(
      string.rep("local value = 1\n", 200), string.rep("local value = 2\n", 200),
      "Before", "After", true)
    config.plugins.diffview.fold_unchanged_by_default = fold
    local ok, err = pcall(function()
      local deadline = system.get_time() + 5
      while view.updater_idx do
        test.ok(system.get_time() < deadline, "Diff comparison did not finish")
        coroutine.yield(0.01)
      end
      config.plugins.diffview.layout = "side-by-side"
      view.size.x, view.size.y = 2400, 400
      view:update()
      test.not_ok(view.unified, "benchmark requires side-by-side drawing")
      local left, right = view.buffer_view_a, view.buffer_view_b
      left:set_wrapping_enabled(false)
      right:set_wrapping_enabled(false)
      core.set_active_view(right)
      local workload = Workload.new({ kind = "diff", action = "wheel", wrap = false,
        save_workspace = true, actions = 41 }, "")
      workload.diff, workload.view = view, right
      local left_before, right_before = left.scroll.to.y, right.scroll.to.y
      workload:dispatch(1)
      test.ok(left.scroll.to.y > left_before, "benchmark did not scroll the left Diff Side")
      test.ok(right.scroll.to.y > right_before, "benchmark did not scroll the right Diff Side")
    end)
    view:on_close()
    core.active_view = active
    config.plugins.diffview.layout = layout
    if not ok then error(err, 0) end
  end)
end)
