local test = require "core.test"

test.describe("diff", function()
  test.test("splits strings by chars and lines", function()
    test.same(diff.split("abc", "char"), {"a", "b", "c"})
    test.same(diff.split("a\nb\n", "line"), {"a", "b", ""})
  end)

  test.test("returns exact line and inline change records", function()
    local before = {"one", "two"}
    local after = {"one", "three"}
    local expected = {
      { tag = "equal", a = "one", b = "one" },
      { tag = "delete", a = "two" },
      { tag = "insert", b = "three" },
    }

    test.same(diff.diff(before, after), expected)

    local iter_changes = {}
    for change in diff.diff_iter(before, after) do
      table.insert(iter_changes, change)
    end
    test.same(iter_changes, expected)

    test.same(diff.inline_diff("cat", "cot"), {
      { tag = "equal", val = "c" },
      { tag = "insert", val = "o" },
      { tag = "delete", val = "a" },
      { tag = "equal", val = "t" },
    })
  end)
end)
