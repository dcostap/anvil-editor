local core = require "core"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local test = require "core.test"

local FakeView = View:extend()

function FakeView:new(name, height)
  FakeView.super.new(self)
  self.name = name
  self.height = height
  self.updates = 0
  self.draws = 0
  self.presses = 0
  self.keys = 0
end

function FakeView:get_name() return self.name end
function FakeView:update()
  self.updates = self.updates + 1
  if self.height then self.size.y = self.height end
end
function FakeView:draw() self.draws = self.draws + 1 end
function FakeView:on_mouse_pressed()
  self.presses = self.presses + 1
  return true
end
function FakeView:on_key_pressed()
  self.keys = self.keys + 1
  return true
end

local function pane_factory(name)
  return function() return FakeView(name) end
end

test.describe("Root Panel Pane presentation", function()
  local saved
  local root

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      root_panel = core.root_panel,
      title_bar = core.title_bar,
      nag_view = core.nag_view,
      global_prompt_bar = core.global_prompt_bar,
      status_bar = core.status_bar,
      active_view = core.active_view,
      set_active_view = core.set_active_view,
      draw_rect = renderer.draw_rect,
    }
    core.title_bar = FakeView("title", 10)
    core.nag_view = FakeView("nag", 5)
    core.nag_view.show_height = 5
    core.global_prompt_bar = FakeView("prompt", 7)
    core.status_bar = FakeView("status", 8)
    root = RootPanel()
    root.size.x, root.size.y = 300, 200
    core.root_panel = root
    core.set_active_view = function(view) core.active_view = view end
    renderer.draw_rect = function() end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    renderer.draw_rect = saved.draw_rect
    saved.draw_rect = nil
    for key, value in pairs(saved) do core[key] = value end
  end)

  test.it("keeps shell Views outside the Pane layout", function()
    local one = panes.create { factory = pane_factory("one") }
    local two = panes.split(one, "right", { factory = pane_factory("two") })
    root:update()

    test.equal(core.title_bar.position.y, 0)
    test.equal(core.nag_view.position.y, 10)
    test.equal(one.position.y, 15)
    test.equal(one.size.y, 170)
    test.equal(two.position.x, 150)
    test.equal(core.global_prompt_bar.position.y, 185)
    test.equal(core.status_bar.position.y, 192)
  end)

  test.it("lays out only the visible Pane Group", function()
    local one = panes.create { factory = pane_factory("one") }
    panes.split(one, "right", { factory = pane_factory("two") })
    local three = panes.create { factory = pane_factory("three") }
    root:update()

    test.same(root:pane_views(), { three.current_view })
    test.equal(three.size.x, 300)
    panes.focus(one)
    root:update()
    test.equal(#root:pane_views(), 2)
  end)

  test.it("renders the shell with zero Panes", function()
    root:update()
    test.same(root:pane_views(), {})
    test.equal(root.content_rect.h, 170)
    root:draw()
    test.equal(core.title_bar.draws, 1)
    test.equal(core.status_bar.draws, 1)
  end)

  test.it("routes pointer events to the hit-tested Pane owner", function()
    local one = panes.create { factory = pane_factory("one") }
    local two = panes.split(one, "right", { factory = pane_factory("two") })
    root:update()
    root:on_mouse_pressed("left", 20, 80, 1)
    test.equal(one.current_view.presses, 1)
    test.equal(panes.active(), one)
    root:on_mouse_pressed("left", 250, 80, 1)
    test.equal(two.current_view.presses, 1)
    test.equal(panes.active(), two)
  end)

  test.it("routes keyboard events through a registered focus target", function()
    local one = panes.create { factory = pane_factory("one") }
    local child = FakeView("child")
    panes.register_focus_target(one.current_view, child)
    core.active_view = child
    root:update()
    test.ok(root:contains_view(child))
    test.ok(root:on_key_pressed("a"))
    test.equal(child.keys, 1)
  end)

  test.it("resizes the hit-tested divider", function()
    local one = panes.create { factory = pane_factory("one") }
    panes.split(one, "right", { factory = pane_factory("two") })
    root:update()
    test.ok(root:on_mouse_pressed("left", 150, 50, 1))
    test.ok(root:on_mouse_moved(75, 50, -75, 0))
    test.ok(one.group.root.ratio < 0.3)
    test.ok(root:on_mouse_released("left", 75, 50))
  end)
end)
