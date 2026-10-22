local layout_rows = require "layout_rows"
local test = require "core.test"

local function rows_of(heights)
  local result = {}
  for row = 1, heights:count() do
    local height, plan = heights:get(row)
    result[row] = { height, plan }
  end
  return result
end

local TEXT, FOLD, OTHER = 0, 1, 2

-- One record for each row: kind, line, last line, row in line, payload.
local function records(list)
  local result = {}
  for _, row in ipairs(list) do
    for _, value in ipairs(row) do result[#result + 1] = value end
  end
  return result
end

local function lines_of(rows)
  local result = {}
  for row = 1, rows:count() do
    local kind, line, row_in_line, payload = rows:get(row)
    result[row] = { kind, line, row_in_line, payload }
  end
  return result
end

test.describe("Layout rows", function()
  test.it("maps each line to its first text row", function()
    local rows = layout_rows.rows()
    -- Line 1 wraps to two rows. Line 2 has a provider row before its text.
    rows:replace(1, 0, records {
      { TEXT, 1, 1, 1, 0 }, { TEXT, 1, 1, 2, 0 },
      { OTHER, 2, 2, 1, 7 }, { TEXT, 2, 2, 1, 0 },
    })
    test.equal(rows:count(), 4)
    test.equal(rows:position_row(1), 1)
    test.equal(rows:position_row(2), 4)
    test.equal(rows:position_row(3), nil)
  end)

  test.it("maps every line of a fold to the fold row", function()
    local rows = layout_rows.rows()
    -- Lines 2..5 are one fold row.
    rows:replace(1, 0, records {
      { TEXT, 1, 1, 1, 0 }, { FOLD, 2, 5, 1, 3 }, { TEXT, 6, 6, 1, 0 },
    })
    test.same({ rows:position_row(2), rows:position_row(5), rows:position_row(6) }, { 2, 2, 3 })
  end)

  test.it("finds the first row of a line", function()
    local rows = layout_rows.rows()
    rows:replace(1, 0, records {
      { TEXT, 1, 1, 1, 0 }, { OTHER, 3, 3, 1, 4 }, { TEXT, 3, 3, 1, 0 }, { TEXT, 4, 4, 1, 0 },
    })
    test.equal(rows:first_row(1), 1)
    test.equal(rows:first_row(2), 2)
    test.equal(rows:first_row(3), 2)
    test.equal(rows:first_row(5), 5)
  end)

  test.it("replaces rows, moves the later lines, and returns the removed payloads", function()
    local rows = layout_rows.rows()
    rows:replace(1, 0, records {
      { TEXT, 1, 1, 1, 0 }, { OTHER, 2, 2, 1, 5 }, { TEXT, 2, 2, 1, 0 },
      { TEXT, 3, 3, 1, 0 }, { FOLD, 4, 6, 1, 6 },
    })
    -- A line break on line 2: its rows become two text rows, and later lines move by one.
    local removed = rows:replace(2, 2, records {
      { TEXT, 2, 2, 1, 0 }, { TEXT, 3, 3, 1, 0 },
    }, 1)
    test.same(removed, { 5 })
    test.same(lines_of(rows), {
      { TEXT, 1, 1, 0 }, { TEXT, 2, 1, 0 }, { TEXT, 3, 1, 0 },
      { TEXT, 4, 1, 0 }, { FOLD, 5, 1, 6 },
    })
    test.equal(rows:position_row(7), 5)
    test.equal(rows:position_row(8), nil)
  end)

  test.it("changes nothing for an incomplete record", function()
    local rows = layout_rows.rows()
    rows:replace(1, 0, records { { TEXT, 1, 1, 1, 0 } })
    test.ok(not pcall(rows.replace, rows, 1, 1, { TEXT, 1, 1 }))
    test.ok(not pcall(rows.replace, rows, 1, 1, { TEXT, "x", 1, 1, 0 }))
    test.same(lines_of(rows), { { TEXT, 1, 1, 0 } })
  end)
end)

test.describe("Layout row heights", function()
  test.it("sums the heights above each row", function()
    local heights = layout_rows.heights()
    heights:replace(1, 0, { 10, 20, 30 }, { 1, 2, 3 })
    test.equal(heights:count(), 3)
    test.equal(heights:total(), 60)
    test.equal(heights:y_offset(1), 0)
    test.equal(heights:y_offset(3), 30)
    -- The offset after the last row is the total height.
    test.equal(heights:y_offset(4), 60)
  end)

  test.it("finds the row at an offset", function()
    local heights = layout_rows.heights()
    heights:replace(1, 0, { 10, 20, 30 })
    test.equal(heights:row_at_y(-5), 1)
    test.equal(heights:row_at_y(0), 1)
    test.equal(heights:row_at_y(9.5), 1)
    -- A row starts at the sum of the heights above it.
    test.equal(heights:row_at_y(10), 2)
    test.equal(heights:row_at_y(29), 2)
    test.equal(heights:row_at_y(30), 3)
    test.equal(heights:row_at_y(1000), 3)
  end)

  test.it("replaces rows and moves the rows after them", function()
    local heights = layout_rows.heights()
    heights:replace(1, 0, { 10, 20, 30, 40 }, { 1, 2, 3, 4 })
    -- Rows 2 and 3 become three rows of 5.
    local removed = heights:replace(2, 2, { 5, 5, 5 }, { 7, 8, 9 })
    test.equal(removed, 50)
    test.same(rows_of(heights), { { 10, 1 }, { 5, 7 }, { 5, 8 }, { 5, 9 }, { 40, 4 } })
    test.equal(heights:total(), 65)
    test.equal(heights:y_offset(5), 25)
    test.equal(heights:row_at_y(25), 5)
  end)

  test.it("removes rows at the end and inserts rows at the start", function()
    local heights = layout_rows.heights()
    heights:replace(1, 0, { 10, 20, 30 })
    test.equal(heights:replace(3, 1, {}), 30)
    heights:replace(1, 0, { 1 }, { 6 })
    test.same(rows_of(heights), { { 1, 6 }, { 10, 0 }, { 20, 0 } })
    test.equal(heights:total(), 31)
  end)

  test.it("changes one height and returns the previous height", function()
    local heights = layout_rows.heights()
    heights:replace(1, 0, { 10, 20, 30 })
    test.equal(heights:y_offset(3), 30)
    test.equal(heights:set(1, 15, 4), 10)
    test.same({ heights:get(1) }, { 15, 4 })
    test.equal(heights:y_offset(3), 35)
    test.equal(heights:total(), 65)
  end)

  test.it("grows past its first allocation", function()
    local heights = layout_rows.heights()
    local values = {}
    for row = 1, 1000 do values[row] = row end
    heights:replace(1, 0, values)
    heights:replace(501, 0, values)
    test.equal(heights:count(), 2000)
    -- 1..500, then 1..1000, then 501..1000.
    test.equal(heights:total(), 500500 * 2)
    test.equal(heights:y_offset(502), 125250 + 1)
  end)

  test.it("rejects a row outside the rows", function()
    local heights = layout_rows.heights()
    heights:replace(1, 0, { 10 })
    test.ok(not pcall(heights.get, heights, 2))
    test.ok(not pcall(heights.replace, heights, 3, 0, {}))
    test.ok(not pcall(heights.replace, heights, 1, 2, {}))
  end)
end)
