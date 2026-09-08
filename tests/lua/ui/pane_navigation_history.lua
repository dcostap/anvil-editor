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

  test.it("opens a Buffer at its destination without a file-start stop", function()
    local Buffer = require "core.buffer"
    local RootPanel = require "core.rootpanel"
    local pane = panes.create { factory = factory("source", 4) }
    local source = pane.current_view
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, string.rep("line\n", 100))
    buffer.abs_filename = USERDIR .. PATHSEP .. "navigation-target.txt"
    local root = RootPanel()
    local view = root:open_buffer(buffer, { pane = pane, line = 80, col = 3 })
    test.equal(view:get_selection_state().selections[1], 80)
    test.equal(panes.back(pane), source)
    test.equal(panes.forward(pane), view)
    test.equal(view:get_selection_state().selections[1], 80)
    test.equal(view:get_selection_state().selections[2], 3)
    root:open_buffer(buffer, { pane = pane, line = 30, col = 2 })
    test.equal(panes.back(pane), view)
    test.equal(view:get_selection_state().selections[1], 80)
    test.equal(panes.back(pane), source)
    root:open_buffer(buffer, { pane = pane, navigate = function(target)
      target.buffer:set_selection(60, 4)
    end })
    test.equal(view:get_selection_state().selections[1], 60)
    test.equal(panes.back(pane), source)
    test.equal(panes.forward(pane), view)
    test.equal(view:get_selection_state().selections[1], 60)
  end)

  test.it("opens a new file with only its requested arrival place", function()
    local RootPanel = require "core.rootpanel"
    local pane = panes.create { factory = factory("source", 4) }
    local source = pane.current_view
    local path = USERDIR .. PATHSEP .. "navigation-arrival.txt"
    local file = assert(io.open(path, "wb"))
    file:write(string.rep("line\n", 100))
    file:close()
    local ok, err = pcall(function()
      local view = RootPanel():open_file(path, { pane = pane, line = 80, col = 2 })
      test.equal(view:get_selection_state().selections[1], 80)
      test.equal(panes.back(pane), source)
      test.equal(panes.forward(pane), view)
      test.equal(view:get_selection_state().selections[1], 80)
    end)
    os.remove(path)
    if not ok then error(err) end
  end)

  test.it("inserts a place without removing forward places in the same View", function()
    local pane = panes.create { factory = factory("A", 1) }
    local view = pane.current_view
    view.place = 2
    panes.record_location(pane)
    panes.back(pane)
    view.place = 3
    panes.record_location(pane)

    test.equal(panes.back(pane), view)
    test.equal(view.place, 1)
    panes.forward(pane)
    test.equal(view.place, 3)
    panes.forward(pane)
    test.equal(view.place, 2)
  end)

  test.it("preserves other Views and repeated visits when inserting a place", function()
    local pane = panes.create { factory = factory("A", 1) }
    local a = pane.current_view
    local b = PlaceView("B", 10)
    panes.present(b, { pane = pane })
    a.place = 2
    panes.present(a, { pane = pane })
    panes.back(pane)
    panes.back(pane)
    a.place = 3
    panes.record_location(pane)

    test.equal(panes.back(pane), a)
    test.equal(a.place, 1)
    test.equal(panes.forward(pane), a)
    test.equal(a.place, 3)
    test.equal(panes.forward(pane), b)
    test.equal(b.place, 10)
    test.equal(panes.forward(pane), a)
    test.equal(a.place, 2)
  end)

  test.it("limits each View across repeated visits without removing another View's places", function()
    local pane = panes.create { factory = factory("A", 1), history_limit = 2 }
    local a = pane.current_view
    local b = PlaceView("B", 10)
    panes.present(b, { pane = pane })
    b.place = 20
    panes.record_location(pane)
    a.place = 2
    panes.present(a, { pane = pane })
    a.place = 3
    panes.record_location(pane)

    test.equal(panes.history_length(pane), 4)
    test.equal(panes.back(pane), a)
    test.equal(a.place, 2)
    test.equal(panes.back(pane), b)
    test.equal(b.place, 20)
    test.equal(panes.back(pane), b)
    test.equal(b.place, 10)
    test.not_ok(panes.is_back_available(pane))
  end)

  test.it("compresses a repeated three-place sequence", function()
    local pane = panes.create { factory = factory("A", 10) }
    local view = pane.current_view
    for _, place in ipairs { 20, 30, 10, 20, 30 } do
      view.place = place
      panes.record_location(pane)
    end
    test.equal(panes.history_length(pane), 3)
    test.equal(view.place, 30)
    panes.back(pane)
    test.equal(view.place, 20)
    panes.back(pane)
    test.equal(view.place, 10)
    test.not_ok(panes.is_back_available(pane))
  end)

  test.it("keeps the current place when insertion completes an earlier repeated copy", function()
    local pane = panes.create { factory = factory("A", 10) }
    local view = pane.current_view
    for _, place in ipairs { 30, 10, 20, 30 } do
      view.place = place
      panes.record_location(pane)
    end
    for _ = 1, 4 do panes.back(pane) end
    view.place = 20
    panes.record_location(pane)

    test.equal(panes.history_length(pane), 3)
    test.equal(view.place, 20)
    panes.forward(pane)
    test.equal(view.place, 30)
    panes.back(pane)
    test.equal(view.place, 20)
    panes.back(pane)
    test.equal(view.place, 10)
  end)

  test.it("does not compress different positions into a repeated sequence", function()
    local pane = panes.create { factory = factory("A", 10) }
    local view = pane.current_view
    for _, place in ipairs { 20, 11, 20 } do
      view.place = place
      panes.record_location(pane)
    end
    test.equal(panes.history_length(pane), 4)
    for _, place in ipairs { 11, 20, 10 } do
      panes.back(pane)
      test.equal(view.place, place)
    end
  end)

  test.it("does not compress repeated places across another View", function()
    local pane = panes.create { factory = factory("A", 10) }
    local view = pane.current_view
    view.place = 20
    panes.record_location(pane)
    local other = PlaceView("B", 30)
    panes.present(other, { pane = pane })
    view.place = 10
    panes.present(view, { pane = pane })
    view.place = 20
    panes.record_location(pane)

    test.equal(panes.history_length(pane), 5)
    panes.back(pane)
    test.equal(view.place, 10)
    test.equal(panes.back(pane), other)
    test.equal(other.place, 30)
    test.equal(panes.back(pane), view)
    test.equal(view.place, 20)
    panes.back(pane)
    test.equal(view.place, 10)
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
