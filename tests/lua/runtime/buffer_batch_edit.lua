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

test.describe("core.buffer batch edit primitive", function()
  test.it("applies a single replacement and reports inverse edits", function()
    local buffer = Buffer()
    set_text(buffer, "abc")

    local tx = buffer:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 3, text = "X" },
    }, { type = "replace" })

    test.ok(tx.applied)
    test.ok(tx.changed)
    test.equal(text(buffer), "aXc\n")
    test.same(tx.inverse_edits, {
      { line1 = 1, col1 = 2, line2 = 1, col2 = 3, text = "b" },
    })
  end)

  test.it("applies multiple original-coordinate edits simultaneously", function()
    local buffer = Buffer()
    set_text(buffer, "abc\ndef\nghi")

    local tx = buffer:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 3, text = "X" },
      { line1 = 2, col1 = 2, line2 = 2, col2 = 3, text = "Y" },
      { line1 = 3, col1 = 2, line2 = 3, col2 = 3, text = "Z" },
    }, { type = "batch" })

    test.ok(tx.applied)
    test.equal(text(buffer), "aXc\ndYf\ngZi\n")
    test.equal(#tx.edits, 3)
    test.equal(#tx.inverse_edits, 3)
  end)

  test.it("rejects overlapping edits atomically", function()
    local buffer = Buffer()
    set_text(buffer, "abcdef")
    local before_change_id = buffer:get_change_id()
    local before_selections = { table.unpack(buffer.selections) }

    local tx = buffer:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 5, text = "X" },
      { line1 = 1, col1 = 4, line2 = 1, col2 = 6, text = "Y" },
    })

    test.not_ok(tx.applied)
    test.ok(tx.rejected)
    test.equal(text(buffer), "abcdef\n")
    test.same(buffer.selections, before_selections)
    test.equal(buffer:get_change_id(), before_change_id)
  end)

  test.it("rejects duplicate zero-width inserts at the same position", function()
    local buffer = Buffer()
    set_text(buffer, "abc")

    local tx = buffer:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 2, text = "X" },
      { line1 = 1, col1 = 2, line2 = 1, col2 = 2, text = "Y" },
    })

    test.not_ok(tx.applied)
    test.equal(text(buffer), "abc\n")
  end)

  test.it("runs the internal transaction hook even when public notification is suppressed", function()
    local buffer = Buffer()
    set_text(buffer, "abc")
    local transactions = {}
    local changes = {}
    function buffer:on_text_transaction(tx)
      transactions[#transactions + 1] = tx
    end
    function buffer:on_text_change(change_type, tx)
      changes[#changes + 1] = { change_type, tx }
    end

    local tx = buffer:apply_edits({
      { line1 = 1, col1 = 2, line2 = 1, col2 = 2, text = "X" },
    }, { type = "insert", notify = false })

    test.ok(tx.applied)
    test.equal(text(buffer), "aXbc\n")
    test.equal(#transactions, 1)
    test.equal(transactions[1], tx)
    test.equal(#changes, 0)
  end)

  test.it("previews final selections after batch edits", function()
    local buffer = Buffer()
    set_text(buffer, "a b c")
    buffer.selections = {
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

    test.same(buffer:selections_after_edits(edits, final_by_idx), {
      1, 3, 1, 3,
      1, 7, 1, 7,
      1, 11, 1, 11,
    })
    test.equal(text(buffer), "a b c\n")
  end)

  test.it("uses explicit final selections and creates one undoable transaction", function()
    local buffer = Buffer()
    set_text(buffer, "abc\ndef")
    local changes = {}
    function buffer:on_text_change(change_type, tx)
      changes[#changes + 1] = { change_type, tx and #tx.edits or 0 }
    end

    buffer:apply_edits({
      { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "X" },
      { line1 = 2, col1 = 1, line2 = 2, col2 = 1, text = "Y" },
    }, {
      type = "text-input",
      selections = { 1, 2, 1, 2, 2, 2, 2, 2 },
      last_selection = 2,
    })

    test.equal(text(buffer), "Xabc\nYdef\n")
    test.same(buffer.selections, { 1, 2, 1, 2, 2, 2, 2, 2 })
    test.equal(buffer.last_selection, 2)
    test.same(changes, { { "text-input", 2 } })
    test.equal(buffer.undo_stack.idx, 2)

    buffer:undo()
    test.equal(text(buffer), "abc\ndef\n")
    test.same(buffer.selections, { 1, 1, 1, 1 })

    buffer:redo()
    test.equal(text(buffer), "Xabc\nYdef\n")
    test.same(buffer.selections, { 1, 2, 1, 2, 2, 2, 2, 2 })
  end)
end)
