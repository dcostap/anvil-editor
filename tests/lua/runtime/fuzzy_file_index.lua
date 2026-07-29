local fuzzy = require "fuzzy"
local test = require "core.test"

local function path(value)
  return value:gsub("/", PATHSEP)
end

test.describe("Native fuzzy file index", function()
  test.it("ingests chunked multi-root scanner output and returns activation metadata", function()
    local builder = fuzzy.file_index_builder {
      {
        path = path("C:/project"),
        label = "project",
        role = "root",
        id = "root",
        rank_penalty = 0,
        mappings = {
          {
            relative_prefix = path("vendor/lib"),
            label = "library",
            role = "vendored",
            id = "vendor-library",
            rank_penalty = 75,
          },
        },
      },
      {
        path = path("C:/external"),
        label = "Java Sources",
        role = "external",
        id = "java",
        rank_penalty = 150,
      },
    }

    builder:feed(1, "./src/main.cpp\0vendor/lib/foo.cpp\0src/main.cpp\0part")
    builder:feed(1, "ial.cpp\0")
    builder:feed(2, "java/String.java\0")
    local index, stats = builder:finish()

    test.equal(stats.candidates, 5)
    test.equal(stats.accepted, 4)
    test.equal(stats.duplicates, 1)
    test.equal(#index, 4)

    local results = index:search("String", { limit = 10, spans = true })
    test.equal(#results, 1)
    test.equal(results[1].text, path("Java Sources/java/String.java"))
    test.equal(results[1].relative_path, path("java/String.java"))
    test.equal(results[1].root_path, path("C:/external"))
    test.equal(results[1].root_role, "external")
    test.equal(results[1].root_id, "java")
    test.equal(results[1].rank_penalty, 150)
    test.same(results[1].prefix_span, { 1, #"Java Sources" })
    test.ok(#results[1].spans > 0)

    local vendored
    for i = 1, #index do
      local entry = index:entry(i)
      if entry.root_role == "vendored" then vendored = entry end
    end
    test.not_nil(vendored)
    test.equal(vendored.text, path("library/foo.cpp"))
    test.equal(vendored.relative_path, path("vendor/lib/foo.cpp"))
    test.equal(vendored.root_id, "vendor-library")
    index:free()
  end)
end)
