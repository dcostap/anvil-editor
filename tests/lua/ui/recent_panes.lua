local core = require "core"
local panes = require "core.panes"
local pane_report = require "core.pane_report"
local recent_panes = require "core.recent_panes"
local View = require "core.view"
local test = require "core.test"

-- Seam: the Project Sidebar model's focus stamps, the Pane report, and the Recent Pane commands.
local NamedView = View:extend()
function NamedView:new(name)
  NamedView.super.new(self)
  self.name = name
end
function NamedView:get_name() return self.name end

local function factory(name)
  return function() return NamedView(name) end
end

test.describe("Recent Pane numbers", function()
  test.it("numbers the five Panes that had focus before the current one, across Projects", function()
    local numbers = recent_panes.numbers({
      {path = "C:/A", panes = {{id = "a1", focused = 10}, {id = "a2", focused = 70}, {id = "a3"}}},
      {path = "C:/B", panes = {{id = "b1", focused = 60}, {id = "b2", focused = 50}, {id = "b3", focused = 40},
        {id = "b4", focused = 30}, {id = "b5", focused = 20}}},
    })
    local function number(path, id) return numbers[recent_panes.key(path, id)] end
    test.is_nil(number("C:/A", "a2"), "The current Pane has a number")
    test.same({number("C:/B", "b1"), number("C:/B", "b2"), number("C:/B", "b3"), number("C:/B", "b4"),
      number("C:/B", "b5")}, {1, 2, 3, 4, 5})
    test.is_nil(number("C:/A", "a1"), "A sixth Pane has a number")
    test.is_nil(number("C:/A", "a3"), "A Pane that never had focus has a number")
  end)
end)

test.describe("Recent Panes in a Project", function()
  local saved, reports, requests, fetches, focused, now

  test.before_each(function()
    panes.reset_for_tests()
    pane_report.reset_for_tests()
    recent_panes.reset_for_tests()
    saved = {hosted = system.is_hosted_surface, send = system.set_project_panes, focus = system.window_has_focus,
      request = system.pane_request, set_active_view = core.set_active_view, root = core.root_project,
      model = core.project_sidebar, fetch = core.request_project_sidebar, time = system.get_time}
    reports, requests, fetches, focused, now = {}, {}, 0, true, 1000
    system.get_time = function() return now end
    system.is_hosted_surface = function() return true end
    system.set_project_panes = function(text) reports[#reports + 1] = text; return true end
    system.window_has_focus = function() return focused end
    system.pane_request = function(...) requests[#requests + 1] = {...}; return true end
    core.set_active_view = function(view) core.active_view = view end
    core.root_project = function() return {path = "C:\\Here"} end
    core.project_sidebar = nil
    core.request_project_sidebar = function() fetches = fetches + 1; return true end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    pane_report.reset_for_tests()
    recent_panes.reset_for_tests()
    system.is_hosted_surface, system.set_project_panes, system.window_has_focus, system.pane_request =
      saved.hosted, saved.send, saved.focus, saved.request
    system.get_time = saved.time
    core.set_active_view, core.root_project, core.project_sidebar, core.request_project_sidebar =
      saved.set_active_view, saved.root, saved.model, saved.fetch
  end)

  local function last_report()
    return assert(load("return " .. reports[#reports], "=Pane report", "t", {}))()
  end

  -- Focuses a Pane and lets the Project report it, as a frame does. The user then stays `seconds` there.
  local function focus(pane, seconds)
    panes.focus(pane)
    pane_report.publish()
    now = now + (seconds or 5)
  end

  test.it("stamps a Pane when it takes focus while the Project has keyboard focus", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local three = panes.create { factory = factory("three") }
    focus(one)
    focus(two)
    focused = false
    focus(three)
    local report = last_report()
    test.ok(report[2].focused > report[1].focused, "The later focus has the older stamp")
    test.is_nil(report[3].focused, "A Pane that took focus without the keyboard has a stamp")
    test.is_nil(report[1].number, "The report still numbers Tabs by their order")
  end)

  test.it("returns to the previous Pane with the first Recent Pane", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    local three = panes.create { factory = factory("three") }
    focus(one)
    focus(two, 0.2)
    focus(three)
    recent_panes.focus(1)
    test.equal(panes.active(), two)
    pane_report.publish()
    recent_panes.focus(1)
    test.equal(panes.active(), three)
    pane_report.publish()
    recent_panes.focus(2)
    test.equal(panes.active(), one)
    test.same(requests, {})
  end)

  test.it("uses live local focus history when no Pane is pending", function()
    local numbered = require "core.numbered_panes"
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    focus(one)
    focus(two)
    test.equal(numbered.local_numbers()[one.id], 1)
    test.is_nil(numbered.local_numbers()[two.id])
    test.ok(numbered.focus(1))
    test.equal(panes.active(), one)
    pane_report.publish()
    test.equal(numbered.local_numbers()[two.id], 1)
  end)

  test.it("selects the reported Pane number when a more recent Pane is snoozed", function()
    local numbered = require "core.numbered_panes"
    local command = require "core.command"
    local build = panes.create { factory = factory("build") }
    local agent = panes.create { factory = factory("agent") }
    local held = panes.create { factory = factory("held") }
    local current = panes.create { factory = factory("current") }
    focus(build)
    focus(agent)
    focus(held)
    panes.snooze(held)
    focus(current)

    local numbers = numbered.numbers({{path = "C:/Here", panes = last_report()}}, {}, {})
    test.equal(numbers[numbered.key("C:/Here", agent.id)], 1)
    test.equal(numbers[numbered.key("C:/Here", build.id)], 2)
    test.ok(command.perform("pane:focus_number_2"))
    test.equal(panes.active(), build, "The command did not select the Pane numbered 2 in the report")
  end)

  test.it("asks the shell to focus a Recent Pane in another Project", function()
    local one = panes.create { factory = factory("one") }
    local two = panes.create { factory = factory("two") }
    focus(one)
    -- The fetched model holds an old report of this Project. Its live Panes replace it.
    core.project_sidebar = {
      {path = "C:/Here", panes = {{id = one.id, focused = now + 1000}}},
      {path = "C:/Other", panes = {{id = "far", focused = now - 1}}},
    }
    focus(two)
    recent_panes.focus(1)
    test.equal(panes.active(), two, "A Pane in another Project took focus here")
    test.equal(#requests, 1)
    local route, path, text = table.unpack(requests[1])
    test.same({route, path}, {"select", "C:/Other"})
    test.same(assert(load("return " .. text, "=request", "t", {}))(),
      {action = "focus", pane = "far", feedback = "numbered"})
    recent_panes.focus(2)
    test.equal(panes.active(), one)
  end)

  test.it("replaces the old report of a Project on a Machine, which the Sidebar names by its key", function()
    local machine_project = require "core.machine_project"
    local key, current = "anvil-machine://b71feffb0f24799d67c542024d722147/C:/Here", machine_project.current
    machine_project.current = key
    local ok, err = pcall(function()
      local one = panes.create { factory = factory("one") }
      local two = panes.create { factory = factory("two") }
      focus(one)
      core.project_sidebar = {
        {path = key, panes = {{id = one.id, focused = now + 1000}}},
        {path = "C:/Other", panes = {{id = "far", focused = now - 1}}},
      }
      focus(two)
      recent_panes.focus(1)
      test.equal(#requests, 1)
      local _, path = table.unpack(requests[1])
      test.equal(path, "C:/Other")
    end)
    machine_project.current = current
    test.ok(ok, err)
  end)

  test.it("fetches the other Projects' stamps each time the Project takes keyboard focus", function()
    panes.create { factory = factory("one") }
    focused = false
    pane_report.publish()
    test.equal(fetches, 0)
    focused = true
    pane_report.publish()
    pane_report.publish()
    test.equal(fetches, 1)
  end)
end)
