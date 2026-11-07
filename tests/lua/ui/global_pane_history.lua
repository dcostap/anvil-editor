local core = require "core"
local common = require "core.common"
local command = require "core.command"
local panes = require "core.panes"
local pane_report = require "core.pane_report"
local pane_requests = require "core.pane_requests"
local recent_panes = require "core.recent_panes"
local View = require "core.view"
local test = require "core.test"

-- Seam: the Pane History commands, the Pane report and the shell's focus requests.
local NamedView = View:extend()
function NamedView:new(name)
  NamedView.super.new(self)
  self.name = name
end
function NamedView:get_name() return self.name end

local function factory(name)
  return function() return NamedView(name) end
end

test.describe("Pane History", function()
  local saved, requests, now, focused

  test.before_each(function()
    panes.reset_for_tests()
    pane_report.reset_for_tests()
    recent_panes.reset_for_tests()
    saved = {hosted = system.is_hosted_surface, send = system.set_project_panes, focus = system.window_has_focus,
      request = system.pane_request, set_active_view = core.set_active_view, root = core.root_project,
      model = core.project_sidebar, fetch = core.request_project_sidebar, time = system.get_time,
      window = system.get_anvil_window_id}
    system.get_anvil_window_id = function() return 0 end
    requests, now, focused = {}, 1000, true
    system.get_time = function() return now end
    system.is_hosted_surface = function() return true end
    system.set_project_panes = function() return true end
    system.window_has_focus = function() return focused end
    system.pane_request = function(...) requests[#requests + 1] = {...}; return true end
    core.set_active_view = function(view) core.active_view = view end
    core.root_project = function() return {path = "C:\\Here"} end
    core.project_sidebar = nil
    core.request_project_sidebar = function() return true end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    pane_report.reset_for_tests()
    recent_panes.reset_for_tests()
    system.is_hosted_surface, system.set_project_panes, system.window_has_focus, system.pane_request =
      saved.hosted, saved.send, saved.focus, saved.request
    system.get_time = saved.time
    system.get_anvil_window_id = saved.window
    core.set_active_view, core.root_project, core.project_sidebar, core.request_project_sidebar =
      saved.set_active_view, saved.root, saved.model, saved.fetch
  end)

  -- Lets the Project report its focus, as a frame does. The user then stays `seconds` there.
  local function stay(seconds)
    pane_report.publish()
    now = now + (seconds or 5)
  end

  local function visit(pane, seconds)
    panes.focus(pane)
    stay(seconds)
  end

  local function move(direction)
    command.perform("pane:history_" .. direction)
    stay()
  end

  test.it("moves back and forward through the visited Panes without adding visits", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local three = panes.create { factory = factory("three") }
    visit(one)
    visit(two, 0.2)
    visit(three)
    move("back")
    test.equal(panes.active(), two)
    move("back")
    test.equal(panes.active(), one)
    move("forward")
    test.equal(panes.active(), two)
    move("forward")
    test.equal(panes.active(), three)
    move("oldest")
    test.equal(panes.active(), one)
    move("newest")
    test.equal(panes.active(), three)
    test.not_ok(require("core.pane_history").move("forward"), "Forward went past the newest visit")
  end)

  test.it("keeps the Pane that Back showed when the user goes to another Pane", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local three = panes.create { factory = factory("three") }
    local four = panes.create { factory = factory("four") }
    visit(one)
    visit(two)
    visit(three)
    move("back")
    test.equal(panes.active(), two)
    visit(four)
    move("back")
    test.equal(panes.active(), two, "Back did not return to the Pane that the user left")
    move("back")
    test.equal(panes.active(), three, "The new visit removed the later history")
  end)

  test.it("moves through repeated Pane sequences only once", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local three = panes.create { factory = factory("three") }
    visit(one)
    visit(two)
    visit(one)
    visit(two)
    visit(one)
    visit(two)
    visit(three)
    move("back")
    test.equal(panes.active(), two)
    move("back")
    test.equal(panes.active(), one)
    test.not_ok(require("core.pane_history").move("back"), "Back repeated an earlier sequence")
    move("forward")
    test.equal(panes.active(), two)
    move("forward")
    test.equal(panes.active(), three)
    test.not_ok(require("core.pane_history").move("forward"))
  end)

  test.it("keeps the later cross-Project sequence and maps a history move to it", function()
    local list, current = require("core.pane_history").timeline({
      {path = "C:/Here", panes = {history = {
        {id = "one", at = 1000}, {id = "two", at = 3000},
        {id = "one", at = 4000}, {id = "two", at = 6000},
        {id = "one", at = 7000, to = 1000},
      }}},
      {path = "C:/Other", panes = {history = {
        {id = "one", at = 2000}, {id = "one", at = 5000},
      }}},
    })
    test.same(list, {
      {path = "C:/Here", id = "one", at = 4000},
      {path = "C:/Other", id = "one", at = 5000},
      {path = "C:/Here", id = "two", at = 6000},
    })
    test.equal(current, 1)
  end)

  test.it("crosses Projects in both directions", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    visit(two)
    visit(one)
    -- The user visits a Pane in another Project, then goes back from there.
    focused = false
    stay()
    local far = math.floor(now * 1000)
    core.project_sidebar = {{path = "C:/Other", panes = {{id = "far"}, history = {{id = "far", at = far}}}}}
    now = now + 5
    focused = true
    test.ok(pane_requests.perform(common.serialize({action = "focus", pane = one.id, history = 1005000})))
    stay()
    test.equal(panes.active(), one)
    move("forward")
    test.equal(#requests, 1, "Forward did not go to the other Project's Pane")
    local route, path, text = table.unpack(requests[1])
    test.same({route, path}, {"select", "C:/Other"})
    test.same(assert(load("return " .. text, "=request", "t", {}))(),
      {action = "focus", pane = "far", feedback = "numbered", history = far})
  end)

  test.it("keeps history moves inside their Window despite visits and moves in another Window", function()
    local one = panes.create {factory = factory("one")}
    local two = panes.create {factory = factory("two")}
    visit(one)
    visit(two)
    core.project_sidebar = {
      {path = "C:/Elsewhere", window_id = 2, panes = {{id = "far"}, history = {
        {id = "far", at = 1002000}, {id = "far", at = 1007000},
        {id = "far", at = 1008000, to = 1002000},
      }}},
    }
    move("back")
    test.equal(panes.active(), one)
    move("forward")
    test.equal(panes.active(), two)
    move("oldest")
    test.equal(panes.active(), one)
    move("newest")
    test.equal(panes.active(), two)
    test.same(requests, {})
  end)

  test.it("starts fresh history when its Project moves to another Window", function()
    local one = panes.create {factory = factory("one")}
    local two = panes.create {factory = factory("two")}
    visit(one)
    visit(two)
    system.get_anvil_window_id = function() return 2 end
    stay()
    test.not_ok(require("core.pane_history").move("back"))
    test.equal(panes.active(), two)
    visit(one)
    move("back")
    test.equal(panes.active(), two)
  end)
end)
