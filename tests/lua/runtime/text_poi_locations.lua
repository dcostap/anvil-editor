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

  test.it("keeps format priority when limiting mixed locations", function()
    local text = "first.lua:1 file:///tmp/second.lua:2"
    local candidates = locations.extract_line_candidates(text, 1, 1)
    test.equal(#candidates, 1)
    test.equal(candidates[1].source_path, "file:///tmp/second.lua")
    candidates = locations.extract_line_candidates(text, 1, 2)
    test.equal(#candidates, 2)
    test.equal(candidates[1].source_path, "first.lua")
    test.equal(candidates[2].source_path, "file:///tmp/second.lua")
    test.equal(#locations.extract_line_candidates(text, 1, 0), 0)
  end)

  test.it("rejects URI fragments when a later format returns to an earlier column", function()
    local candidates = locations.extract_line_candidates(
      "https://site.test/a.lua:9,4 first.lua:3:2 second.lua(4,2)", 1, 32)
    test.equal(#candidates, 2)
    test.equal(candidates[1].source_path, "first.lua")
    test.equal(candidates[1].target_col, 2)
    test.equal(candidates[2].source_path, "second.lua")
    test.equal(candidates[2].target_line, 4)
  end)

  test.it("finds a file location after a long JSONL field", function()
    local line = string.rep("x", 16000) .. ":2 target.lua:9:4"
    local candidates = locations.extract_line_candidates(line, 1, 32)
    local found
    for _, candidate in ipairs(candidates) do
      if candidate.source_path == "target.lua" then found = candidate end
    end
    test.not_nil(found)
    test.equal(found.target_line, 9)
    test.equal(found.target_col, 4)
  end)

  test.it("scans many file locations on one long line", function()
    local line = string.rep("target.lua:9:4 ", 22000)
    local candidates = locations.extract_line_candidates(line, 1, 24000)
    test.equal(#candidates, 22000)
    test.equal(candidates[1].source_path, "target.lua")
    test.equal(candidates[#candidates].target_line, 9)
  end)
end)
