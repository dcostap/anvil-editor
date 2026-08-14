local core = require "core"
local panes = require "core.panes"
local View = require "core.view"
local test = require "core.test"

local HistoryView = View:extend()
function HistoryView:new(name)
  HistoryView.super.new(self)
  self.name = name
  self.suspends = 0
  self.resumes = 0
  self.closes = 0
end
function HistoryView:get_name() return self.name end
function HistoryView:on_suspend() self.suspends = self.suspends + 1 end
function HistoryView:on_resume() self.resumes = self.resumes + 1 end
function HistoryView:try_close(close)
  self.closes = self.closes + 1
  close()
end

local function make(name) return HistoryView(name) end
local function factory(name) return function() return make(name) end end

test.describe("Pane View history", function()
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

  test.it("suspends displaced Views and resumes them with Back and Forward", function()
    local pane = panes.create { factory = factory("one") }
    local one = pane.current_view
    local two = make("two")
    panes.present(two, { pane = pane })
    test.equal(pane.current_view, two)
    test.equal(one.suspends, 1)
    test.equal(two.resumes, 1)

    test.equal(panes.back(pane), one)
    test.equal(two.suspends, 1)
    test.equal(one.resumes, 1)
    test.equal(panes.forward(pane), two)
    test.equal(two.resumes, 2)
  end)

  test.it("keeps history independent for each Pane", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local one_next = make("one-next")
    local two_next = make("two-next")
    panes.present(one_next, { pane = one })
    panes.present(two_next, { pane = two })
    test.equal(panes.back(one):get_name(), "one")
    test.equal(two.current_view, two_next)
    test.equal(panes.back(two):get_name(), "two")
  end)

  test.it("revisits an owned View without duplicating its live instance", function()
    local pane = panes.create { factory = factory("one") }
    local one = pane.current_view
    panes.present(make("two"), { pane = pane })
    panes.present(one, { pane = pane })
    test.equal(pane.current_view, one)
    test.equal(#panes.history_views(pane), 2)
  end)

  test.it("does not make one View Current in two Panes", function()
    local one = panes.create { factory = factory("one") }
    local shared = one.current_view
    local two = panes.create { factory = factory("two") }
    local result, err = panes.present(shared, { pane = two })
    test.is_nil(result)
    test.ok(err)
    test.equal(one.current_view, shared)
    test.not_equal(two.current_view, shared)
  end)

  test.it("prunes the oldest suspended Views at the history bound", function()
    local pane = panes.create { factory = factory("one"), history_limit = 3 }
    local one = pane.current_view
    panes.present(make("two"), { pane = pane })
    panes.present(make("three"), { pane = pane })
    panes.present(make("four"), { pane = pane })
    local views = panes.history_views(pane)
    test.equal(#views, 3)
    test.equal(views[1]:get_name(), "two")
    test.is_nil(one.__pane_owner)
  end)

  test.it("closes Current and retained Views before removing a Pane", function()
    local pane = panes.create { factory = factory("one") }
    local one = pane.current_view
    local two = make("two")
    panes.present(two, { pane = pane })
    test.ok(panes.close(pane))
    test.equal(one.closes, 1)
    test.equal(two.closes, 1)
    test.equal(panes.count(), 0)
  end)
end)
