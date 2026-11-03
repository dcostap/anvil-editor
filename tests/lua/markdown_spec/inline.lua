local test = require "core.test"
local harness = dofile("tests/fixtures/markdown/inline_harness.lua")
local corpus = harness.corpus()
local review = dofile("tests/fixtures/markdown/commonmark_review.lua")

-- Keep the reference expectations unchanged. Anvil rules belong in the normal
-- regression suite. A mismatch here is an audit result, not a requested rule change.
test.describe("CommonMark " .. corpus.version .. " inline presentation audit", function()
  test.after_each(harness.close)
  for _, fixture in ipairs(corpus.cases) do
    test.it(fixture.section .. " example " .. fixture.example, function()
      if review[fixture.example] then print("Review: " .. review[fixture.example]) end
      harness.check_reference(corpus, fixture)
    end)
  end
end)
