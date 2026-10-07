local terminal = require "plugins.terminal"
local test = require "core.test"

-- Seam: suspended View updates with a fake native Terminal grid.
test.describe("Hidden Terminal geometry", function()
  test.after_each(function() terminal._set_native_for_tests(nil) end)

  test.it("keeps the native grid until the View has layout geometry", function()
    local grid = {}
    terminal._set_native_for_tests {
      new = function(options)
        grid.cols, grid.rows = options.cols, options.rows
        return {
          stats = function() return {attach_count = 1, host_pid = 1, shell_pid = 2, replay_bytes = 0} end,
          snapshot = function() return {cols = grid.cols, row_count = grid.rows, rows = {}, events = {}} end,
          resize = function(_, cols, rows) grid.cols, grid.rows = cols, rows; return true end,
          focus = function() return true end,
          update = function() return false, {kind = "running", revision = 1, attach_count = 1} end,
        }
      end,
    }
    local view = terminal.TerminalView {cwd = system.getcwd()}
    local cols, rows = grid.cols, grid.rows
    view.size.x, view.size.y = 0, 0
    view:update_suspended()
    test.equal(grid.cols, cols, "missing View geometry changed the native columns")
    test.equal(grid.rows, rows, "missing View geometry changed the native rows")
  end)
end)
