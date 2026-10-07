local test = require "core.test"
local model = require "plugins.diff.model"

test.describe("Inline diff gap marks", function()
  for _, example in ipairs {
    { "a call chain", "value = fetchValue().trim();", "value = cachedValue;", "cachedValue" },
    { "a field expression", 'numberOfAxles = root.firstDescendantText("NumberOfAxles").normalizeImportText(),',
      "numberOfAxles = numberOfAxles,", "numberOfAxles" },
  } do
    test.it("does not repeat the replacement highlight for " .. example[1], function()
      for _, mode in ipairs { "none", "trim", "ignore" } do
        for _, reverse in ipairs { false, true } do
          local before, after = example[2], example[3]
          if reverse then before, after = after, before end
          local comparison = model.compute({ before }, { after }, { whitespace_mode = mode })
          test.same(comparison:inline_markers("a", 1), {})
          test.same(comparison:inline_markers("b", 1), {})
          local side = reverse and "a" or "b"
          local replacement = example[3]:find(example[4], example[3]:find("=", 1, true) + 1, true)
          local highlighted = false
          for _, range in ipairs(comparison:inline_ranges(side, 1)) do
            if range.col1 <= replacement and range.col2 >= replacement + #example[4] then
              highlighted = true
            end
          end
          test.ok(highlighted, "the replacement must retain its inline highlight")
        end
      end
    end)
  end

  test.it("keeps the location of an argument removed between unchanged arguments", function()
    for _, mode in ipairs { "none", "trim", "ignore" } do
      local before, after = "send(first, extra, last);", "send(first, last);"
      local comparison = model.compute({ before }, { after }, { whitespace_mode = mode })
      test.same(comparison:inline_markers("b", 1), { { col = 13 } })
      test.same(comparison:inline_ranges("b", 1), {})
      local reversed = model.compute({ after }, { before }, { whitespace_mode = mode })
      test.same(reversed:inline_markers("a", 1), { { col = 13 } })
    end
  end)
end)
