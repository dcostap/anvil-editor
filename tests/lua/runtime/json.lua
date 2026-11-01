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

  test.it("gives an error for incomplete JSON", function()
    for _, text in ipairs {"[", "[1,", "{", "{\"a\":", "{\"a\":1", "[[[", "\"open"} do
      local value, err = json.decode(text)
      test.equal(value, false, text)
      test.ok(err, text)
    end
  end)

  test.it("writes a number-flagged value as a number only when it is a JSON number", function()
    for _, text in ipairs {"0", "-1", "12", "1.5", "-0.25e+3", "2E-7"} do
      test.equal(json.encode({json.number_flag .. text}), "[" .. text .. "]")
    end
    for _, text in ipairs {"+1", "01", "1.", ".5", "1e", "0x10", "- 1", "1.5.2"} do
      local encoded = json.encode({json.number_flag .. text})
      test.same(json.decode(encoded), {json.number_flag .. text})
    end
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
