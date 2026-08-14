local test = require "core.test"
local position = require "core.lsp.position"

local function fake_buffer(lines)
  return {
    lines = lines,
    get_utf8_line = function(self, line)
      return self.lines[line]
    end,
  }
end

test.describe("core.lsp.position", function()
  test.test("converts ASCII buffer positions to default UTF-16 LSP positions", function()
    local buffer = fake_buffer({ "abc\n", "def\n" })
    test.same(position.buffer_to_lsp(buffer, 1, 1), { line = 0, character = 0 })
    test.same(position.buffer_to_lsp(buffer, 1, 4), { line = 0, character = 3 })
    test.same(position.buffer_to_lsp(buffer, 2, 2), { line = 1, character = 1 })

    local line, col = position.lsp_to_buffer(buffer, { line = 0, character = 3 })
    test.equal(line, 1)
    test.equal(col, 4)
  end)

  test.test("uses UTF-8 byte offsets when requested", function()
    local buffer = fake_buffer({ "aé😀b\n" })
    test.same(position.buffer_to_lsp(buffer, 1, 8, "utf-8"), { line = 0, character = 7 })
    local line, col = position.lsp_to_buffer(buffer, { line = 0, character = 7 }, "utf-8")
    test.equal(line, 1)
    test.equal(col, 8)
  end)

  test.test("converts multibyte UTF-8 to UTF-16 code units", function()
    local buffer = fake_buffer({ "aéb\n" })
    test.same(position.buffer_to_lsp(buffer, 1, 2), { line = 0, character = 1 })
    test.same(position.buffer_to_lsp(buffer, 1, 4), { line = 0, character = 2 })
    test.same(position.buffer_to_lsp(buffer, 1, 5), { line = 0, character = 3 })

    local line, col = position.lsp_to_buffer(buffer, { line = 0, character = 2 })
    test.equal(line, 1)
    test.equal(col, 4)
  end)

  test.test("counts astral codepoints as UTF-16 surrogate pairs", function()
    local buffer = fake_buffer({ "a😀b\n" })
    test.same(position.buffer_to_lsp(buffer, 1, 2), { line = 0, character = 1 })
    test.same(position.buffer_to_lsp(buffer, 1, 6), { line = 0, character = 3 })
    test.same(position.buffer_to_lsp(buffer, 1, 7), { line = 0, character = 4 })

    local line, col = position.lsp_to_buffer(buffer, { line = 0, character = 3 })
    test.equal(line, 1)
    test.equal(col, 6)
  end)

  test.test("clips buffer positions outside line bounds before converting to LSP", function()
    local buffer = fake_buffer({ "abc\n", "x\n" })
    test.same(position.buffer_to_lsp(buffer, -5, -10), { line = 0, character = 0 })
    test.same(position.buffer_to_lsp(buffer, 20, 200), { line = 1, character = 1 })
  end)

  test.test("clips invalid and out-of-range LSP positions safely", function()
    local buffer = fake_buffer({ "abc\n", "x\n" })
    local line, col = position.lsp_to_buffer(buffer, { line = -10, character = -2 })
    test.equal(line, 1)
    test.equal(col, 1)

    line, col = position.lsp_to_buffer(buffer, { line = 99, character = 999 })
    test.equal(line, 2)
    test.equal(col, 2)

    line, col = position.lsp_to_buffer(buffer, { line = 0 / 0, character = 0 / 0 })
    test.equal(line, 1)
    test.equal(col, 1)
  end)

  test.test("handles positions inside a UTF-16 surrogate pair according to bias", function()
    local buffer = fake_buffer({ "a😀b\n" })
    local line, col = position.lsp_to_buffer(buffer, { line = 0, character = 2 })
    test.equal(line, 1)
    test.equal(col, 2)

    line, col = position.lsp_to_buffer(buffer, { line = 0, character = 2 }, "utf-16", "right")
    test.equal(line, 1)
    test.equal(col, 6)
  end)

  test.test("converts ranges between buffer and LSP shapes", function()
    local buffer = fake_buffer({ "abc\n", "déf\n" })
    local lsp_range = position.range_buffer_to_lsp(buffer, { 1, 2, 2, 4 })
    test.same(lsp_range, {
      start = { line = 0, character = 1 },
      ["end"] = { line = 1, character = 2 },
    })

    local buffer_range = position.range_lsp_to_buffer(buffer, lsp_range)
    test.equal(buffer_range.line1, 1)
    test.equal(buffer_range.col1, 2)
    test.equal(buffer_range.line2, 2)
    test.equal(buffer_range.col2, 4)
  end)

  test.test("does not count LF-normalized line endings as LSP characters", function()
    local buffer = fake_buffer({ "abc\n" })
    test.same(position.buffer_to_lsp(buffer, 1, 4), { line = 0, character = 3 })
    local line, col = position.lsp_to_buffer(buffer, { line = 0, character = 100 })
    test.equal(line, 1)
    test.equal(col, 4)
  end)
end)
