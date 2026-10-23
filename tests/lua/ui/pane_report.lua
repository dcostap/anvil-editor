local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local pane_report = require "core.pane_report"
local View = require "core.view"
local test = require "core.test"

-- Seam: the Pane report a hosted Project sends to the shell, and the Pane actions the shell sends back.
local NamedView = View:extend()
function NamedView:new(name)
  NamedView.super.new(self)
  self.name = name
end
function NamedView:get_name() return self.name end

local function factory(name)
  return function() return NamedView(name) end
end

test.describe("Pane report", function()
  local saved, reports
  test.before_each(function()
    panes.reset_for_tests()
    pane_report.reset_for_tests()
    saved = {hosted = system.is_hosted_surface, send = system.set_project_panes, set_active_view = core.set_active_view}
    reports = {}
    system.is_hosted_surface = function() return true end
    system.set_project_panes = function(text) reports[#reports + 1] = text; return true end
    core.set_active_view = function(view) core.active_view = view end
  end)
  test.after_each(function()
    panes.reset_for_tests()
    pane_report.reset_for_tests()
    system.is_hosted_surface, system.set_project_panes, core.set_active_view =
      saved.hosted, saved.send, saved.set_active_view
  end)

  local function last_report()
    return assert(load("return " .. reports[#reports], "=Pane report", "t", {}))()
  end

  test.it("reports Tabs in Pane order with their groups, the active Pane, and the visible group", function()
    local one = panes.create { factory = factory("one.lua") }
    panes.split(one, "right", { factory = factory("two.lua") })
    local three = panes.create { factory = factory("three.lua") }
    panes.focus(three)
    pane_report.publish()
    local report = last_report()
    test.equal(#report, 3)
    test.same({report[1].name, report[2].name, report[3].name}, {"one.lua", "two.lua", "three.lua"})
    test.same({report[1].number, report[2].number, report[3].number}, {1, 2, 3})
    test.same({report[1].group, report[2].group, report[3].group}, {1, 1, 2})
    test.equal(report[3].id, three.id)
    test.equal(report.active, 3)
    test.equal(report.visible, 2)
  end)

  test.it("sends a report only when it changes", function()
    local one = panes.create { factory = factory("one.lua") }
    pane_report.publish()
    pane_report.publish()
    test.equal(#reports, 1)
    one.current_view.name = "renamed.lua"
    pane_report.publish()
    test.equal(#reports, 2)
    test.equal(last_report()[1].name, "renamed.lua")
  end)

  test.it("focuses and closes the Pane that a Pane action names", function()
    local one = panes.create { factory = factory("one.lua") }
    local two = panes.create { factory = factory("two.lua") }
    panes.focus(one)
    core.on_event("panerequest", common.serialize({action = "focus", pane = two.id}, {escape = true}), -1, -1)
    test.equal(panes.active(), two)
    core.on_event("panerequest", common.serialize({action = "close", pane = one.id}, {escape = true}), -1, -1)
    test.equal(panes.count(), 1)
    test.is_nil(panes.find(one.id))
    -- A Pane that no longer exists changes nothing.
    core.on_event("panerequest", common.serialize({action = "focus", pane = one.id}, {escape = true}), -1, -1)
    test.equal(panes.active(), two)
  end)
end)
