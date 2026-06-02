local test = require "core.test"

test.describe("string utf8 wrappers", function()
  test.test("handles UTF-8 strings by characters instead of bytes", function()
    test.equal(string.ulen("e"), 1)
    test.equal(string.ulen("e\204\129"), 2)
    test.equal(string.uchar(233), "é")
    test.equal(string.usub("héllo", 2, 4), "éll")
    test.equal(string.uinsert("hllo", 2, "e"), "hello")
    test.equal(string.uremove("héllo", 2, 4), "ho")
    test.equal(string.uoffset("éλ", 2), 3)
    test.equal(string.ulower("HELLO"), "hello")
    test.equal(string.uupper("hello"), "HELLO")
    test.equal(string.uncasecmp("Hello", "hello"), 0)
  end)

  test.test("supports matching and replacement helpers", function()
    local start_idx, end_idx = string.ufind("hello", "ll")
    test.equal(start_idx, 3)
    test.equal(end_idx, 4)

    local pieces = {}
    for part in string.ugmatch("a,b,c", "[^,]+") do
      table.insert(pieces, part)
    end
    test.same(pieces, {"a", "b", "c"})

    local replaced, count = string.ugsub("héllo", "é", "a", 1)
    test.equal(replaced, "hallo")
    test.equal(count, 1)
    test.equal(string.umatch("hello", "h(.*)o"), "ell")
  end)

  test.test("cleans invalid utf8 and normalizes basic text", function()
    local invalid = "\255abc"
    local cleaned, valid = string.uclean(invalid, "?")
    test.equal(cleaned, "?abc")
    test.not_ok(valid)
    test.equal(string.uinvalidoffset(invalid), 1)
    test.ok(string.uisvalid("héllo"))
    test.ok(string.uisnfc("Cafe"))

    local normalized, already_normal = string.unormalize_nfc("Cafe")
    test.equal(normalized, "Cafe")
    test.ok(already_normal)
  end)
end)

test.describe("utf8extra", function()
  test.test("provides codepoint and iterator helpers", function()
    local text = utf8extra.char(233, 955)
    test.equal(text, "éλ")

    local cp1, cp2 = utf8extra.codepoint(text, 1, -1, true)
    test.equal(cp1, 233)
    test.equal(cp2, 955)

    local seen = {}
    for pos, codepoint in utf8extra.codes(text, true) do
      table.insert(seen, {pos, codepoint})
    end
    test.same(seen, {{1, 233}, {3, 955}})
  end)

  test.test("supports escaping, indexing and width helpers", function()
    test.equal(utf8extra.escape("%u{233}%u{955}"), "éλ")

    local pos, codepoint = utf8extra.charpos("éλ", 1, 1)
    test.equal(pos, 3)
    test.equal(codepoint, 955)

    local next_pos, next_codepoint = utf8extra.next("éλ", 1)
    test.equal(next_pos, 3)
    test.equal(next_codepoint, 955)

    local width = utf8extra.width("ab")
    test.equal(width, 2)

    local idx, offset, glyph_width = utf8extra.widthindex("ab", 2)
    test.equal(idx, 2)
    test.equal(offset, 1)
    test.equal(glyph_width, 1)
  end)
end)
