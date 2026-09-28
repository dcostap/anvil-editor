local test = require "core.test"
local Workload = require "core.perf_workloads"

test.describe("benchmark decoration readiness", function()
  test.it("waits for every file caption and diff decoration", function()
    local old_status = package.loaded["plugins.file_git_status"]
    local old_diff = package.loaded["plugins.gitdiff_highlight"]
    local status_ready, diff_ready = {}, {}
    package.loaded["plugins.file_git_status"] = {
      is_settled = function(_, path) return status_ready[path] == true end,
    }
    package.loaded["plugins.gitdiff_highlight"] = {
      is_settled = function(buffer) return diff_ready[buffer.abs_filename] == true end,
    }
    local ok, err = pcall(function()
      local buffers = { {}, { abs_filename = "one.lua" }, { abs_filename = "two.lua" } }
      test.equal(Workload.buffers_ready(buffers), false)
      status_ready["one.lua"], diff_ready["one.lua"] = true, true
      test.equal(Workload.buffers_ready(buffers), false)
      status_ready["two.lua"] = true
      test.equal(Workload.buffers_ready(buffers), false)
      diff_ready["two.lua"] = true
      test.equal(Workload.buffers_ready(buffers), true)
    end)
    package.loaded["plugins.file_git_status"] = old_status
    package.loaded["plugins.gitdiff_highlight"] = old_diff
    if not ok then error(err, 0) end
  end)
end)
