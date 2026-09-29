local test = require "core.test"
local locations = require "core.text_poi_locations"

test.describe("File locations in long text lines", function()
  test.it("finds a location at the start of a line", function()
    local candidates = locations.extract_line_candidates("target.lua:9:4", 1, 32)
    test.equal(#candidates, 1)
    test.equal(candidates[1].source_path, "target.lua")
    candidates = locations.extract_line_candidates("target.lua(9,4)", 1, 32)
    test.equal(#candidates, 1)
    test.equal(candidates[1].target_col, 4)
  end)

  test.it("ignores locations inside URLs but keeps file locations beside them", function()
    local candidates = locations.extract_line_candidates(
      "https://example.test/file.lua:7:2 target.lua:9:4", 1, 32
    )
    test.equal(#candidates, 1)
    test.equal(candidates[1].source_path, "target.lua")
  end)

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

  test.it("scans many file locations on one long line without blocking", function()
    local line = string.rep("target.lua:9:4 ", 22000)
    local start = system.get_time()
    local candidates = locations.extract_line_candidates(line, 1, 24000)
    local elapsed = system.get_time() - start
    test.equal(#candidates, 22000)
    test.equal(candidates[1].source_path, "target.lua")
    test.equal(candidates[#candidates].target_line, 9)
    test.ok(elapsed < 1.5, "many locations blocked the main thread for " .. elapsed .. " seconds")
  end)
end)
