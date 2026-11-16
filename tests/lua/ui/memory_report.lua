local core = require "core"
local command = require "core.command"
local common = require "core.common"
local perf = require "core.perf"
local hud = require "plugins.performance_hud"
local test = require "core.test"

-- Seam: the command saves a complete report through the real file worker.
test.describe("Memory report command", function()
  test.it("saves collection results and Lua owners without changing focus", function()
    local root = USERDIR .. PATHSEP .. "memory-report-command"
    test.ok(common.mkdirp(root))
    local output_path, clipboard, previous_path = perf.output_path, system.get_clipboard(), hud.last_saved_path
    local active = core.active_view
    perf.output_path = function() return root .. PATHSEP .. "report.txt" end
    local ok, err = pcall(function()
      test.ok(command.perform("core:record_memory_report"))
      local deadline = system.get_time() + 30
      while not hud.last_saved_path and system.get_time() < deadline do coroutine.yield(0.01) end
      test.equal(hud.last_saved_path, root .. PATHSEP .. "report.txt")
      local file = assert(io.open(hud.last_saved_path, "rb"))
      local text = file:read("*a")
      file:close()
      test.ok(text:find("private_commit_bytes", 1, true))
      test.ok(text:find("after GC", 1, true))
      test.ok(text:find("Lua heap census", 1, true))
      test.equal(system.get_clipboard(), hud.last_saved_path)
      test.equal(core.active_view, active)
    end)
    perf.output_path, hud.last_saved_path = output_path, previous_path
    system.set_clipboard(clipboard)
    test.ok(test.remove_tree(root))
    assert(ok, err)
  end)
end)
