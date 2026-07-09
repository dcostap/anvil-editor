local test = require "core.test"
local codec = require "core.treesitter.artifact_codec"

test.describe("Tree-sitter artifact codec", function()
  test.it("round-trips framed Project index data without Lua source loading", function()
    local payload = {
      files = {
        {
          path = "C:/Project/src/Thing.kt",
          fingerprint = "10\0query",
          symbols = { { name = "Thing", start_line = 2, declaration = "class Thing" } },
          usages_by_name = {
            Thing = {
              { path = "C:/Project/src/Thing.kt", start_line = 4, is_declaration = false },
            },
          },
          usage_complete = true,
        },
      },
    }
    local encoded = codec.encode(payload)
    test.equal(encoded:sub(1, 8), "ANVILTS1")
    test.not_ok(encoded:find("return", 1, true))
    local decoded, err = codec.decode(encoded)
    test.not_nil(decoded, err)
    test.same(decoded, payload)
  end)

  test.it("rejects malformed and trailing artifact data", function()
    local value, reason = codec.decode("return {}")
    test.is_nil(value)
    test.equal(reason, "invalid-header")
    value, reason = codec.decode(codec.encode({ ok = true }) .. "junk")
    test.is_nil(value)
    test.equal(reason, "trailing-data")
  end)
end)
