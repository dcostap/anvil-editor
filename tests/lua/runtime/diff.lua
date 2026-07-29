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

  test.test("uses histogram anchors to keep low-occurrence code lines stable", function()
    local before = {
      "Dinosaur* getDinosaur(char* name)",
      "{",
      '  char* dataURL = getResource("dinosaurs", name);',
      "",
      "  if (dataURL != NULL)",
      "  {",
      "    return createDinosaur(dataURL);",
      "  }",
      "  else",
      "  {",
      '    fprintf(stderr, "Could not find data: %s", name);',
      "  }",
      "  return NULL;",
      "}",
    }
    local after = {
      "Dinosaur* getDinosaur(char* name)",
      "{",
      "  if (name == NULL)",
      "  {",
      '    log.error("Dinosaur name is null!");',
      "    return NULL;",
      "  }",
      "",
      '  char* dataURL = getResource("dinosaurs", name);',
      "",
      "  if (dataURL == NULL)",
      "  {",
      '    fprintf(stderr, "Could not find data: %s", name);',
      "    return NULL;",
      "  }",
      "  else",
      "    return createDinosaur(dataURL);",
      "}",
    }

    local data_line
    for change in diff.diff_iter(before, after) do
      if change.a == before[3] or change.b == before[3] then data_line = change end
    end
    test.same(data_line, { tag = "equal", a = before[3], b = after[9] })
  end)

  test.test("handles large mostly-equal inputs without a quadratic matrix", function()
    local before, after = {}, {}
    for i = 1, 5000 do
      before[i] = "unique source line " .. i
      after[i] = before[i]
    end
    table.insert(after, 2500, "one inserted line")

    local edits, inserted = 0, 0
    for change in diff.diff_iter(before, after) do
      edits = edits + 1
      if change.tag == "insert" then inserted = inserted + 1 end
    end
    test.equal(edits, 5001)
    test.equal(inserted, 1)
  end)

  test.test("falls back to a shortest edit script for highly repeated regions", function()
    local before, after = {}, {}
    for i = 1, 200 do before[i], after[i] = "repeated", "repeated" end
    before[100], after[100] = "old center", "new center"

    local equal, modified = 0, 0
    for change in diff.diff_iter(before, after) do
      if change.tag == "equal" then equal = equal + 1 end
      if change.tag == "modify" then modified = modified + 1 end
    end
    test.equal(equal, 199)
    test.equal(modified, 1)
  end)

  test.test("returns the same histogram script from table and iterator APIs", function()
    local seed = 73129
    local function random(limit)
      seed = (seed * 48271) % 2147483647
      return seed % limit + 1
    end
    local vocabulary = { "{", "}", "", "if", "else", "return", "call()", "value" }
    for _ = 1, 40 do
      local before, after = {}, {}
      for i = 1, random(15) + 5 do before[i] = vocabulary[random(#vocabulary)] end
      for i = 1, random(15) + 5 do after[i] = vocabulary[random(#vocabulary)] end
      local iterated = {}
      for change in diff.diff_iter(before, after) do iterated[#iterated + 1] = change end
      test.same(iterated, diff.diff(before, after))
    end
  end)
end)
