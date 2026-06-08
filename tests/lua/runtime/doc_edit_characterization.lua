local Doc = require "core.doc"
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

local function text(doc)
  return table.concat(doc.lines)
end

local function set_selections(doc, selections, last_selection)
  doc.selections = {}
  for i = 1, #selections, 4 do
    doc:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, i == 1 and nil or 0)
  end
  doc.last_selection = last_selection or 1
end

test.describe("core.doc edit behavior characterization", function()
  test.it("inserts and removes multiline text while preserving line table invariants", function()
    local doc = Doc()

    doc:insert(1, 1, "abc\ndef")
    test.equal(text(doc), "abc\ndef\n")
    test.equal(#doc.lines, 2)
    test.equal(doc.lines[1], "abc\n")
    test.equal(doc.lines[2], "def\n")

    doc:remove(1, 2, 2, 3)
    test.equal(text(doc), "af\n")
    test.equal(#doc.lines, 1)
    test.equal(doc.lines[1], "af\n")
  end)

  test.it("types at multiple collapsed carets from bottom to top", function()
    local doc = Doc()
    set_text(doc, "one\ntwo")
    set_selections(doc, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })

    doc:text_input("X")

    test.equal(text(doc), "Xone\nXtwo\n")
    test.same(doc.selections, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
  end)

  test.it("typing replaces multiple selected ranges and leaves carets after replacements", function()
    local doc = Doc()
    set_text(doc, "abc def")
    set_selections(doc, {
      1, 1, 1, 4,
      1, 5, 1, 8,
    })

    doc:text_input("X")

    test.equal(text(doc), "X X\n")
    test.same(doc.selections, {
      1, 2, 1, 2,
      1, 4, 1, 4,
    })
  end)

  test.it("IME editing inserts at multiple collapsed carets and selects the composing text backwards", function()
    local doc = Doc()
    set_text(doc, "one\ntwo")
    set_selections(doc, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })

    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    doc:ime_text_editing("X", 0, 0)

    test.equal(text(doc), "Xone\nXtwo\n")
    test.equal(changes, 1)
    test.same(doc.selections, {
      1, 2, 1, 1,
      2, 2, 2, 1,
    })
  end)

  test.it("IME editing replaces multiple selected ranges", function()
    local doc = Doc()
    set_text(doc, "abc def")
    set_selections(doc, {
      1, 1, 1, 4,
      1, 5, 1, 8,
    })

    doc:ime_text_editing("X", 0, 0)

    test.equal(text(doc), "X X\n")
    test.same(doc.selections, {
      1, 2, 1, 1,
      1, 4, 1, 3,
    })
  end)

  test.it("IME editing keeps the final selection anchor at the composition start", function()
    local doc = Doc()
    set_text(doc, "abc")
    doc:set_selection(1, 2, 1, 2)

    doc:ime_text_editing("XY", 0, 0)

    test.equal(text(doc), "aXYbc\n")
    test.same(doc.selections, { 1, 4, 1, 2 })
  end)

  test.it("typing overlapping selected ranges lets later selections own the overlap", function()
    local doc = Doc()
    set_text(doc, "abcdefghij")
    set_selections(doc, {
      1, 1, 1, 7,
      1, 4, 1, 9,
    })

    doc:text_input("X")

    test.equal(text(doc), "XXij\n")
    test.same(doc.selections, {
      1, 2, 1, 2,
      1, 3, 1, 3,
    })
  end)

  test.it("typing handles mixed collapsed carets and selected ranges in one edit", function()
    local doc = Doc()
    set_text(doc, "abc def ghi\none two three")
    set_selections(doc, {
      1, 1, 1, 4, -- selected abc
      1, 5, 1, 5, -- collapsed before def
      2, 5, 2, 8, -- selected two
    })

    doc:text_input("X")

    test.equal(text(doc), "X Xdef ghi\none X three\n")
    test.same(doc.selections, {
      1, 2, 1, 2,
      1, 4, 1, 4,
      2, 6, 2, 6,
    })
  end)

  test.it("undo and redo restore mixed collapsed carets and selected ranges", function()
    local doc = Doc()
    set_text(doc, "abc def ghi\none two three")
    set_selections(doc, {
      1, 1, 1, 4,
      1, 5, 1, 5,
      2, 5, 2, 8,
    })
    local before_selections = { table.unpack(doc.selections) }

    doc:text_input("X")
    doc:undo()

    test.equal(text(doc), "abc def ghi\none two three\n")
    test.same(doc.selections, before_selections)

    doc:redo()
    test.equal(text(doc), "X Xdef ghi\none X three\n")
    test.same(doc.selections, {
      1, 2, 1, 2,
      1, 4, 1, 4,
      2, 6, 2, 6,
    })
  end)

  test.it("typing replaces multiple multiline selections", function()
    local doc = Doc()
    set_text(doc, "aa\nbb\ncc\ndd\nee")
    set_selections(doc, {
      1, 1, 3, 1, -- aa\nbb\n
      4, 1, 5, 1, -- dd\n
    })

    doc:text_input("X")

    test.equal(text(doc), "Xcc\nXee\n")
    test.same(doc.selections, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
  end)

  test.it("delete_to handles mixed selected ranges and collapsed carets", function()
    local doc = Doc()
    set_text(doc, "abcdef\nuvwxyz")
    set_selections(doc, {
      1, 2, 1, 4, -- selected bc
      1, 6, 1, 6, -- collapsed after e, before f
      2, 1, 2, 3, -- selected uv
    })

    doc:delete_to(-1)

    test.equal(text(doc), "adf\nwxyz\n")
    test.same(doc.selections, {
      1, 2, 1, 2,
      1, 3, 1, 3,
      2, 1, 2, 1,
    })
  end)

  test.it("moving multiple carets through a varied document then typing edits at the moved positions", function()
    local doc = Doc()
    set_text(doc, "alpha\nb\ncharlie delta\necho")
    set_selections(doc, {
      1, 1, 1, 1,
      2, 2, 2, 2,
      3, 9, 3, 9,
    })

    doc:move_to(2)
    test.same(doc.selections, {
      1, 3, 1, 3,
      3, 2, 3, 2,
      3, 11, 3, 11,
    })

    doc:text_input("X")

    test.equal(text(doc), "alXpha\nb\ncXharlie deXlta\necho\n")
    test.same(doc.selections, {
      1, 4, 1, 4,
      3, 3, 3, 3,
      3, 13, 3, 13,
    })
  end)

  test.it("selecting from multiple carets and typing replaces the movement-created ranges", function()
    local doc = Doc()
    set_text(doc, "abcdef\nuvwxyz")
    set_selections(doc, {
      1, 2, 1, 2,
      2, 3, 2, 3,
    })

    doc:select_to(2)
    test.same(doc.selections, {
      1, 4, 1, 2,
      2, 5, 2, 3,
    })

    doc:text_input("X")

    test.equal(text(doc), "aXdef\nuvXyz\n")
    test.same(doc.selections, {
      1, 3, 1, 3,
      2, 4, 2, 4,
    })
  end)

  test.it("movement clamps and merges duplicate carets at document boundaries", function()
    local doc = Doc()
    set_text(doc, "abc")
    set_selections(doc, {
      1, 1, 1, 1,
      1, 2, 1, 2,
    })

    doc:move_to(-1)

    test.same(doc.selections, { 1, 1, 1, 1 })
    test.equal(doc.last_selection, 1)
  end)

  test.it("merge_cursors keeps first caret and maps active duplicate to survivor", function()
    local doc = Doc()
    set_text(doc, "abc\nxyz")
    set_selections(doc, {
      1, 2, 1, 2,
      1, 2, 1, 4,
      2, 1, 2, 1,
      1, 2, 1, 2,
    }, 4)

    doc:merge_cursors()

    test.same(doc.selections, {
      1, 2, 1, 2,
      2, 1, 2, 1,
    })
    test.equal(doc.last_selection, 1)
  end)

  test.it("merge_cursors with an index only merges the targeted cursor", function()
    local doc = Doc()
    set_text(doc, "abc\nxyz")
    set_selections(doc, {
      1, 1, 1, 1,
      2, 1, 2, 1,
      1, 1, 1, 1,
      2, 1, 2, 1,
    }, 4)

    doc:merge_cursors(3)

    test.same(doc.selections, {
      1, 1, 1, 1,
      2, 1, 2, 1,
      2, 1, 2, 1,
    })
    test.equal(doc.last_selection, 3)
  end)

  test.it("full merge_cursors avoids repeated splice removals", function()
    local doc = Doc()
    local common = require "core.common"
    set_text(doc, "abc")
    doc.selections = {}
    for i = 1, 64 do
      doc.selections[#doc.selections + 1] = 1
      doc.selections[#doc.selections + 1] = 1 + (i % 3)
      doc.selections[#doc.selections + 1] = 1
      doc.selections[#doc.selections + 1] = 1 + (i % 3)
    end
    doc.last_selection = 64

    local original_splice = common.splice
    local splices = 0
    common.splice = function(...)
      splices = splices + 1
      return original_splice(...)
    end
    local ok, err = pcall(function()
      doc:merge_cursors()
      test.equal(splices, 0)
      test.same(doc.selections, {
        1, 2, 1, 2,
        1, 3, 1, 3,
        1, 1, 1, 1,
      })
      test.equal(doc.last_selection, 1)
    end)
    common.splice = original_splice
    if not ok then error(err) end
  end)

  test.it("overwrite mode replaces the next character for single-character text input", function()
    local doc = Doc()
    set_text(doc, "abcd")
    doc:set_selection(1, 2, 1, 2)
    doc.overwrite = true

    doc:text_input("Z")

    test.equal(text(doc), "aZcd\n")
    test.same(doc.selections, { 1, 3, 1, 3 })
  end)

  test.it("delete_to removes selected ranges or translated collapsed ranges and merges duplicate cursors", function()
    local doc = Doc()
    set_text(doc, "abcd")
    set_selections(doc, {
      1, 2, 1, 2,
      1, 4, 1, 4,
    })

    doc:delete_to(-1)

    test.equal(text(doc), "bd\n")
    test.same(doc.selections, {
      1, 1, 1, 1,
      1, 2, 1, 2,
    })
  end)

  test.it("insert after undo marks the document dirty instead of reusing the old clean change id", function()
    local doc = Doc()
    set_text(doc, "abc")
    doc:insert(1, 4, "X")
    doc:clean()

    doc:undo()
    doc:insert(1, 1, "Y")

    test.equal(text(doc), "Yabc\n")
    test.ok(doc:is_dirty())
  end)

  test.it("remove after undo marks the document dirty instead of reusing the old clean change id", function()
    local doc = Doc()
    set_text(doc, "abc")
    doc:insert(1, 4, "X")
    doc:clean()

    doc:undo()
    doc:remove(1, 1, 1, 2)

    test.equal(text(doc), "bc\n")
    test.ok(doc:is_dirty())
  end)

  test.it("undo and redo restore text for a timestamp-merged multi-caret text input", function()
    local doc = Doc()
    set_text(doc, "one\ntwo")
    set_selections(doc, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })
    local before_selections = { table.unpack(doc.selections) }

    doc:text_input("X")
    test.equal(text(doc), "Xone\nXtwo\n")

    doc:undo()
    test.equal(text(doc), "one\ntwo\n")
    test.same(doc.selections, before_selections)

    doc:redo()
    test.equal(text(doc), "Xone\nXtwo\n")
    test.same(doc.selections, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
  end)

  test.it("replace returns per-selection results and transforms selected text", function()
    local doc = Doc()
    set_text(doc, "one two")
    set_selections(doc, {
      1, 1, 1, 4,
      1, 5, 1, 8,
    })

    local results = doc:replace(function(old)
      return old:upper(), #old
    end)

    test.equal(text(doc), "ONE TWO\n")
    test.same(results, { 3, 3 })
    test.same(doc.selections, {
      1, 1, 1, 1,
      1, 5, 1, 5,
    })
  end)

  test.it("replace transforms the whole document when there is no selection", function()
    local doc = Doc()
    set_text(doc, "one\ntwo")
    doc:set_selection(1, 2, 1, 2)

    local results = doc:replace(function(old)
      return old:gsub("o", "O"), #old
    end)

    test.equal(text(doc), "One\ntwO\n")
    test.same(results, { 7 })
    test.same(doc.selections, { 1, 1, 1, 1 })
  end)

  test.it("replace handles different-length selected replacements in one document change", function()
    local doc = Doc()
    set_text(doc, "aa bb cc")
    set_selections(doc, {
      1, 1, 1, 3,
      1, 4, 1, 6,
      1, 7, 1, 9,
    })
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    local results = doc:replace(function(old)
      return old == "aa" and "A" or old == "bb" and "BBBB" or "C", old
    end)

    test.equal(text(doc), "A BBBB C\n")
    test.same(results, { "aa", "bb", "cc" })
    test.equal(changes, 1)
    test.same(doc.selections, {
      1, 1, 1, 1,
      1, 3, 1, 3,
      1, 8, 1, 8,
    })
  end)

  test.it("replace with unchanged text returns results without changing the document", function()
    local doc = Doc()
    set_text(doc, "one two")
    set_selections(doc, {
      1, 1, 1, 4,
      1, 5, 1, 8,
    })
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end
    local before_selections = { table.unpack(doc.selections) }

    local results = doc:replace(function(old)
      return old, #old
    end)

    test.equal(text(doc), "one two\n")
    test.same(results, { 3, 3 })
    test.equal(changes, 0)
    test.same(doc.selections, before_selections)
  end)

  test.it("replace_cursor replaces a selected range and returns the callback result", function()
    local doc = Doc()
    set_text(doc, "abc def")
    doc:set_selection(1, 1, 1, 4)

    local result = doc:replace_cursor(1, 1, 1, 1, 4, function(old)
      return old:upper(), #old
    end)

    test.equal(text(doc), "ABC def\n")
    test.equal(result, 3)
    test.same(doc.selections, { 1, 1, 1, 1 })
  end)

  test.it("replace_cursor selects inserted text for a collapsed cursor replacement", function()
    local doc = Doc()
    set_text(doc, "abc")
    doc:set_selection(1, 2, 1, 2)

    doc:replace_cursor(1, 1, 2, 1, 2, function()
      return "XY"
    end)

    test.equal(text(doc), "aXYbc\n")
    test.same(doc.selections, { 1, 2, 1, 4 })
  end)
end)
