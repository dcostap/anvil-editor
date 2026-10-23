-- Set ANVIL_PATH_PERF_REFERENCE to a saved baseline's data/core/common.lua.
-- This compares pure path normalization in one process, without filesystem I/O.
local test = require "core.test"
local common = require "core.common"

test.describe("Path normalization measurements", function()
  test.it("compares normalization of paths from a large Project", function()
    if PLATFORM ~= "Windows" then test.skip("Windows path workload") end
    local reference_path = os.getenv("ANVIL_PATH_PERF_REFERENCE")
    if not reference_path then test.skip("set ANVIL_PATH_PERF_REFERENCE to the saved baseline module") end
    local reference = assert(loadfile(reference_path))()
    local paths = {}
    for i = 1, 10000 do
      paths[i] = string.format("D:\\Projects\\fixture\\large-project\\group-%02d\\candidate_%06d.lua", i % 64, i)
    end
    local before, after = {}, {}
    local function measure(module, samples, record)
      collectgarbage("collect")
      local started = system.get_time()
      local bytes = 0
      for _, path in ipairs(paths) do bytes = bytes + #module.normalize_path(path) end
      local elapsed = (system.get_time() - started) * 1000
      test.ok(bytes > 0)
      if record then samples[#samples + 1] = elapsed end
    end
    for i = 1, 25 do
      if i % 2 == 1 then
        measure(reference, before, i > 5)
        measure(common, after, i > 5)
      else
        measure(common, after, i > 5)
        measure(reference, before, i > 5)
      end
    end
    table.sort(before); table.sort(after)
    print(string.format("PATH_PERF paths=%d reference_median_ms=%.3f candidate_median_ms=%.3f reference_p95_ms=%.3f candidate_p95_ms=%.3f",
      #paths, before[10], after[10], before[19], after[19]))
  end)
end)
