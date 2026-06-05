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

test.describe("core.doc batch edit primitive", function()
  test.it("applies a single replacement and reports inverse edits", function()
    local doc = Doc()
    set_text(doc, "abc")

    local tx = doc:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 3, text = "X" },
    }, { type = "replace" })

    test.ok(tx.applied)
    test.ok(tx.changed)
    test.equal(text(doc), "aXc\n")
    test.same(tx.inverse_edits, {
      { line1 = 1, col1 = 2, line2 = 1, col2 = 3, text = "b" },
    })
  end)

  test.it("applies multiple original-coordinate edits simultaneously", function()
    local doc = Doc()
    set_text(doc, "abc\ndef\nghi")

    local tx = doc:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 3, text = "X" },
      { line1 = 2, col1 = 2, line2 = 2, col2 = 3, text = "Y" },
      { line1 = 3, col1 = 2, line2 = 3, col2 = 3, text = "Z" },
    }, { type = "batch" })

    test.ok(tx.applied)
    test.equal(text(doc), "aXc\ndYf\ngZi\n")
    test.equal(#tx.edits, 3)
    test.equal(#tx.inverse_edits, 3)
  end)

  test.it("rejects overlapping edits atomically", function()
    local doc = Doc()
    set_text(doc, "abcdef")
    local before_change_id = doc:get_change_id()
    local before_selections = { table.unpack(doc.selections) }

    local tx = doc:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 5, text = "X" },
      { line1 = 1, col1 = 4, line2 = 1, col2 = 6, text = "Y" },
    })

    test.not_ok(tx.applied)
    test.ok(tx.rejected)
    test.equal(text(doc), "abcdef\n")
    test.same(doc.selections, before_selections)
    test.equal(doc:get_change_id(), before_change_id)
  end)

  test.it("rejects duplicate zero-width inserts at the same position", function()
    local doc = Doc()
    set_text(doc, "abc")

    local tx = doc:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 2, text = "X" },
      { line1 = 1, col1 = 2, line2 = 1, col2 = 2, text = "Y" },
    })

    test.not_ok(tx.applied)
    test.equal(text(doc), "abc\n")
  end)

  test.it("runs the internal transaction hook even when public notification is suppressed", function()
    local doc = Doc()
    set_text(doc, "abc")
    local transactions = {}
    local changes = {}
    function doc:on_text_transaction(tx)
      transactions[#transactions + 1] = tx
    end
    function doc:on_text_change(change_type, tx)
      changes[#changes + 1] = { change_type, tx }
    end

    local tx = doc:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 2, text = "X" },
    }, { type = "insert", notify = false })

    test.ok(tx.applied)
    test.equal(text(doc), "aXbc\n")
    test.equal(#transactions, 1)
    test.equal(transactions[1], tx)
    test.equal(#changes, 0)
  end)

  test.it("previews final selections after batch edits", function()
    local doc = Doc()
    set_text(doc, "a b c")
    doc.selections = {
      1, 1, 1, 1,
      1, 3, 1, 3,
      1, 5, 1, 5,
    }

    local edits = {
      { idx = 1, line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "10" },
      { idx = 2, line1 = 1, col1 = 3, line2 = 1, col2 = 3, text = "15" },
      { idx = 3, line1 = 1, col1 = 5, line2 = 1, col2 = 5, text = "20" },
    }
    local final_by_idx = { "end", "end", "end" }

    test.same(doc:selections_after_edits(edits, final_by_idx), {
      1, 3, 1, 3,
      1, 7, 1, 7,
      1, 11, 1, 11,
    })
    test.equal(text(doc), "a b c\n")
  end)

  test.it("uses explicit final selections and creates one undoable transaction", function()
    local doc = Doc()
    set_text(doc, "abc\ndef")
    local changes = {}
    function doc:on_text_change(change_type, tx)
      changes[#changes + 1] = { change_type, tx and #tx.edits or 0 }
    end

    doc:apply_edits({
      { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "X" },
      { line1 = 2, col1 = 1, line2 = 2, col2 = 1, text = "Y" },
    }, {
      type = "text-input",
      selections = { 1, 2, 1, 2, 2, 2, 2, 2 },
      last_selection = 2,
    })

    test.equal(text(doc), "Xabc\nYdef\n")
    test.same(doc.selections, { 1, 2, 1, 2, 2, 2, 2, 2 })
    test.equal(doc.last_selection, 2)
    test.same(changes, { { "text-input", 2 } })
    test.equal(doc.undo_stack.idx, 2)

    doc:undo()
    test.equal(text(doc), "abc\ndef\n")
    test.same(doc.selections, { 1, 1, 1, 1 })

    doc:redo()
    test.equal(text(doc), "Xabc\nYdef\n")
    test.same(doc.selections, { 1, 2, 1, 2, 2, 2, 2, 2 })
  end)
end)
