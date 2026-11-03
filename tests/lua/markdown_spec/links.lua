local test = require "core.test"
local harness = dofile("tests/fixtures/markdown/inline_harness.lua")

-- This compares reference behavior, not an approved change to Anvil's rule.
-- Anvil currently shows the label's ** markers literally. Review that choice
-- before changing link presentation. The semantic model already reports bold.
test.describe("Markdown link presentation audit", function()
  test.after_each(harness.close)

  test.it("formats Markdown inside an inline link label", function()
    local view = harness.view("[**bold**](target.md)")
    test.same(harness.runs(view, 1), { { text = "bold", style = "strong" } })
  end)
end)
