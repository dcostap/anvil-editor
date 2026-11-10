local test = require "core.test"
local layout = require "core.ui.layout"

local px = layout.px

-- A node with a natural size, at scale 1. Unlike a fixed `width`, a natural width can shrink and grow.
local Box = layout.Node:extend()

function Box:new(options)
  Box.super.new(self, options)
  self.natural_w, self.natural_h = options.w or 0, options.h or 0
end

function Box:content_width() return px(self.natural_w) end
function Box:content_height() return px(self.natural_h) end

local function place(node, w, h)
  node:place(0, 0, px(w), px(h or node:height(px(w)) / SCALE))
  return node
end

-- The rect of `node` at scale 1, rounded, so the checks do not depend on the display scale.
local function rect(node)
  local function v(value) return math.floor(value / SCALE + 0.5) end
  return { v(node.x), v(node.y), v(node.w), v(node.h) }
end

test.describe("Dialog layout", function()
  test.it("shares a row's free width by grow weight, within each child's limits", function()
    local a, b, c = Box { w = 40, h = 10 }, Box { grow = 2, h = 10 }, Box { grow = 1, h = 10 }
    place(layout.Row { gap = 0, a, b, c }, 340)
    test.same({ rect(a)[3], rect(b)[3], rect(c)[3] }, { 40, 200, 100 })

    local capped, rest = Box { grow = 1, max_width = 50, h = 10 }, Box { grow = 1, h = 10 }
    place(layout.Row { gap = 0, capped, rest }, 300)
    test.same({ rect(capped)[3], rect(rest)[3] }, { 50, 250 })
  end)

  test.it("shrinks a row's children in proportion to their widths, but not below their minimums", function()
    local a, b = Box { w = 100, h = 10 }, Box { w = 300, h = 10 }
    place(layout.Row { gap = 0, a, b }, 200)
    test.same({ rect(a)[3], rect(b)[3] }, { 50, 150 })

    local firm, soft = Box { w = 100, min_width = 90, h = 10 }, Box { w = 100, h = 10 }
    place(layout.Row { gap = 0, firm, soft }, 150)
    test.same({ rect(firm)[3], rect(soft)[3] }, { 90, 60 })
  end)

  test.it("places a row's children with justify and align inside its padding", function()
    local a, b = Box { w = 20, h = 10 }, Box { w = 30, h = 30 }
    local row = layout.Row { gap = 10, padding = { 5, 20 }, justify = "end", align = "end", a, b }
    test.equal(row:width(), px(20 + 10 + 30 + 40))
    test.equal(row:height(px(200)), px(40))
    place(row, 200)
    test.same(rect(a), { 120, 25, 20, 10 })
    test.same(rect(b), { 150, 5, 30, 30 })

    row.justify, row.align = "between", "stretch"
    place(row, 200)
    test.same(rect(a), { 20, 5, 20, 30 })
    test.same(rect(b), { 150, 5, 30, 30 })

    row.justify, row.align = "center", "start"
    place(row, 200)
    test.same(rect(a), { 70, 5, 20, 10 })
  end)

  test.it("keeps a child's size limits in each cross-axis alignment", function()
    local wide, tall = Box { width = 200, h = 10 }, Box { w = 10, h = 5, min_height = 30 }
    place(layout.Column { align = "start", wide }, 100)
    test.equal(rect(wide)[3], 200)
    place(layout.Row { align = "start", tall }, 100, 20)
    test.equal(rect(tall)[4], 30)
  end)

  test.it("grows a column's children into its height, so a spacer pushes a footer down", function()
    local body, footer = Box { w = 50, h = 40 }, Box { w = 80, h = 20 }
    local column = layout.Column { gap = 0, align = "center", body, layout.Spacer { grow = 1 }, footer }
    test.equal(column:height(px(200)), px(60))
    place(column, 200, 300)
    test.same(rect(body), { 75, 0, 50, 40 })
    test.same(rect(footer), { 60, 280, 80, 20 })
  end)

  test.it("sizes a long list to the height of its measure", function()
    local rows = {}
    for i = 1, 20 do rows[i] = { name = tostring(i) } end
    local list = require("core.ui.list") { rows = rows, row_height = 10 }
    test.equal(list:height(px(200)), 80)
  end)

  test.it("gives a scroll's child at least the scroll's height", function()
    local footer = Box { w = 10, h = 20 }
    local scroll = layout.Scroll { height = 300, layout.Column { gap = 0, layout.Spacer { grow = 1 }, footer } }
    place(scroll, 200, 300)
    test.ok(footer.y + footer.h >= px(290), "the footer sits at the bottom of the scroll")
    test.equal(scroll:max_scroll(), 0)
  end)

  test.it("scrolls a control child with the wheel, and gives a hidden child no space", function()
    local button = require("core.ui.button") { label = "OK" }
    local scroll = place(layout.Scroll { height = 10, button }, 200)
    test.ok(scroll:on_wheel(5, 5, -1), "a control taller than the scroll scrolls")

    local hidden = Box { w = 10, h = 40, visible = false }
    local empty = layout.Scroll { hidden }
    test.equal(empty:height(px(200)), 0)
    place(empty, 200)
    local list = {}
    empty:collect(list)
    test.equal(#list, 0)
    test.not_ok(empty:on_wheel(5, 5, -1))
  end)

  test.it("wraps text again when its font changes size in place", function()
    local words = string.rep("word ", 40)
    local text = layout.Text { text = words }
    local font = require("core.ui").role_font("body")
    local size = font:get_size()
    text:height(px(200))
    font:set_size(size * 2)
    local after, fresh = text:height(px(200)), layout.Text({ text = words }):height(px(200))
    font:set_size(size)
    test.equal(after, fresh)
  end)
end)
