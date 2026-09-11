local test = require "core.test"

test.describe("Search Modifiers", function()
  test.it("extracts stacked modifiers without changing quoted search text", function()
    local modifiers = require "plugins.fuzzy_searcher.modifiers"
    local result = modifiers.parse('commit:abcdef12 src/ #"size:20m" size:>=10k sort:name')
    test.equal(result.text, 'src/ #"size:20m"')
    test.equal(result.commit, "abcdef12")
    test.equal(result.sort, "name")
    test.equal(result.error, nil)
    test.equal(#result.tokens, 3)
    test.equal(result.tokens[1].first, 1)
    test.equal(result.tokens[1].last, 15)
    test.ok(modifiers.accepts(result, { size = 10240, type = "file" }))
    test.not_ok(modifiers.accepts(result, { size = 10239, type = "file" }))
  end)

  test.it("matches a size bucket and compares exact byte limits", function()
    local modifiers = require "plugins.fuzzy_searcher.modifiers"
    for _, text in ipairs { "size:20m", "size:20mb", "SIZE:20MB" } do
      local query = modifiers.parse(text)
      test.ok(modifiers.accepts(query, { size = 20971520, type = "file" }))
      test.ok(modifiers.accepts(query, { size = 22020095, type = "file" }))
      test.not_ok(modifiers.accepts(query, { size = 20971519, type = "file" }))
      test.not_ok(modifiers.accepts(query, { size = 22020096, type = "file" }))
      test.not_ok(modifiers.accepts(query, { size = 20971520, type = "dir" }))
    end
    local query = modifiers.parse("size:>=10k size:<20k")
    test.ok(modifiers.accepts(query, { size = 10240, type = "file" }))
    test.ok(modifiers.accepts(query, { size = 20479, type = "file" }))
    test.not_ok(modifiers.accepts(query, { size = 20480, type = "file" }))
  end)

  test.it("keeps paths, unknown tokens, and shell text literal", function()
    local modifiers = require "plugins.fuzzy_searcher.modifiers"
    for _, text in ipairs {
      'C:\\src\\file.lua:20', 'https://example.com', 'other:value',
      '!echo size:20m', '>editor:open sort:name', '#"size:20m"',
    } do
      local query = modifiers.parse(text)
      test.equal(query.text, text)
      test.not_ok(query.active)
    end
    local query = modifiers.parse('#size:<10k word sort:name')
    test.equal(query.text, "#word")
    test.equal(query.mode, "#")
    test.equal(query.marker_first, 1)
  end)

  test.it("reports incomplete, conflicting, and unsupported modifiers", function()
    local modifiers = require "plugins.fuzzy_searcher.modifiers"
    for _, text in ipairs {
      'size:', 'size:many', 'size:99999999999999999m', 'sort:other', 'commit:HEAD',
      'sort:size sort:name', 'commit:abcdef commit:fedcba',
      'commit:abcdef sort:date', 'commit:abcdef @file', '$name size:10k',
    } do
      local query = modifiers.parse(text)
      test.ok(query.active, text)
      test.ok(query.error, text)
    end
    test.not_ok(modifiers.parse('size:').tokens[1].valid)
  end)
end)
