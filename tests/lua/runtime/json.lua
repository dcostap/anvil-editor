local test = require "core.test"
local json = require "core.json"

test.describe("core.json", function()
  test.it("decodes large escaped strings without changing their contents", function()
    local source = string.rep("line with a \\\"quote\\\", a backslash \\\\ and a newline\\n", 5000)
    local encoded = "{\"text\":\"" .. source .. "\"}"
    local decoded = test.not_nil(json.decode(encoded))
    test.equal(decoded.text, string.rep("line with a \"quote\", a backslash \\ and a newline\n", 5000))
  end)

  test.it("decodes ordinary strings without escape fragments", function()
    local decoded = test.not_nil(json.decode([[{"text":"plain text"}]]))
    test.equal(decoded.text, "plain text")
  end)

  test.it("prettifies nested JSON with stable formatting", function()
    local formatted = json.prettify([[{"a":[1,2],"b":{}}]])
    test.equal(formatted, [[{
  "a": [
    1,
    2
  ],
  "b": {}
}]])
  end)
end)
