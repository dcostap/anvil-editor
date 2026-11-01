local layout = require "core.pane_layout"
local test = require "core.test"

local function pane(id)
  return { id = id, position = {}, size = {} }
end

local function leaf(value)
  return { kind = "pane", pane = value }
end

local function ids(root)
  local result = {}
  for _, value in ipairs(layout.leaves(root)) do result[#result + 1] = value.id end
  return result
end

test.describe("Pane layout", function()
  test.it("returns one Pane from one leaf", function()
    local first = pane("one")
    test.same(ids(leaf(first)), { "one" })
  end)

  test.it("keeps deterministic visual order for every split direction", function()
    for _, case in ipairs {
      { direction = "left", expected = { "new", "old" } },
      { direction = "right", expected = { "old", "new" } },
      { direction = "up", expected = { "new", "old" } },
      { direction = "down", expected = { "old", "new" } },
    } do
      local old, new = pane("old"), pane("new")
      local root = layout.split(leaf(old), old, case.direction, new)
      test.same(ids(root), case.expected)
    end
  end)

  test.it("keeps nested split order", function()
    local one, two, three = pane("one"), pane("two"), pane("three")
    local root = layout.split(leaf(one), one, "right", two)
    root = layout.split(root, one, "down", three)
    test.same(ids(root), { "one", "three", "two" })
  end)

  test.it("rebalances only the axis added by a split", function()
    local one, two, three = pane("one"), pane("two"), pane("three")
    local root = layout.split(leaf(one), one, "right", two)
    root.ratio = 0.2
    root = layout.split(root, two, "down", three)
    layout.update_rects(root, { x = 0, y = 0, w = 300, h = 200 })

    test.equal(one.size.x, 60)
    test.equal(one.size.y, 200)
    test.equal(two.size.x, 240)
    test.equal(two.size.y, 100)
    test.equal(three.size.x, 240)
    test.equal(three.size.y, 100)
  end)

  test.it("collapses a removed leaf and permits an empty result", function()
    local one, two = pane("one"), pane("two")
    local root = layout.split(leaf(one), one, "right", two)
    root = layout.remove(root, one)
    test.same(ids(root), { "two" })
    test.is_nil(layout.remove(root, two))
  end)

  test.it("gives every remaining Pane equal area after removal", function()
    local one, two, three = pane("one"), pane("two"), pane("three")
    local root = layout.split(leaf(one), one, "right", two)
    root = layout.split(root, two, "right", three)
    root.ratio = 0.8

    root = layout.remove(root, three)
    layout.update_rects(root, { x = 0, y = 0, w = 200, h = 100 })

    test.equal(one.size.x, 100)
    test.equal(two.size.x, 100)
  end)

  test.it("lays out Panes and hit-tests final rectangles", function()
    local one, two = pane("one"), pane("two")
    local root = layout.split(leaf(one), one, "right", two)
    layout.update_rects(root, { x = 10, y = 20, w = 200, h = 100 })
    test.equal(one.position.x, 10)
    test.equal(one.size.x, 100)
    test.equal(two.position.x, 110)
    test.equal(two.size.x, 100)
    test.equal(layout.pane_at(root, 25, 25), one)
    test.equal(layout.pane_at(root, 175, 25), two)
  end)

  test.it("finds dividers and clamps resize ratios", function()
    local one, two = pane("one"), pane("two")
    local root = layout.split(leaf(one), one, "right", two)
    layout.update_rects(root, { x = 0, y = 0, w = 200, h = 100 })
    test.equal(layout.divider_at(root, 100, 50, 4), root)
    layout.resize(root, -100)
    test.ok(root.ratio > 0 and root.ratio < 0.5)
    layout.resize(root, 500)
    test.ok(root.ratio > 0.5 and root.ratio < 1)
  end)

  test.it("round-trips serialized shape and ratios", function()
    local one, two, three = pane("one"), pane("two"), pane("three")
    local root = layout.split(leaf(one), one, "right", two)
    root = layout.split(root, two, "down", three)
    root.ratio = 0.3
    local state = layout.serialize(root)
    local restored = layout.deserialize(state, { one = one, two = two, three = three })
    test.same(ids(restored), { "one", "two", "three" })
    test.equal(restored.ratio, 0.3)
    test.same(layout.serialize(restored), state)
  end)

  test.it("rejects duplicate Pane leaves", function()
    local one = pane("one")
    local root = { kind = "split", axis = "x", ratio = 0.5, a = leaf(one), b = leaf(one) }
    local ok = pcall(layout.validate, root)
    test.not_ok(ok)
  end)
end)

test.describe("Pane Column overflow", function()
  local function row(...)
    local values = {}
    for i, id in ipairs { ... } do values[i] = pane(id) end
    local root = leaf(values[1])
    for i = 2, #values do root = layout.split(root, values[i - 1], "right", values[i]) end
    return root, values
  end

  local function shown_ids(root)
    local result = {}
    for _, value in ipairs(layout.shown_leaves(root)) do result[#result + 1] = value.id end
    return result
  end

  local VIEW = { x = 10, y = 0, w = 400, h = 100 }

  test.it("shows every Pane Column when all columns fit the minimum width", function()
    local root = row("one", "two", "three", "four")
    test.equal(layout.update_rects(root, VIEW, { min_width = 100 }), 1)
    test.same(shown_ids(root), { "one", "two", "three", "four" })
  end)

  test.it("shows only the Pane Columns that fit and gives them the whole width", function()
    local root, p = row("one", "two", "three", "four")
    layout.update_rects(root, VIEW, { min_width = 150 })
    test.same(shown_ids(root), { "one", "two" })
    test.equal(p[1].position.x, 10)
    test.equal(p[1].size.x, 200)
    test.equal(p[2].size.x, 200)
    test.equal(layout.pane_at(root, 405, 50), p[2])
    test.is_nil(layout.pane_at(root, 415, 50))
  end)

  test.it("slides the shown Pane Columns to keep the focused Pane in view", function()
    local root, p = row("one", "two", "three", "four")
    test.equal(layout.update_rects(root, VIEW, { min_width = 150, focus = p[4] }), 3)
    test.same(shown_ids(root), { "three", "four" })
    test.equal(p[3].position.x, 10)
    test.equal(layout.update_rects(root, VIEW, { min_width = 150, first = 3, focus = p[2] }), 2)
    test.same(shown_ids(root), { "two", "three" })
    test.equal(layout.update_rects(root, VIEW, { min_width = 150, first = 2, focus = p[3] }), 2)
  end)

  test.it("shows more Pane Columns when the minimum width gets smaller", function()
    local root, p = row("one", "two", "three", "four")
    local first = layout.update_rects(root, VIEW, { min_width = 150, focus = p[4] })
    first = layout.update_rects(root, VIEW, { min_width = 120, first = first, focus = p[4] })
    test.equal(first, 2)
    test.same(shown_ids(root), { "two", "three", "four" })
    layout.update_rects(root, VIEW, { min_width = 90, first = first, focus = p[4] })
    test.same(shown_ids(root), { "one", "two", "three", "four" })
  end)

  test.it("keeps a top and bottom split as one Pane Column", function()
    local one, two = pane("one"), pane("two")
    local root = layout.split(leaf(one), one, "down", two)
    layout.update_rects(root, VIEW, { min_width = 1000 })
    test.same(shown_ids(root), { "one", "two" })
    test.equal(two.size.x, 400)
  end)

  test.it("moves a Pane Column divider between its two neighbours only", function()
    local root, p = row("one", "two", "three", "four")
    local first = layout.update_rects(root, VIEW, { min_width = 130, focus = p[4] })
    test.same(shown_ids(root), { "two", "three", "four" })
    local divider = layout.divider_at(root, p[3].position.x, 50, 3)
    test.ok(divider)
    layout.resize(divider, { x = p[3].position.x - 40, y = 50 })
    layout.update_rects(root, VIEW, { min_width = 130, first = first, focus = p[4] })
    test.equal(math.floor(p[2].size.x + 0.5), 93)
    test.equal(math.floor(p[3].size.x + 0.5), 173)
    test.equal(math.floor(p[4].size.x + 0.5), 133)
    test.equal(math.floor(p[2].position.x + p[2].size.x + 0.5), 103)
  end)

  test.it("finds no divider at the edge of the shown Pane Columns", function()
    local root, p = row("one", "two", "three", "four")
    layout.update_rects(root, VIEW, { min_width = 150 })
    test.is_nil(layout.divider_at(root, 409, 50, 3))
    test.ok(layout.divider_at(root, p[2].position.x, 50, 3))
  end)
end)
