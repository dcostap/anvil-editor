local core = require "core"
local keymap = require "core.keymap"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local test = require "core.test"
local View = require "core.view"

local WheelView = View:extend()

function WheelView:new()
  WheelView.super.new(self)
  self.wheel_events = 0
end

function WheelView:on_mouse_wheel()
  self.wheel_events = self.wheel_events + 1
  return true
end

test.describe("Mouse wheel routing", function()
  local saved
  local root

  test.before_each(function()
    saved = {
      active_view = core.active_view,
      root_panel = core.root_panel,
      ctrl = keymap.modkeys.ctrl,
      ctrl_wheeldown = keymap.map["ctrl+wheeldown"],
    }
    panes.reset_for_tests()
    root = RootPanel()
    core.root_panel = root
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.active_view = saved.active_view
    core.root_panel = saved.root_panel
    keymap.modkeys.ctrl = saved.ctrl
    keymap.map["ctrl+wheeldown"] = saved.ctrl_wheeldown
  end)

  test.it("gives a mapped Control-wheel action priority over View scrolling", function()
    local pane = panes.create { factory = function() return WheelView() end }
    local view = pane.current_view
    root.overlapping_view = view

    local mapped_actions = 0
    keymap.map["ctrl+wheeldown"] = {
      function()
        mapped_actions = mapped_actions + 1
        return true
      end,
    }
    keymap.modkeys.ctrl = true

    core.on_event("mousewheel", -1, 0)

    test.equal(mapped_actions, 1)
    test.equal(view.wheel_events, 0)
  end)
end)
