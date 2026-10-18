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


  test.it("finalizes an immutable fuzzy snapshot off the Lua thread", function()
    local builder = fuzzy.file_index_builder {
      { path = path("C:/project"), label = "project", role = "root", id = "root" },
    }
    local chunks = {}
    for i = 1, 10000 do chunks[i] = string.format("src/file_%05d.cpp\0", i) end
    builder:feed(1, table.concat(chunks))

    local task = builder:finish_async()
    local index, stats
    local deadline = system.get_time() + 5
    repeat
      index, stats = task:poll()
      if not index then coroutine.yield(0.001) end
    until index or system.get_time() >= deadline

    test.not_nil(index, "native file-index finalization did not complete")
    test.equal(stats.accepted, 10000)
    test.equal(#index, 10000)
    test.equal(#index:search("file_10000", { limit = 5 }), 1)
    index:free()
  end)

  local function wait_search(task)
    local deadline = system.get_time() + 5
    local results
    repeat
      results = task:poll()
      if not results then coroutine.yield(0.001) end
    until results or system.get_time() >= deadline
    return results
  end

  local function numbered_index(count)
    local builder = fuzzy.file_index_builder {
      { path = path("C:/project"), label = "project", role = "root", id = "root" },
    }
    local chunks = {}
    for i = 1, count do chunks[i] = string.format("src/file_%05d.cpp\0", i) end
    builder:feed(1, table.concat(chunks))
    return builder:finish()
  end

  test.it("searches off the Lua thread with the same results as a direct search", function()
    local index = numbered_index(2000)
    local options = { limit = 20, spans = true }
    local expected = index:search("file_01", options)

    local results = wait_search(index:search_async("file_01", options))

    test.not_nil(results, "native file search did not complete")
    test.same(results, expected)
    test.equal(results.has_more, expected.has_more)
    index:free()
  end)

  test.it("completes a search that started before its index was freed", function()
    local index = numbered_index(20000)
    local options = { limit = 5, spans = true }
    local expected = index:search("file_19999", options)
    local task = index:search_async("file_19999", options)
    index:free()

    local results = wait_search(task)

    test.not_nil(results, "native file search did not complete")
    test.equal(#results, 1)
    test.same(results, expected)
  end)
end)
