local core = require "core"
local layout = require "core.pane_layout"
local panes = require "core.panes"
local View = require "core.view"
local test = require "core.test"

local NamedView = View:extend()
function NamedView:new(name)
  NamedView.super.new(self)
  self.name = name
end
function NamedView:get_name() return self.name end
local function factory(name) return function() return NamedView(name) end end
local function names()
  local result = {}
  for _, pane in ipairs(panes.ordered()) do result[#result + 1] = pane.current_view:get_name() end
  return result
end

test.describe("Pane navigation and movement", function()
  local set_active_view

  test.before_each(function()
    panes.reset_for_tests()
    set_active_view = core.set_active_view
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = set_active_view
  end)

  test.it("focuses geometric neighbors inside the visible group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local three = panes.split(one, "down", { factory = factory("three") })
    layout.update_rects(one.group.root, { x = 0, y = 0, w = 300, h = 200 })
    panes.focus(one)
    test.equal(panes.focus_direction("right"), two)
    panes.focus(one)
    test.equal(panes.focus_direction("down"), three)
  end)

  test.it("moves a singleton Pane into another Pane Group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    test.equal(#panes.groups, 2)
    test.equal(panes.move(two, one, "right"), two)
    test.equal(#panes.groups, 1)
    test.equal(one.group, two.group)
    test.same(names(), { "one", "two" })
    test.equal(panes.number(two), 2)
  end)

  test.it("moves a Pane within one split layout", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local three = panes.split(two, "right", { factory = factory("three") })
    panes.move(three, one, "left")
    test.same(names(), { "three", "one", "two" })
    test.equal(three.group, one.group)
  end)

  test.it("detaches one Pane as a new singleton group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    panes.detach(one)
    test.equal(#panes.groups, 2)
    test.not_equal(one.group, two.group)
    test.same(names(), { "two", "one" })
  end)

  test.it("uses edge drop zones to move a Pane", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    panes.focus(one)
    layout.update_rects(one.group.root, { x = 0, y = 0, w = 200, h = 100 })
    local target, direction = panes.drop_target_at(190, 50)
    test.equal(target, one)
    test.equal(direction, "right")
    test.equal(panes.drop(two, 190, 50), two)
    test.same(names(), { "one", "two" })
  end)

  test.it("does not mutate layout when a split factory fails", function()
    local one = panes.create { factory = factory("one") }
    local before = layout.serialize(one.group.root)
    local result, err = panes.split(one, "right", {
      factory = function() error("factory failed") end,
    })
    test.is_nil(result)
    test.ok(err:find("factory failed", 1, true))
    test.same(layout.serialize(one.group.root), before)
    test.same(names(), { "one" })
  end)
end)
