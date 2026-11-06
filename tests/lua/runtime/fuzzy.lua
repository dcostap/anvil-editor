local test = require "core.test"
local common = require "core.common"
local fuzzy = require "fuzzy"

test.describe("native fuzzy Lua API", function()
  test.it("keeps fuzzy matching but requires matching letter case when requested", function()
    local opts = { case_sensitive = true, spans = true }
    test.is_nil(fuzzy.match("renderWidget", "RW", opts))
    local match = test.not_nil(fuzzy.match("RenderWidget", "RW", opts))
    test.same(match.spans, { { 1, 1 }, { 7, 7 } })
    local rows = fuzzy.filter({ "renderWidget", "RenderWidget", "RENDERWidget" },
      "RW", opts)
    test.equal(#rows, 2)
    test.ok(rows[1].text == "RenderWidget" or rows[2].text == "RenderWidget")
    local index = fuzzy.index({ "renderWidget", "RenderWidget" })
    test.equal(#index:search("RW", opts), 1)
    index:free()
    test.equal(#fuzzy.filter({ "renderWidget", "RenderWidget" }, "RW"), 2)
  end)

  test.it("filters and returns source indices", function()
    local items = { "core:pick_file", "close-window", "save-all" }
    local results = fuzzy.filter(items, "opf", { limit = 10 })
    test.ok(#results >= 1)
    test.equal(results[1].index, 1)
    test.equal(results[1].text, "core:pick_file")
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

  test.it("ranks a word-boundary match above the same embedded match", function()
    local boundary = fuzzy.match("working directory", "working director")
    local embedded = fuzzy.match("reworking directory", "working director")

    test.not_nil(boundary)
    test.not_nil(embedded)
    test.ok(boundary.score > embedded.score,
      "matching at the word boundary should rank above an embedded match")
  end)

  test.it("matches Latin letters without diacritics", function()
    local results = fuzzy.filter({ "éclair", "eclair", "resume", "naïve" }, "ecl", { limit = 10 })
    local found_accented = false
    for _, result in ipairs(results) do
      if result.text == "éclair" then found_accented = true end
    end
    test.ok(found_accented)
    results = fuzzy.filter({ "éclair", "eclair" }, "écl", { limit = 10 })
    test.ok(#results == 2)
    results = fuzzy.filter({ "eclair" }, "ëcl", { limit = 10 })
    test.equal(results[1].text, "eclair")

    local match = fuzzy.match("éclair", "ecl", { spans = true })
    test.same(match.spans, { { 1, 4 } })
    test.equal(match.match_class, "contiguous")
  end)

  test.it("keeps enye distinct and accepts its combining form", function()
    test.is_nil(fuzzy.match("niño", "nino"))
    test.is_nil(fuzzy.match("nin\204\131o", "nino"))
    local match = test.not_nil(fuzzy.match("nin\204\131o", "NIÑO", { spans = true }))
    test.same(match.spans, { { 1, 6 } })
    test.is_nil(fuzzy.match("NIÑO", "niño", { case_sensitive = true }))
  end)

  test.it("finds literal accent equivalents at original byte positions", function()
    local text = "café cafe cafe\204\129 CAFÉ"
    for _, query in ipairs { "cafe", "café", "cafe\204\129" } do
      local literal = fuzzy.literal(query)
      test.same(literal:spans(text), { {1, 5}, {7, 10}, {12, 17}, {19, 23} })
      test.equal(literal:find(text), 1)
      -- The external candidate filter must not lose an accepted spelling.
      local pattern = test.not_nil(regex.compile(literal:pattern(), "i"))
      for _, spelling in ipairs { "café", "cafe", "cafe\204\129", "CAFÉ" } do
        test.not_nil(pattern:find(spelling))
      end
    end
    test.same(fuzzy.literal("café", { case_sensitive = true }):spans(text),
      { {1, 5}, {7, 10}, {12, 17} })
    test.same(fuzzy.literal("ñ"):spans("n ñ n\204\131 Ñ"), { {3, 4}, {6, 8}, {10, 11} })
    test.same(fuzzy.literal("n"):spans("ñ n\204\131 n"), { {8, 8} })
    test.same(fuzzy.literal("i"):spans("İ"), { {1, 2} })
    test.not_nil(assert(regex.compile(fuzzy.literal("i"):pattern(), "i")):find("İ"))
  end)

  test.it("keeps scanner candidates with multi-character canonical decompositions", function()
    for _, case in ipairs {
      { "কো", "কো" }, { "কো", "কো" }, { "কো", "কো" },
      { "ো", "কো" }, { "ে", "কো" }, { "া", "কো" },
      { "কো xyz", "কো xyz" }, { "கொ", "கொ" }, { "གྷ", "གྷ" },
    } do
      local literal = fuzzy.literal(case[1])
      test.not_nil(literal:find(case[2]), "native matcher lost " .. case[1])
      test.not_nil(assert(regex.compile(literal:pattern(), "i")):find(case[2]),
        "candidate filter lost " .. case[1] .. " in " .. case[2])
    end
    test.same(fuzzy.literal("ে"):spans("কো"), { {4, 6} })
    test.same(fuzzy.literal("া"):spans("কো"), { {4, 6} })
  end)

  test.it("keeps literal punctuation, repeated matches and empty queries safe", function()
    local query = "a.*[é](x)\\+$?{z}|^"
    local literal = fuzzy.literal(query)
    test.same(literal:spans(query .. " " .. query), { {1, #query}, {#query + 2, #query * 2 + 1} })
    test.is_nil(literal:find("abcde"))
    local pattern = test.not_nil(regex.compile(literal:pattern()))
    test.not_nil(pattern:find(query))
    test.is_nil(pattern:find("abcde"))
    for _, empty in ipairs { "", "\204\129" } do
      test.same(fuzzy.literal(empty):spans("cafe"), {})
      test.is_nil(assert(regex.compile(fuzzy.literal(empty):pattern())):find("cafe"))
    end
    test.same(fuzzy.literal("aaa"):spans("aaaaaa"), { {1, 3}, {4, 6} })
    test.same(fuzzy.literal("cafe"):spans("\255\0café"), { {3, 7} })
    local long = string.rep("a", 4096) .. "é"
    test.same(fuzzy.literal(long):spans("x" .. long), { {2, #long + 1} })
    test.same(fuzzy.literal("σ"):spans("Σ ς σ"), { {1, 2}, {4, 5}, {7, 8} })
    test.same(fuzzy.literal("s"):spans("ſ S"), { {1, 2}, {4, 4} })
  end)

  test.it("matches text after embedded NUL bytes", function()
    local text = "prefix\0éclair"
    test.ok(fuzzy.score(text, "ecl"))
    local match = fuzzy.match(text, "ecl", { spans = true })
    test.equal(match.text, text)
    test.same(match.spans, { { 8, 11 } })
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
  end)

  test.it("rejects medium-length scattered coincidence matches", function()
    test.is_nil(fuzzy.score("core:add_directory_system_file_picker", "caret"))
    local results = fuzzy.filter({
      "core:add_directory_system_file_picker",
      "caret-type",
      "core:toggle_caret_type",
    }, "caret", { limit = 10 })
    test.equal(#results, 2)
    test.equal(results[1].text, "caret-type")
    test.equal(results[2].text, "core:toggle_caret_type")
  end)
end)
