local test = require "core.test"
local model = require "plugins.diff.model"

test.describe("Diff whitespace comparison", function()
  test.it("ignores whitespace throughout a line without changing the source text", function()
    local before = { '\t label = "a b" \t\n', "    loading = false\n" }
    local after = { 'label="ab"\n', "        loading=false  \n" }
    local m = model.compute(before, after, { ignore_whitespace = true })
    for line = 1, 2 do
      test.equal(m:line_state("a", line), "equal")
      test.equal(m:line_state("b", line), "equal")
      test.equal(m:map_line("a", line), line)
      test.same(m:inline_ranges("b", line), {})
    end
    test.equal(m:next_hunk("a", 1), nil)
    test.same(before, { '\t label = "a b" \t\n', "    loading = false\n" })
    test.same(after, { 'label="ab"\n', "        loading=false  \n" })
  end)

  test.it("still reports added blank lines and line breaks", function()
    local m = model.compute({ "alpha\n", "beta\n" }, { "alpha\n", " \t\n", "beta\n" }, {
      ignore_whitespace = true,
    })
    test.equal(m:line_state("b", 2), "insert")
    test.equal(m:map_line("a", 2), 3)
    local split = model.compute({ "ab\n" }, { "a\n", "b\n" }, { ignore_whitespace = true })
    test.not_nil(split:next_hunk("b", 1))
  end)

  test.it("highlights real word changes at their original columns", function()
    local before = "result = left == oldName\n"
    local after = "  result=left = = newName  \n"
    local m = model.compute({ before }, { after }, { ignore_whitespace = true })
    test.equal(m:line_state("b", 1), "modify")
    local old_ranges, new_ranges = m:inline_ranges("a", 1), m:inline_ranges("b", 1)
    test.equal(#old_ranges, 1)
    test.equal(#new_ranges, 1)
    test.equal(before:sub(old_ranges[1].col1, old_ranges[1].col2 - 1), "oldName")
    test.equal(after:sub(new_ranges[1].col1, new_ranges[1].col2 - 1), "newName")
  end)

  test.it("does not include an unchanged keyword in a renamed identifier highlight", function()
    local before, after = "val oldName = true\n", "  val newName=true\n"
    local m = model.compute({ before }, { after }, { ignore_whitespace = true })
    local old_range, new_range = m:inline_ranges("a", 1)[1], m:inline_ranges("b", 1)[1]
    test.equal(before:sub(old_range.col1, old_range.col2 - 1), "oldName")
    test.equal(after:sub(new_range.col1, new_range.col2 - 1), "newName")
  end)
end)
