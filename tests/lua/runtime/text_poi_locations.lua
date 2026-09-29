local test = require "core.test"
local locations = require "core.text_poi_locations"

test.describe("File locations in long text lines", function()
  test.it("finds a file location without blocking on a long JSONL field", function()
    local line = string.rep("x", 16000) .. ":2 target.lua:9:4"
    local start = system.get_time()
    local candidates = locations.extract_line_candidates(line, 1, 32)
    local elapsed = system.get_time() - start
    local found
    for _, candidate in ipairs(candidates) do
      if candidate.source_path == "target.lua" then found = candidate end
    end
    test.not_nil(found)
    test.equal(found.target_line, 9)
    test.equal(found.target_col, 4)
    test.ok(elapsed < 1.5, "a long field blocked the main thread for " .. elapsed .. " seconds")
  end)
end)
