local panes = require "core.panes"
local core = require "core"
local View = require "core.view"
local test = require "core.test"

local FakeView = View:extend()

function FakeView:new(name)
  FakeView.super.new(self)
  self.name = name
end

function FakeView:get_name()
  return self.name
end

function FakeView:try_close(close)
  close()
end

local function factory(name)
  return function() return FakeView(name) end
end

local function names(values)
  local result = {}
  for _, pane in ipairs(values) do result[#result + 1] = pane.current_view:get_name() end
  return result
end

test.describe("Pane manager", function()
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

  test.it("accepts zero Panes", function()
    test.equal(panes.count(), 0)
    test.same(panes.ordered(), {})
    test.is_nil(panes.active())
    test.is_nil(panes.visible_group())
    test.ok(panes.validate())
  end)

  test.it("creates Pane 1 in one group", function()
    local first = panes.create { factory = factory("one") }
    test.equal(panes.count(), 1)
    test.equal(panes.number(first), 1)
    test.equal(first.current_view:get_name(), "one")
    test.equal(panes.active(), first)
    test.equal(panes.visible_group(), first.group)
    test.same(names(panes.ordered()), { "one" })
    test.ok(panes.validate())
  end)

  test.it("appends each new Pane as a singleton group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    test.same(names(panes.ordered()), { "one", "two" })
    test.equal(panes.number(one), 1)
    test.equal(panes.number(two), 2)
    test.not_equal(one.group, two.group)
  end)

  test.it("splits next to the source in deterministic order", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local zero = panes.split(one, "left", { factory = factory("zero") })
    test.same(names(panes.ordered()), { "zero", "one", "two" })
    test.equal(one.group, two.group)
    test.equal(one.group, zero.group)
    test.equal(panes.visible_group(), one.group)
  end)

  test.it("focuses one member while presenting its complete group", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.split(one, "right", { factory = factory("two") })
    local three = panes.create { factory = factory("three") }
    panes.focus(one)
    test.equal(panes.visible_group(), one.group)
    panes.focus(two)
    test.equal(panes.visible_group(), one.group)
    test.equal(panes.active(), two)
    panes.focus(three)
    test.equal(panes.visible_group(), three.group)
  end)

  test.it("focuses Panes by current number", function()
    panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    test.equal(panes.focus_index(2), two)
    test.equal(panes.active(), two)
  end)

  test.it("renumbers after closing and permits zero Panes", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local three = panes.create { factory = factory("three") }
    test.ok(panes.close(two))
    test.same(names(panes.ordered()), { "one", "three" })
    test.equal(panes.number(three), 2)
    test.ok(panes.close(one))
    test.ok(panes.close(three))
    test.equal(panes.count(), 0)
    test.is_nil(panes.active())
    test.is_nil(panes.visible_group())
  end)

  test.it("rejects duplicate Pane membership", function()
    local one = panes.create { factory = factory("one") }
    local group = one.group
    group.root = {
      kind = "split", axis = "x", ratio = 0.5,
      a = { kind = "pane", pane = one },
      b = { kind = "pane", pane = one },
    }
    test.not_ok(pcall(panes.validate))
  end)

  test.it("removes focus-target ownership when its View closes", function()
    local pane = panes.create { factory = factory("one") }
    local child = FakeView("child")
    panes.register_focus_target(pane.current_view, child)
    test.equal(panes.pane_for_view(child), pane)
    panes.close(pane, { force = true })
    test.is_nil(panes.pane_for_view(child))
    test.ok(panes.validate())
  end)

  test.it("clears a closed final Pane View from global focus", function()
    local pane = panes.create { factory = factory("one") }
    core.active_view = pane.current_view
    local clear_active_view = core.clear_active_view
    core.clear_active_view = function(view)
      if core.active_view == view then core.active_view = nil; return true end
      return false
    end
    panes.close(pane, { force = true })
    core.clear_active_view = clear_active_view
    test.is_nil(core.active_view)
  end)

  test.it("closes the Current View and restores the previous View", function()
    local pane = panes.create { factory = factory("one") }
    local first = pane.current_view
    local second = FakeView("two")
    function second:on_close() self.closed = (self.closed or 0) + 1 end
    panes.present(second, { pane = pane })

    test.ok(panes.close_view(pane, { force = true }))
    test.equal(pane.current_view, first)
    test.equal(panes.history_length(pane), 1)
    test.equal(second.closed, 1)
  end)
end)
