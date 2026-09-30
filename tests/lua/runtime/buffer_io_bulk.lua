local test = require "core.test"

test.it("splits file text without adding a line after the final newline", function()
  local cases = {
    { "", { "\n" }, {} },
    { "one", { "one\n" }, { false } },
    { "one\n", { "one\n" }, { false } },
    { "one\n\n", { "one\n", "\n" }, { false, false } },
    { "one\r\ntwo\r", { "one\n", "two\n" }, { false, false }, true },
    { "é\n", { "é\n" }, { false } },
  }
  for _, case in ipairs(cases) do
    local lines, clean, highlights, crlf, binary = encoding.split_lines(case[1])
    test.same(lines, case[2])
    test.same(clean, {})
    test.same(highlights, case[3])
    test.equal(crlf, case[4] or false)
    test.equal(binary, false)
  end
end)

test.it("keeps invalid source bytes and supplies a clean display line", function()
  local lines, clean, _, crlf, binary = encoding.split_lines("a\255\128b\n")
  test.same(lines, { "a\255\128b\n" })
  test.same(clean, { "a\26\26b\n" })
  test.equal(crlf, false)
  test.equal(binary, true)
end)
