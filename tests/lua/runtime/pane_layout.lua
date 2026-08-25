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
