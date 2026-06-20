local Doc = require "core.doc"
local range_marker = require "core.range_marker"
local test = require "core.test"

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_doc(text)
  local doc = Doc()
  set_text(doc, text or "")
  return doc
end

local function assert_range(marker, line1, col1, line2, col2)
  local range = marker:range()
  test.not_nil(range)
  test.equal(range.line1, line1)
  test.equal(range.col1, col1)
  test.equal(range.line2, line2)
  test.equal(range.col2, col2)
end

test.describe("core.range_marker", function()
  test.it("shifts ranges when inserting before them", function()
    local doc = new_doc("abcdef")
    local marker = range_marker.new(doc, { line1 = 1, col1 = 3, line2 = 1, col2 = 6 })

    doc:insert(1, 1, "xx")

    assert_range(marker, 1, 5, 1, 8)
  end)

  test.it("shifts ranges back when deleting before them", function()
    local doc = new_doc("xxabcdef")
    local marker = range_marker.new(doc, { line1 = 1, col1 = 5, line2 = 1, col2 = 8 })

    doc:remove(1, 1, 1, 3)

    assert_range(marker, 1, 3, 1, 6)
  end)

  test.it("expands ranges when inserting inside them", function()
    local doc = new_doc("abcdef")
    local marker = range_marker.new(doc, { line1 = 1, col1 = 2, line2 = 1, col2 = 5 })

    doc:insert(1, 3, "xx")

    assert_range(marker, 1, 2, 1, 7)
  end)

  test.it("shifts sticky-right-on-newline ranges at start boundary newline insertions", function()
    local doc = new_doc("abc\ndef")
    local marker = range_marker.new(doc, {
      line1 = 2, col1 = 1, line2 = 2, col2 = 4,
      greedy_left = true, greedy_right = true, sticky_right_on_newline = true,
    })

    doc:insert(2, 1, "\n")

    assert_range(marker, 3, 1, 3, 4)
  end)

  test.it("still expands greedy ranges at start boundary same-line insertions", function()
    local doc = new_doc("abcdef")
    local marker = range_marker.new(doc, {
      line1 = 1, col1 = 3, line2 = 1, col2 = 5,
      greedy_left = true, greedy_right = true, sticky_right_on_newline = true,
    })

    doc:insert(1, 3, "x")

    assert_range(marker, 1, 3, 1, 6)
  end)

  test.it("respects greediness at insertion boundaries", function()
    local doc = new_doc("abcdef")
    local plain = range_marker.new(doc, { line1 = 1, col1 = 3, line2 = 1, col2 = 5 })
    local greedy = range_marker.new(doc, { line1 = 1, col1 = 3, line2 = 1, col2 = 5, greedy_left = true, greedy_right = true })

    doc:insert(1, 3, "x")
    assert_range(plain, 1, 4, 1, 6)
    assert_range(greedy, 1, 3, 1, 6)

    doc:insert(1, 6, "y")
    assert_range(plain, 1, 4, 1, 6)
    assert_range(greedy, 1, 3, 1, 7)
  end)

  test.it("clips ranges when deletion overlaps one side", function()
    local doc = new_doc("abcdef")
    local marker = range_marker.new(doc, { line1 = 1, col1 = 3, line2 = 1, col2 = 6 })

    doc:remove(1, 1, 1, 4)

    assert_range(marker, 1, 1, 1, 3)
  end)

  test.it("invalidates ranges consumed by an edit", function()
    local doc = new_doc("abcdef")
    local marker = range_marker.new(doc, { line1 = 1, col1 = 3, line2 = 1, col2 = 6 })

    doc:remove(1, 2, 1, 6)

    test.not_ok(marker:is_valid())
  end)

  test.it("preserves opted-in ranges consumed by whole-text replacement when text remains", function()
    local doc = new_doc("one\nproblem\nthree")
    local marker = range_marker.new(doc, {
      line1 = 2, col1 = 1, line2 = 2, col2 = 8,
      preserve_on_replace = true,
    })

    doc:apply_edits({
      { line1 = 1, col1 = 1, line2 = 3, col2 = 6, text = "zero\none\nproblem\nthree" },
    })

    test.ok(marker:is_valid())
    assert_range(marker, 3, 1, 3, 8)
  end)

  test.it("tracks multi-line ranges through line inserts and deletes", function()
    local doc = new_doc("one\ntwo\nthree")
    local marker = range_marker.new(doc, { line1 = 2, col1 = 1, line2 = 3, col2 = 6 })

    doc:insert(1, 1, "zero\n")
    assert_range(marker, 3, 1, 4, 6)

    doc:remove(2, 1, 3, 1)
    assert_range(marker, 2, 1, 3, 6)
  end)

  test.it("applies batch edits in normalized order", function()
    local doc = new_doc("abcdef")
    local marker = range_marker.new(doc, { line1 = 1, col1 = 3, line2 = 1, col2 = 5 })

    doc:apply_edits({
      { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "x" },
      { line1 = 1, col1 = 7, line2 = 1, col2 = 7, text = "y" },
    })

    assert_range(marker, 1, 4, 1, 6)
  end)
end)
