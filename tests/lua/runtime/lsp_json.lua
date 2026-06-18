local test = require "core.test"
local lsp_json = require "core.lsp.json"

test.describe("core.lsp.json", function()
  test.test("encodes explicit empty arrays and objects", function()
    local encoded = lsp_json.encode(lsp_json.object({
      empty_array = lsp_json.array({}),
      empty_object = lsp_json.object({}),
    }))
    test.contains(encoded, '"empty_array":[]')
    test.contains(encoded, '"empty_object":{}')
  end)

  test.test("raw empty tables default to objects", function()
    test.equal(lsp_json.encode({}), "{}")
    test.equal(lsp_json.encode(lsp_json.array({})), "[]")
  end)

  test.test("preserves explicit null values when decoding objects and arrays", function()
    local decoded, err = lsp_json.decode([[{"value":null,"items":[null]}]])
    test.not_nil(decoded, err)
    test.ok(lsp_json.is_null(decoded.value))
    test.ok(lsp_json.is_null(decoded.items[1]))
    test.ok(lsp_json.is_array(decoded.items))
    test.ok(lsp_json.is_object(decoded))
  end)

  test.test("round-trips decoded empty array and object shapes", function()
    local decoded = test.not_nil(lsp_json.decode([[{"array":[],"object":{}}]]))
    test.ok(lsp_json.is_array(decoded.array))
    test.ok(lsp_json.is_object(decoded.object))
    local encoded = lsp_json.encode(decoded)
    test.contains(encoded, '"array":[]')
    test.contains(encoded, '"object":{}')
  end)

  test.test("preserves string and numeric request id types", function()
    local numeric = test.not_nil(lsp_json.decode([[{"jsonrpc":"2.0","id":7,"result":null}]]))
    test.equal(type(numeric.id), "number")
    test.equal(numeric.id, 7)
    test.ok(lsp_json.is_null(numeric.result))

    local string_id = test.not_nil(lsp_json.decode([[{"jsonrpc":"2.0","id":"7","result":null}]]))
    test.equal(type(string_id.id), "string")
    test.equal(string_id.id, "7")
  end)
end)
