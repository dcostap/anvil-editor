local Buffer = require "core.buffer"
local test = require "core.test"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  if #buffer.lines == 0 then buffer.lines[1] = "\n" end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function text(buffer)
  return table.concat(buffer.lines)
end

local function set_selections(buffer, selections, last_selection)
  buffer.selections = {}
  for i = 1, #selections, 4 do
    buffer:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, i == 1 and nil or 0)
  end
  buffer.last_selection = last_selection or 1
end

test.describe("core.buffer edit behavior characterization", function()
  test.it("inserts and removes multiline text while preserving line table invariants", function()
    local buffer = Buffer()

    buffer:insert(1, 1, "abc\ndef")
    test.equal(text(buffer), "abc\ndef\n")
    test.equal(#buffer.lines, 2)
    test.equal(buffer.lines[1], "abc\n")
    test.equal(buffer.lines[2], "def\n")

    buffer:remove(1, 2, 2, 3)
    test.equal(text(buffer), "af\n")
    test.equal(#buffer.lines, 1)
    test.equal(buffer.lines[1], "af\n")
  end)

  test.it("types at multiple collapsed carets from bottom to top", function()
    local buffer = Buffer()
    set_text(buffer, "one\ntwo")
    set_selections(buffer, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })

    buffer:text_input("X")

    test.equal(text(buffer), "Xone\nXtwo\n")
    test.same(buffer.selections, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
  end)

  test.it("typing replaces multiple selected ranges and leaves carets after replacements", function()
    local buffer = Buffer()
    set_text(buffer, "abc def")
    set_selections(buffer, {
      1, 1, 1, 4,
      1, 5, 1, 8,
    })

    buffer:text_input("X")

    test.equal(text(buffer), "X X\n")
    test.same(buffer.selections, {
      1, 2, 1, 2,
      1, 4, 1, 4,
    })
  end)

  test.it("IME editing inserts at multiple collapsed carets and selects the composing text backwards", function()
    local buffer = Buffer()
    set_text(buffer, "one\ntwo")
    set_selections(buffer, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })

    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    buffer:ime_text_editing("X", 0, 0)

    test.equal(text(buffer), "Xone\nXtwo\n")
    test.equal(changes, 1)
    test.same(buffer.selections, {
      1, 2, 1, 1,
      2, 2, 2, 1,
    })
  end)

  test.it("IME editing replaces multiple selected ranges", function()
    local buffer = Buffer()
    set_text(buffer, "abc def")
    set_selections(buffer, {
      1, 1, 1, 4,
      1, 5, 1, 8,
    })

    buffer:ime_text_editing("X", 0, 0)

    test.equal(text(buffer), "X X\n")
    test.same(buffer.selections, {
      1, 2, 1, 1,
      1, 4, 1, 3,
    })
  end)

  test.it("IME editing keeps the final selection anchor at the composition start", function()
    local buffer = Buffer()
    set_text(buffer, "abc")
    buffer:set_selection(1, 2, 1, 2)

    buffer:ime_text_editing("XY", 0, 0)

    test.equal(text(buffer), "aXYbc\n")
    test.same(buffer.selections, { 1, 4, 1, 2 })
  end)

  test.it("typing overlapping selected ranges lets later selections own the overlap", function()
    local buffer = Buffer()
    set_text(buffer, "abcdefghij")
    set_selections(buffer, {
      1, 1, 1, 7,
      1, 4, 1, 9,
    })

    buffer:text_input("X")

    test.equal(text(buffer), "XXij\n")
    test.same(buffer.selections, {
      1, 2, 1, 2,
      1, 3, 1, 3,
    })
  end)

  test.it("typing handles mixed collapsed carets and selected ranges in one edit", function()
    local buffer = Buffer()
    set_text(buffer, "abc def ghi\none two three")
    set_selections(buffer, {
      1, 1, 1, 4, -- selected abc
      1, 5, 1, 5, -- collapsed before def
      2, 5, 2, 8, -- selected two
    })

    buffer:text_input("X")

    test.equal(text(buffer), "X Xdef ghi\none X three\n")
    test.same(buffer.selections, {
      1, 2, 1, 2,
      1, 4, 1, 4,
      2, 6, 2, 6,
    })
  end)

  test.it("undo and redo restore mixed collapsed carets and selected ranges", function()
    local buffer = Buffer()
    set_text(buffer, "abc def ghi\none two three")
    set_selections(buffer, {
      1, 1, 1, 4,
      1, 5, 1, 5,
      2, 5, 2, 8,
    })
    local before_selections = { table.unpack(buffer.selections) }

    buffer:text_input("X")
    buffer:undo()

    test.equal(text(buffer), "abc def ghi\none two three\n")
    test.same(buffer.selections, before_selections)

    buffer:redo()
    test.equal(text(buffer), "X Xdef ghi\none X three\n")
    test.same(buffer.selections, {
      1, 2, 1, 2,
      1, 4, 1, 4,
      2, 6, 2, 6,
    })
  end)

  test.it("typing replaces multiple multiline selections", function()
    local buffer = Buffer()
    set_text(buffer, "aa\nbb\ncc\ndd\nee")
    set_selections(buffer, {
      1, 1, 3, 1, -- aa\nbb\n
      4, 1, 5, 1, -- dd\n
    })

    buffer:text_input("X")

    test.equal(text(buffer), "Xcc\nXee\n")
    test.same(buffer.selections, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
  end)

  test.it("delete_to handles mixed selected ranges and collapsed carets", function()
    local buffer = Buffer()
    set_text(buffer, "abcdef\nuvwxyz")
    set_selections(buffer, {
      1, 2, 1, 4, -- selected bc
      1, 6, 1, 6, -- collapsed after e, before f
      2, 1, 2, 3, -- selected uv
    })

    buffer:delete_to(-1)

    test.equal(text(buffer), "adf\nwxyz\n")
    test.same(buffer.selections, {
      1, 2, 1, 2,
      1, 3, 1, 3,
      2, 1, 2, 1,
    })
  end)

  test.it("moving multiple carets through a varied buffer then typing edits at the moved positions", function()
    local buffer = Buffer()
    set_text(buffer, "alpha\nb\ncharlie delta\necho")
    set_selections(buffer, {
      1, 1, 1, 1,
      2, 2, 2, 2,
      3, 9, 3, 9,
    })

    buffer:move_to(2)
    test.same(buffer.selections, {
      1, 3, 1, 3,
      3, 2, 3, 2,
      3, 11, 3, 11,
    })

    buffer:text_input("X")

    test.equal(text(buffer), "alXpha\nb\ncXharlie deXlta\necho\n")
    test.same(buffer.selections, {
      1, 4, 1, 4,
      3, 3, 3, 3,
      3, 13, 3, 13,
    })
  end)

  test.it("selecting from multiple carets and typing replaces the movement-created ranges", function()
    local buffer = Buffer()
    set_text(buffer, "abcdef\nuvwxyz")
    set_selections(buffer, {
      1, 2, 1, 2,
      2, 3, 2, 3,
    })

    buffer:select_to(2)
    test.same(buffer.selections, {
      1, 4, 1, 2,
      2, 5, 2, 3,
    })

    buffer:text_input("X")

    test.equal(text(buffer), "aXdef\nuvXyz\n")
    test.same(buffer.selections, {
      1, 3, 1, 3,
      2, 4, 2, 4,
    })
  end)

  test.it("movement clamps and merges duplicate carets at buffer boundaries", function()
    local buffer = Buffer()
    set_text(buffer, "abc")
    set_selections(buffer, {
      1, 1, 1, 1,
      1, 2, 1, 2,
    })

    buffer:move_to(-1)

    test.same(buffer.selections, { 1, 1, 1, 1 })
    test.equal(buffer.last_selection, 1)
  end)

  test.it("merge_cursors keeps first caret and maps active duplicate to survivor", function()
    local buffer = Buffer()
    set_text(buffer, "abc\nxyz")
    set_selections(buffer, {
      1, 2, 1, 2,
      1, 2, 1, 4,
      2, 1, 2, 1,
      1, 2, 1, 2,
    }, 4)

    buffer:merge_cursors()

    test.same(buffer.selections, {
      1, 2, 1, 2,
      2, 1, 2, 1,
    })
    test.equal(buffer.last_selection, 1)
  end)

  test.it("merge_cursors with an index only merges the targeted cursor", function()
    local buffer = Buffer()
    set_text(buffer, "abc\nxyz")
    set_selections(buffer, {
      1, 1, 1, 1,
      2, 1, 2, 1,
      1, 1, 1, 1,
      2, 1, 2, 1,
    }, 4)

    buffer:merge_cursors(3)

    test.same(buffer.selections, {
      1, 1, 1, 1,
      2, 1, 2, 1,
      2, 1, 2, 1,
    })
    test.equal(buffer.last_selection, 3)
  end)

  test.it("full merge_cursors avoids repeated splice removals", function()
    local buffer = Buffer()
    local common = require "core.common"
    set_text(buffer, "abc")
    buffer.selections = {}
    for i = 1, 64 do
      buffer.selections[#buffer.selections + 1] = 1
      buffer.selections[#buffer.selections + 1] = 1 + (i % 3)
      buffer.selections[#buffer.selections + 1] = 1
      buffer.selections[#buffer.selections + 1] = 1 + (i % 3)
    end
    buffer.last_selection = 64

    local original_splice = common.splice
    local splices = 0
    common.splice = function(...)
      splices = splices + 1
      return original_splice(...)
    end
    local ok, err = pcall(function()
      buffer:merge_cursors()
      test.equal(splices, 0)
      test.same(buffer.selections, {
        1, 2, 1, 2,
        1, 3, 1, 3,
        1, 1, 1, 1,
      })
      test.equal(buffer.last_selection, 1)
    end)
    common.splice = original_splice
    if not ok then error(err) end
  end)

  test.it("overwrite mode replaces the next character for single-character text input", function()
    local buffer = Buffer()
    set_text(buffer, "abcd")
    buffer:set_selection(1, 2, 1, 2)
    buffer.overwrite = true

    buffer:text_input("Z")

    test.equal(text(buffer), "aZcd\n")
    test.same(buffer.selections, { 1, 3, 1, 3 })
  end)

  test.it("delete_to removes selected ranges or translated collapsed ranges and merges duplicate cursors", function()
    local buffer = Buffer()
    set_text(buffer, "abcd")
    set_selections(buffer, {
      1, 2, 1, 2,
      1, 4, 1, 4,
    })

    buffer:delete_to(-1)

    test.equal(text(buffer), "bd\n")
    test.same(buffer.selections, {
      1, 1, 1, 1,
      1, 2, 1, 2,
    })
  end)

  test.it("insert after undo marks the buffer dirty instead of reusing the old clean change id", function()
    local buffer = Buffer()
    set_text(buffer, "abc")
    buffer:insert(1, 4, "X")
    buffer:clean()

    buffer:undo()
    buffer:insert(1, 1, "Y")

    test.equal(text(buffer), "Yabc\n")
    test.ok(buffer:is_dirty())
  end)

  test.it("remove after undo marks the buffer dirty instead of reusing the old clean change id", function()
    local buffer = Buffer()
    set_text(buffer, "abc")
    buffer:insert(1, 4, "X")
    buffer:clean()

    buffer:undo()
    buffer:remove(1, 1, 1, 2)

    test.equal(text(buffer), "bc\n")
    test.ok(buffer:is_dirty())
  end)

  test.it("undo and redo restore text for a timestamp-merged multi-caret text input", function()
    local buffer = Buffer()
    set_text(buffer, "one\ntwo")
    set_selections(buffer, {
      1, 1, 1, 1,
      2, 1, 2, 1,
    })
    local before_selections = { table.unpack(buffer.selections) }

    buffer:text_input("X")
    test.equal(text(buffer), "Xone\nXtwo\n")

    buffer:undo()
    test.equal(text(buffer), "one\ntwo\n")
    test.same(buffer.selections, before_selections)

    buffer:redo()
    test.equal(text(buffer), "Xone\nXtwo\n")
    test.same(buffer.selections, {
      1, 2, 1, 2,
      2, 2, 2, 2,
    })
  end)

  test.it("replace returns per-selection results and transforms selected text", function()
    local buffer = Buffer()
    set_text(buffer, "one two")
    set_selections(buffer, {
      1, 1, 1, 4,
      1, 5, 1, 8,
    })

    local results = buffer:replace(function(old)
      return old:upper(), #old
    end)

    test.equal(text(buffer), "ONE TWO\n")
    test.same(results, { 3, 3 })
    test.same(buffer.selections, {
      1, 1, 1, 1,
      1, 5, 1, 5,
    })
  end)

  test.it("replace transforms the whole buffer when there is no selection", function()
    local buffer = Buffer()
    set_text(buffer, "one\ntwo")
    buffer:set_selection(1, 2, 1, 2)

    local results = buffer:replace(function(old)
      return old:gsub("o", "O"), #old
    end)

    test.equal(text(buffer), "One\ntwO\n")
    test.same(results, { 7 })
    test.same(buffer.selections, { 1, 1, 1, 1 })
  end)

  test.it("replace handles different-length selected replacements in one buffer change", function()
    local buffer = Buffer()
    set_text(buffer, "aa bb cc")
    set_selections(buffer, {
      1, 1, 1, 3,
      1, 4, 1, 6,
      1, 7, 1, 9,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    local results = buffer:replace(function(old)
      return old == "aa" and "A" or old == "bb" and "BBBB" or "C", old
    end)

    test.equal(text(buffer), "A BBBB C\n")
    test.same(results, { "aa", "bb", "cc" })
    test.equal(changes, 1)
    test.same(buffer.selections, {
      1, 1, 1, 1,
      1, 3, 1, 3,
      1, 8, 1, 8,
    })
  end)

  test.it("replace with unchanged text returns results without changing the buffer", function()
    local buffer = Buffer()
    set_text(buffer, "one two")
    set_selections(buffer, {
      1, 1, 1, 4,
      1, 5, 1, 8,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end
    local before_selections = { table.unpack(buffer.selections) }

    local results = buffer:replace(function(old)
      return old, #old
    end)

    test.equal(text(buffer), "one two\n")
    test.same(results, { 3, 3 })
    test.equal(changes, 0)
    test.same(buffer.selections, before_selections)
  end)

  test.it("replace_cursor replaces a selected range and returns the callback result", function()
    local buffer = Buffer()
    set_text(buffer, "abc def")
    buffer:set_selection(1, 1, 1, 4)

    local result = buffer:replace_cursor(1, 1, 1, 1, 4, function(old)
      return old:upper(), #old
    end)

    test.equal(text(buffer), "ABC def\n")
    test.equal(result, 3)
    test.same(buffer.selections, { 1, 1, 1, 1 })
  end)

  test.it("replace_cursor selects inserted text for a collapsed cursor replacement", function()
    local buffer = Buffer()
    set_text(buffer, "abc")
    buffer:set_selection(1, 2, 1, 2)

    buffer:replace_cursor(1, 1, 2, 1, 2, function()
      return "XY"
    end)

    test.equal(text(buffer), "aXYbc\n")
    test.same(buffer.selections, { 1, 2, 1, 4 })
  end)
end)
