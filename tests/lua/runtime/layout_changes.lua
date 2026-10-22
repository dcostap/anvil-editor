local layout_changes = require "core.layout_changes"
local test = require "core.test"

local function region(old1, old2, new1, new2)
  return { old1 = old1, old2 = old2, new1 = new1, new2 = new2 }
end

test.describe("Layout changes", function()
  test.it("moves a later edit by the lines that an earlier edit added", function()
    -- A line break at the end of line 100, then a letter on line 200.
    local changes = layout_changes.compose(
      { region(100, 100, 100, 101) }, { region(201, 201, 201, 201) })
    test.same(changes, { region(100, 100, 100, 101), region(200, 200, 201, 201) })
  end)

  test.it("joins edits that touch the same lines", function()
    -- Three line breaks at the end of line 10, one after the other.
    local changes = { region(10, 10, 10, 11) }
    changes = layout_changes.compose(changes, { region(11, 11, 11, 12) })
    changes = layout_changes.compose(changes, { region(12, 12, 12, 13) })
    test.same(changes, { region(10, 10, 10, 13) })
    test.equal(layout_changes.total_delta(changes), 3)
  end)

  test.it("maps an edit before an earlier change without joining them", function()
    -- Delete line 50, then add a line after line 5.
    local changes = layout_changes.compose(
      { region(49, 50, 49, 49) }, { region(5, 5, 5, 6) })
    test.same(changes, { region(5, 5, 5, 6), region(49, 50, 50, 50) })
  end)

  test.it("undoes a line break into an unchanged span", function()
    local changes = layout_changes.compose(
      { region(7, 7, 7, 8) }, { region(7, 8, 7, 7) })
    test.same(changes, { region(7, 7, 7, 7) })
  end)

  test.it("covers lines between two changes that a third change spans", function()
    local changes = layout_changes.compose(
      { region(10, 10, 10, 11), region(20, 20, 21, 21) },
      layout_changes.span(11, 21))
    test.same(changes, { region(10, 20, 10, 21) })
  end)

  test.it("joins overlapping spans in any order", function()
    test.same(layout_changes.spans({ { 30, 32 }, { 5, 8 }, { 7, 12 } }),
      { region(5, 12, 5, 12), region(30, 32, 30, 32) })
  end)

  test.it("keeps the edits of one multi-caret transaction apart", function()
    local changes = layout_changes.from_transaction({ changed_ranges = {
      { old_line1 = 10, old_line2 = 10, new_line1 = 10, new_line2 = 10 },
      { old_line1 = 50, old_line2 = 50, new_line1 = 50, new_line2 = 51 },
      { old_line1 = 90, old_line2 = 90, new_line1 = 91, new_line2 = 91 },
    } })
    changes = layout_changes.compose({ region(70, 70, 70, 70) }, changes)
    test.same(changes, {
      region(10, 10, 10, 10), region(50, 50, 50, 51),
      region(70, 70, 71, 71), region(90, 90, 91, 91),
    })
  end)

  test.it("maps a position past the regions before it", function()
    -- Rows 5..6 become one row, and rows 20..20 become three rows.
    local changes = { region(5, 6, 5, 5), region(20, 20, 19, 21) }
    test.equal(layout_changes.map(changes, 4), 4)
    test.equal(layout_changes.map(changes, 6), nil)
    test.equal(layout_changes.map(changes, 10), 9)
    test.equal(layout_changes.map(changes, 20), nil)
    test.equal(layout_changes.map(changes, 30), 31)
  end)
end)
