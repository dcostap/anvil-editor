local core = require "core"
local panes = require "core.panes"
local PaneCommandBar = require "core.pane_command_bar"
local View = require "core.view"
local test = require "core.test"

local ActionView = View:extend()
function ActionView:new()
  ActionView.super.new(self)
  self.actions_run = 0
end
function ActionView:get_name() return "action view" end
function ActionView:get_pane_actions()
  return {
    { id = "run", label = "Run", action = function() self.actions_run = self.actions_run + 1 end },
  }
end

local function create_view() return ActionView() end

test.describe("Pane Command Bar", function()
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

  test.it("shows the Current View title and its chosen controls", function()
    local pane = panes.create { factory = create_view }
    local bar = PaneCommandBar(pane)
    bar:update_rect { x = 10, y = 20, w = 300, h = 180 }
    local model = bar:get_model()
    test.equal(model.title, "1 action view")
    test.equal(model.actions[1].id, "run")
    test.equal(model.actions[#model.actions].id, "close-pane")
    test.equal(pane.current_view.position.y, 20 + bar.size.y)
    test.equal(pane.current_view.size.y, 180 - bar.size.y)
  end)

  test.it("runs a View action from its control", function()
    local pane = panes.create { factory = create_view }
    local bar = PaneCommandBar(pane)
    bar:update_rect { x = 0, y = 0, w = 300, h = 180 }
    local action = bar:get_model().actions[1]
    test.ok(bar:on_mouse_pressed("left", action.x + 1, action.y + 1, 1))
    test.equal(pane.current_view.actions_run, 1)
  end)
end)
