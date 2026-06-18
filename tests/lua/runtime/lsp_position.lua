local test = require "core.test"
local position = require "core.lsp.position"

local function fake_doc(lines)
  return {
    lines = lines,
    get_utf8_line = function(self, line)
      return self.lines[line]
    end,
  }
end

test.describe("core.lsp.position", function()
  test.test("converts ASCII doc positions to default UTF-16 LSP positions", function()
    local doc = fake_doc({ "abc\n", "def\n" })
    test.same(position.doc_to_lsp(doc, 1, 1), { line = 0, character = 0 })
    test.same(position.doc_to_lsp(doc, 1, 4), { line = 0, character = 3 })
    test.same(position.doc_to_lsp(doc, 2, 2), { line = 1, character = 1 })

    local line, col = position.lsp_to_doc(doc, { line = 0, character = 3 })
    test.equal(line, 1)
    test.equal(col, 4)
  end)

  test.test("uses UTF-8 byte offsets when requested", function()
    local doc = fake_doc({ "aé😀b\n" })
    test.same(position.doc_to_lsp(doc, 1, 8, "utf-8"), { line = 0, character = 7 })
    local line, col = position.lsp_to_doc(doc, { line = 0, character = 7 }, "utf-8")
    test.equal(line, 1)
    test.equal(col, 8)
  end)

  test.test("converts multibyte UTF-8 to UTF-16 code units", function()
    local doc = fake_doc({ "aéb\n" })
    test.same(position.doc_to_lsp(doc, 1, 2), { line = 0, character = 1 })
    test.same(position.doc_to_lsp(doc, 1, 4), { line = 0, character = 2 })
    test.same(position.doc_to_lsp(doc, 1, 5), { line = 0, character = 3 })

    local line, col = position.lsp_to_doc(doc, { line = 0, character = 2 })
    test.equal(line, 1)
    test.equal(col, 4)
  end)

  test.test("counts astral codepoints as UTF-16 surrogate pairs", function()
    local doc = fake_doc({ "a😀b\n" })
    test.same(position.doc_to_lsp(doc, 1, 2), { line = 0, character = 1 })
    test.same(position.doc_to_lsp(doc, 1, 6), { line = 0, character = 3 })
    test.same(position.doc_to_lsp(doc, 1, 7), { line = 0, character = 4 })

    local line, col = position.lsp_to_doc(doc, { line = 0, character = 3 })
    test.equal(line, 1)
    test.equal(col, 6)
  end)

  test.test("clips doc positions outside line bounds before converting to LSP", function()
    local doc = fake_doc({ "abc\n", "x\n" })
    test.same(position.doc_to_lsp(doc, -5, -10), { line = 0, character = 0 })
    test.same(position.doc_to_lsp(doc, 20, 200), { line = 1, character = 1 })
  end)

  test.test("clips invalid and out-of-range LSP positions safely", function()
    local doc = fake_doc({ "abc\n", "x\n" })
    local line, col = position.lsp_to_doc(doc, { line = -10, character = -2 })
    test.equal(line, 1)
    test.equal(col, 1)

    line, col = position.lsp_to_doc(doc, { line = 99, character = 999 })
    test.equal(line, 2)
    test.equal(col, 2)

    line, col = position.lsp_to_doc(doc, { line = 0 / 0, character = 0 / 0 })
    test.equal(line, 1)
    test.equal(col, 1)
  end)

  test.test("handles positions inside a UTF-16 surrogate pair according to bias", function()
    local doc = fake_doc({ "a😀b\n" })
    local line, col = position.lsp_to_doc(doc, { line = 0, character = 2 })
    test.equal(line, 1)
    test.equal(col, 2)

    line, col = position.lsp_to_doc(doc, { line = 0, character = 2 }, "utf-16", "right")
    test.equal(line, 1)
    test.equal(col, 6)
  end)

  test.test("converts ranges between doc and LSP shapes", function()
    local doc = fake_doc({ "abc\n", "déf\n" })
    local lsp_range = position.range_doc_to_lsp(doc, { 1, 2, 2, 4 })
    test.same(lsp_range, {
      start = { line = 0, character = 1 },
      ["end"] = { line = 1, character = 2 },
    })

    local doc_range = position.range_lsp_to_doc(doc, lsp_range)
    test.equal(doc_range.line1, 1)
    test.equal(doc_range.col1, 2)
    test.equal(doc_range.line2, 2)
    test.equal(doc_range.col2, 4)
  end)

  test.test("does not count LF-normalized line endings as LSP characters", function()
    local doc = fake_doc({ "abc\n" })
    test.same(position.doc_to_lsp(doc, 1, 4), { line = 0, character = 3 })
    local line, col = position.lsp_to_doc(doc, { line = 0, character = 100 })
    test.equal(line, 1)
    test.equal(col, 4)
  end)
end)
