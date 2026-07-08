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

  test.it("treats slash and backslash as the same separator in path mode", function()
    local idx = fuzzy.index({ "src\\core/main.lua", "src/core\\test.lua" }, { mode = "path" })
    local results = idx:search("core\\main", { limit = 10, spans = true })
    test.equal(results[1].text, "src\\core/main.lua")
    test.same(results[1].spans[1], { 5, 13 })

    results = idx:search("core/test", { limit = 10 })
    test.equal(results[1].text, "src/core\\test.lua")
    idx:free()

    local match = fuzzy.match("src\\core/main.lua", "core/main", { mode = "path", spans = true })
    test.ok(match)
    test.same(match.spans[1], { 5, 13 })
  end)

  test.it("keeps slash and backslash distinct in generic mode", function()
    local results = fuzzy.filter({ "src/core/main.lua", "src\\core\\main.lua" }, "src/core/main", { limit = 10 })
    test.equal(#results, 1)
    test.equal(results[1].text, "src/core/main.lua")
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

  test.it("rejects medium-length scattered coincidence matches", function()
    test.is_nil(fuzzy.score("core:add-directory-system-file-picker", "caret"))
    local results = fuzzy.filter({
      "core:add-directory-system-file-picker",
      "caret-type",
      "core:toggle-caret-type",
    }, "caret", { limit = 10 })
    test.equal(#results, 2)
    test.equal(results[1].text, "caret-type")
    test.equal(results[2].text, "core:toggle-caret-type")
  end)
end)
