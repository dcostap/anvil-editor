local test = require "core.test"
local harness = dofile("tests/fixtures/markdown/inline_harness.lua")
local corpus = harness.corpus()
local review = dofile("tests/fixtures/markdown/commonmark_review.lua")

-- The complete audit has no exclusions. Keep the supported reference cases in
-- the normal suite so a new mismatch cannot silently join the reviewed gaps.
test.describe("CommonMark inline regression cases", function()
  test.after_each(harness.close)
  local present = {}
  for _, fixture in ipairs(corpus.cases) do
    present[fixture.example] = true
    if not review[fixture.example] then
      test.it(fixture.section .. " example " .. fixture.example, function()
        harness.check_reference(corpus, fixture)
      end)
    end
  end
  for number in pairs(review) do
    assert(present[number], "reviewed CommonMark example is missing: " .. number)
  end
end)
