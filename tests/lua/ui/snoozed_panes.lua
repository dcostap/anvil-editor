local core = require "core"
local common = require "core.common"
local command = require "core.command"
local panes = require "core.panes"
local layout = require "core.pane_layout"
local pane_report = require "core.pane_report"
local numbered = require "core.numbered_panes"
local storage = require "core.storage"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local test = require "core.test"

-- A View that stands for a Terminal View with its Terminal Session.
local FakeTerminal = View:extend()
function FakeTerminal:new(session)
  FakeTerminal.super.new(self)
  self.terminal_view, self.session_id = true, session
end
function FakeTerminal:get_name() return self.session_id end

local function file() return panes.create {factory = function() return View() end} end
local function terminal(session) return panes.create {factory = function() return FakeTerminal(session) end} end

-- Seam: shell requests delivered through the public event handler.
local function request(value)
  core.on_event("panerequest", common.serialize(value, {escape = true}), -1, -1, 0)
end

local function snooze(pane) request {action = "snooze", pane = pane.id} end

local function report_item(pane)
  for _, item in ipairs(pane_report.build()) do
    if item.id == pane.id then return item end
  end
end

local function members(pane) return layout.leaves(pane.group.root) end

test.describe("Snoozed Panes", function()
  local saved
  test.before_each(function()
    panes.reset_for_tests()
    saved = {root = core.root_panel, focus = core.set_active_view, active = core.active_view}
    core.set_active_view = function(view) core.active_view = view end
    core.root_panel = RootPanel()
    storage.clear("sidebar", "snoozes")
  end)
  test.after_each(function()
    panes.reset_for_tests()
    core.root_panel, core.set_active_view, core.active_view = saved.root, saved.focus, saved.active
    storage.clear("sidebar", "snoozes")
  end)

  test.it("moves a snoozed Terminal's Pane to its own Pane Group that navigation skips", function()
    local a = file()
    local t = panes.split(a, "right", {factory = function() return FakeTerminal("t") end})
    local b = file()
    panes.focus(t)
    snooze(t)
    test.same(members(t), {t})
    test.same(members(a), {a})
    test.ok(report_item(t).snoozed, "the report does not mark the Snoozed Pane")
    test.is_nil(report_item(a).snoozed)
    test.equal(panes.active(), a, "focus did not go to the Pane beside the Snoozed Pane")
    local visited = {}
    for _ = 1, 4 do
      command.perform("pane:focus_next")
      visited[#visited + 1] = panes.active()
    end
    test.same(visited, {b, a, b, a})
  end)

  test.it("does not snooze a Pane without a Terminal", function()
    local a, b = file(), file()
    snooze(b)
    test.is_nil(report_item(b).snoozed)
    test.same(panes.navigable(), {a, b})
  end)

  test.it("shows a Snoozed Pane on request and keeps it snoozed", function()
    local a, t = file(), terminal("t")
    snooze(t)
    request {action = "focus", pane = t.id}
    test.equal(panes.active(), t)
    test.equal(panes.visible_group(), t.group)
    test.ok(report_item(t).snoozed)
    test.same(panes.navigable(), {a})
  end)

  test.it("gives a Snoozed Pane no Pane number", function()
    local projects = {{path = "C:/A", panes = {
      {id = "current", focused = 100},
      {id = "snoozed", focused = 90, snoozed = true, terminal = {session = "s", state = "running", bell = 10}},
      {id = "recent", focused = 80},
    }}}
    local numbers = numbered.numbers(projects, {}, {})
    test.equal(numbers[numbered.key("C:/A", "recent")], 1)
    test.is_nil(numbers[numbered.key("C:/A", "snoozed")])
  end)

  test.it("wakes due Snoozed Panes together in Pane Groups of at most three, oldest Snooze first", function()
    local a = file()
    local t1, t2, t3, t4, t5 = terminal("t1"), terminal("t2"), terminal("t3"), terminal("t4"), terminal("t5")
    for _, pane in ipairs {t1, t2, t3, t4, t5} do snooze(pane) end
    panes.focus(a)
    local now = os.time()
    storage.save("sidebar", "snoozes", {t1 = now - 10, t2 = now - 40, t3 = now - 30, t4 = now - 20, t5 = now + 3600})
    require("core.snoozed_panes").check()
    test.same(members(t2), {t2, t3, t4})
    test.same(members(t1), {t1})
    test.is_nil(report_item(t1).snoozed)
    test.is_nil(report_item(t2).snoozed)
    test.ok(report_item(t5).snoozed, "a Snooze that is not due ended")
    test.equal(panes.active(), a, "a woken Pane took focus")
  end)

  test.it("leaves a shown Snoozed Pane in place when it wakes", function()
    local a, t1, t2 = file(), terminal("t1"), terminal("t2")
    snooze(t1); snooze(t2)
    panes.focus(t1)
    local now = os.time()
    storage.save("sidebar", "snoozes", {t1 = now - 20, t2 = now - 10})
    require("core.snoozed_panes").check()
    test.same(members(t1), {t1})
    test.same(members(t2), {t2})
    test.same(panes.navigable(), {a, t1, t2})
    test.equal(panes.active(), t1)
  end)

  test.it("wakes a Snoozed Pane when the user removes its Snooze", function()
    local a, t = file(), terminal("t")
    storage.save("sidebar", "snoozes", {t = os.time() + 3600})
    snooze(t)
    storage.clear("sidebar", "snoozes")
    request {action = "unsnooze", pane = t.id}
    test.is_nil(report_item(t).snoozed)
    test.same(panes.navigable(), {a, t})
  end)

  test.it("keeps Snoozed Panes in the Workspace", function()
    local a, t = file(), terminal("t")
    snooze(t)
    local state = panes.save_workspace_state(function(view)
      return {module = "test", state = {session = view.session_id}}
    end)
    test.ok(panes.restore_workspace_state(state, function(saved_view)
      return saved_view.state.session and FakeTerminal(saved_view.state.session) or View()
    end))
    local restored = panes.ordered()
    test.equal(#restored, 2)
    test.is_nil(report_item(restored[1]).snoozed)
    test.ok(report_item(restored[2]).snoozed, "the restored Pane is not snoozed")
    test.ok(a)
  end)
end)
