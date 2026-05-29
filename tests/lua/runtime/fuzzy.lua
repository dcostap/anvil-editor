local test = require "core.test"
local common = require "core.common"
local fuzzy = require "fuzzy"

test.describe("native fuzzy Lua API", function()
  test.it("filters and returns source indices", function()
    local items = { "core:open-file", "close-window", "save-all" }
    local results = fuzzy.filter(items, "opf", { limit = 10 })
    test.ok(#results >= 1)
    test.equal(results[1].index, 1)
    test.equal(results[1].text, "core:open-file")
  end)

  test.it("indexes path lists with spans", function()
    local idx = fuzzy.index({ "src/main.c", "README.md" }, { mode = "path" })
    local results = idx:search("main", { limit = 10, spans = true })
    test.equal(results[1].text, "src/main.c")
    test.same(results[1].spans[1], { 5, 8 })
    test.same(results[1].selection_span, { 5, 8 })
    test.equal(results[1].match_start, 5)
    idx:free()
  end)

  test.it("supports single-string score and match", function()
    test.ok(fuzzy.score("src/main.c", "main", { mode = "path" }))
    test.is_nil(fuzzy.score("src/main.c", "zzzz", { mode = "path" }))
    local match = fuzzy.match("src/main.c", "main", { mode = "path", spans = true })
    test.equal(match.score, fuzzy.score("src/main.c", "main", { mode = "path" }))
    test.same(match.spans[1], { 5, 8 })
    test.same(match.selection_span, { 5, 8 })
    test.equal(match.match_start, 5)
  end)

  test.it("reports cursor position but no selection for separated fuzzy chunks", function()
    local match = fuzzy.match("alpha beta", "ab", { spans = true })
    test.same(match.spans, { { 1, 1 }, { 7, 7 } })
    test.is_nil(match.selection_span)
    test.equal(match.match_start, 1)
  end)

  test.it("backs common.fuzzy_match", function()
    local results = common.fuzzy_match({ "foo", "bar", "frob" }, "fb")
    test.equal(results[1], "frob")
    test.ok(common.fuzzy_match("src/main.c", "main", true))
    test.is_nil(system.fuzzy_match)
  end)
end)
