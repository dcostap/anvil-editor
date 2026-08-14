local Buffer = require "core.buffer"
local tables = require "core.markdown.tables"
local test = require "core.test"

local function make_view(text)
  local buffer = Buffer("tables.md", "tables.md", true)
  buffer:insert(1, 1, text)
  return { buffer = buffer }, buffer
end

test.describe("Markdown table source lookup", function()
  test.it("returns stable table bounds and refreshes after a buffer edit", function()
    local view, buffer = make_view(
      "| Name | Value |\n"
      .. "| --- | --- |\n"
      .. "| one | 1 |\n"
      .. "| two | 2 |\n"
      .. "\n"
    )

    local line1, line2 = tables.source_bounds(view, 1)
    test.equal(line1, 1)
    test.equal(line2, 4)
    local delimiter1, delimiter2 = tables.source_bounds(view, 2)
    test.equal(delimiter1, nil)
    test.equal(delimiter2, nil)

    buffer:insert(3, 1, "| inserted | 3 |\n")
    local updated1, updated2 = tables.source_bounds(view, 3)
    test.equal(updated1, 1)
    test.equal(updated2, 5)
  end)
end)
