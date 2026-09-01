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

  test.test("keeps embedded NUL bytes in diff records", function()
    local before = { "a\0old" }
    local after = { "a\0new" }
    local changes = diff.diff(before, after)
    test.equal(changes[1].a or changes[2].a, before[1])
    test.equal(changes[#changes].b, after[1])
  end)

  test.test("rejects inline diff work above its cell budget", function()
    local result, err = diff.inline_diff(string.rep("a", 200), string.rep("b", 200), 1000)
    test.equal(result, nil)
    test.equal(err, "inline diff input is too large")
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

  test.test("keeps replacement block continuation lines paired", function()
    local before = {
      "    fun test(): String {",
      "        val start = System.currentTimeMillis()",
      "        repeat(35) {",
      '            logInfo("RUNNING TEST TASK $it")',
      "            Thread.sleep(1000)",
      "        }",
    }
    local after = {
      "    fun sageBridgeHealthCheck() {",
      "        SageBridgeClient.sageBridgeConnectionCheck().onFailure {",
      "            logError(it)",
      "            // TODO(2026-08-06): add more user-friendly name to this thing. Sage bridge is a vague / confusing term. Rename the SageBridge class etc",
      '            notifyDevelopers(it, "SAGE BRIDGE HEALTH CHECK FAILURE", true)',
      "        }",
    }

    local changes = diff.diff(before, after)
    for line = 1, 5 do
      test.same(changes[line], { tag = "modify", a = before[line], b = after[line] })
    end
    test.same(changes[6], { tag = "equal", a = before[6], b = after[6] })

    local iterated = {}
    for change in diff.diff_iter(before, after) do iterated[#iterated + 1] = change end
    test.same(iterated, changes)
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
