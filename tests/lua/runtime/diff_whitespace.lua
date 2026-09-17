local test = require "core.test"
local model = require "plugins.diff.model"

test.describe("Diff whitespace comparison", function()
  test.it("trims line edges but keeps internal whitespace significant", function()
    local edge_only = model.compute(
      { '  label = "a b"  ' },
      { 'label = "a b"' },
      { whitespace_mode = "trim" }
    )
    test.equal(edge_only:line_state("a", 1), "equal")
    test.equal(edge_only:line_state("b", 1), "equal")

    local internal = model.compute(
      { 'label = "a b"' },
      { 'label = "ab"' },
      { whitespace_mode = "trim" }
    )
    test.equal(internal:line_state("a", 1), "modify")
    test.equal(internal:line_state("b", 1), "modify")
  end)

  test.it("highlights internal whitespace changes in trim mode", function()
    local before, after = "label = value", "label=value"
    local m = model.compute({ before }, { after }, { whitespace_mode = "trim" })
    local old_ranges, new_ranges = m:inline_ranges("a", 1), m:inline_ranges("b", 1)
    test.equal(#old_ranges, 2)
    for _, range in ipairs(old_ranges) do
      test.equal(before:sub(range.col1, range.col2 - 1), " ")
    end
    test.same(new_ranges, {})
  end)

  test.it("ignores whitespace throughout a line without changing the source text", function()
    local before = { '\t label = "a b" \t\n', "    loading = false\n" }
    local after = { 'label="ab"\n', "        loading=false  \n" }
    local m = model.compute(before, after, { whitespace_mode = "ignore" })
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
      whitespace_mode = "ignore",
    })
    test.equal(m:line_state("b", 2), "insert")
    test.equal(m:map_line("a", 2), 3)
    local split = model.compute({ "ab\n" }, { "a\n", "b\n" }, { whitespace_mode = "ignore" })
    test.not_nil(split:next_hunk("b", 1))
  end)

  test.it("highlights real word changes at their original columns", function()
    local before = "result = left == oldName\n"
    local after = "  result=left = = newName  \n"
    local m = model.compute({ before }, { after }, { whitespace_mode = "ignore" })
    test.equal(m:line_state("b", 1), "modify")
    local old_ranges, new_ranges = m:inline_ranges("a", 1), m:inline_ranges("b", 1)
    test.equal(#old_ranges, 1)
    test.equal(#new_ranges, 1)
    test.equal(before:sub(old_ranges[1].col1, old_ranges[1].col2 - 1), "oldName")
    test.equal(after:sub(new_ranges[1].col1, new_ranges[1].col2 - 1), "newName")
  end)

  test.it("does not include an unchanged keyword in a renamed identifier highlight", function()
    local before, after = "val oldName = true\n", "  val newName=true\n"
    local m = model.compute({ before }, { after }, { whitespace_mode = "ignore" })
    local old_range, new_range = m:inline_ranges("a", 1)[1], m:inline_ranges("b", 1)[1]
    test.equal(before:sub(old_range.col1, old_range.col2 - 1), "oldName")
    test.equal(after:sub(new_range.col1, new_range.col2 - 1), "newName")
  end)
end)
