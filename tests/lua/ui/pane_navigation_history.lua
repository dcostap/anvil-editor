local core = require "core"
local panes = require "core.panes"
local command = require "core.command"
local View = require "core.view"
local test = require "core.test"

local PlaceView = View:extend()
function PlaceView:new(name, place)
  PlaceView.super.new(self)
  self.name = name
  self.place = place or 1
end
function PlaceView:get_name() return self.name end
function PlaceView:get_navigation_state() return { place = self.place } end
function PlaceView:set_navigation_state(state) self.place = state.place end

local function factory(name, place)
  return function() return PlaceView(name, place) end
end

test.describe("Pane navigation history", function()
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

  test.it("navigates cursor places inside one Current View", function()
    local pane = panes.create { factory = factory("one", 1) }
    local view = pane.current_view
    view.place = 10
    test.ok(panes.record_location(pane))
    view.place = 20
    test.ok(panes.record_location(pane))
    test.equal(panes.back(pane), view)
    test.equal(view.place, 10)
    test.equal(panes.back(pane), view)
    test.equal(view.place, 1)
    test.equal(panes.forward(pane), view)
    test.equal(view.place, 10)
  end)

  test.it("restores a place when navigating across Views", function()
    local pane = panes.create { factory = factory("one", 4) }
    local one = pane.current_view
    one.place = 8
    panes.record_location(pane)
    local two = PlaceView("two", 30)
    panes.present(two, { pane = pane })
    two.place = 40
    panes.record_location(pane)
    test.equal(panes.back(pane), two)
    test.equal(two.place, 30)
    test.equal(panes.back(pane), one)
    test.equal(one.place, 8)
  end)

  test.it("suppresses adjacent duplicate places", function()
    local pane = panes.create { factory = factory("one", 1) }
    test.not_ok(panes.record_location(pane))
    pane.current_view.place = 2
    test.ok(panes.record_location(pane))
    test.not_ok(panes.record_location(pane))
    test.equal(panes.history_length(pane), 2)
  end)

  test.it("preserves saved places during same-View traversal", function()
    local pane = panes.create { factory = factory("one", 100) }
    local view = pane.current_view
    view.place = 300
    panes.record_location(pane)
    panes.back(pane)
    view.place = 120
    panes.forward(pane)
    panes.back(pane)
    test.equal(view.place, 100)
    panes.forward(pane)
    view.place = 320
    panes.back(pane)
    panes.forward(pane)
    test.equal(view.place, 300)
  end)

  test.it("saves the departing position when traversal changes Views", function()
    local pane = panes.create { factory = factory("one", 100) }
    local one = pane.current_view
    local two = PlaceView("two", 300)
    panes.present(two, { pane = pane })
    two.place = 320
    panes.back(pane)
    one.place = 120
    panes.forward(pane)
    test.equal(two.place, 320)
    panes.back(pane)
    test.equal(one.place, 120)
  end)

  test.it("returns to the only checkpoint after moving away", function()
    local pane = panes.create { factory = factory("one", 100) }
    pane.current_view.place = 120
    test.ok(panes.is_back_available(pane))
    test.ok(command.perform("core:navigate_back"))
    test.equal(pane.current_view.place, 100)
    test.equal(panes.history_length(pane), 1)
    test.not_ok(panes.is_back_available(pane))
  end)

  test.it("records an explicit revisit inside the Current View", function()
    local pane = panes.create { factory = factory("one", 1) }
    local view = pane.current_view
    view.place = 2

    panes.present(view, { pane = pane })

    test.equal(panes.history_length(pane), 2)
    test.equal(panes.back(pane), view)
    test.equal(view.place, 1)
    test.equal(panes.forward(pane), view)
    test.equal(view.place, 2)
  end)

  test.it("does not record ordinary edits without a navigation event", function()
    local pane = panes.create { factory = factory("one", 1) }
    pane.current_view.edits = 3
    test.equal(panes.history_length(pane), 1)
    test.is_nil(panes.back(pane))
  end)

  test.it("uses the unified Back and Forward commands", function()
    local pane = panes.create { factory = factory("one", 1) }
    pane.current_view.place = 2
    panes.record_location(pane)
    test.ok(command.perform("core:navigate_back"))
    test.equal(pane.current_view.place, 1)
    test.ok(command.perform("core:navigate_forward"))
    test.equal(pane.current_view.place, 2)
  end)
end)
