local test = require "core.test"
local numbered = require "core.numbered_panes"

-- Seam: the shared numbering and navigation API consumes Project reports and seen times.
test.describe("Pending Pane numbers", function()
  test.it("fills spare numbers from focus history without repeating pending or current Panes", function()
    local projects = {{path = "C:/A", panes = {
      {id = "current", focused = 100},
      {id = "pending", focused = 90, terminal = {session = "p", state = "running", bell = 10}},
      {id = "recent", focused = 80},
      {id = "older", focused = 70},
      {id = "oldest", focused = 60},
      {id = "last", focused = 50},
      {id = "never"},
    }}}
    local function targets()
      local result = {}
      local numbers = numbered.numbers(projects, {})
      for n = 1, numbered.COUNT do
        local item = numbered.target(projects, n, {})
        result[n] = item and item.id
        if item then test.equal(numbers[numbered.key(item.path, item.id)], n) end
      end
      test.is_nil(numbers[numbered.key("C:/A", "current")])
      test.is_nil(numbers[numbered.key("C:/A", "never")])
      return result
    end
    test.same(targets(), {"pending", "recent", "older", "oldest", "last"})
    projects[1].panes[4].focused = 85
    test.same(targets(), {"pending", "older", "recent", "oldest", "last"})
    projects[1].panes[2].terminal.bell = nil
    test.same(targets(), {"pending", "older", "recent", "oldest", "last"})
  end)

  test.it("numbers unread results and waiting agents FIFO across Projects", function()
    local projects = {
      {path = "C:/A", panes = {
        {id = "read", terminal = {session = "read", state = "running"}},
        {id = "new", terminal = {session = "new", state = "running"}},
        {id = "bell", terminal = {session = "bell", state = "running", bell = 20}},
        {id = "text", focused = 100}}, terminals = {
        {id = "read", state = "running", agent_state = "done", agent_since = 5},
        {id = "new", state = "running", agent_state = "error", agent_since = 30}}},
      {path = "C:/B", panes = {{id = "wait", terminal = {session = "wait", state = "running"}}},
        terminals = {{id = "wait", state = "running", agent_state = "blocked", agent_since = 10}}},
    }
    local seen = {read = 6, wait = 40}
    local numbers = numbered.numbers(projects, seen)
    test.equal(numbers[numbered.key("C:/B", "wait")], 1)
    test.equal(numbers[numbered.key("C:/A", "bell")], 2)
    test.equal(numbers[numbered.key("C:/A", "new")], 3)
    test.is_nil(numbers[numbered.key("C:/A", "read")])
    test.is_nil(numbers[numbered.key("C:/A", "text")])
    test.equal(numbered.target(projects, 1, seen).id, "wait")
    seen.bell = 25
    projects[2].terminals[1].agent_state = "working"
    test.equal(numbered.target(projects, 1, seen).id, "new")
    test.is_nil(numbered.target(projects, 2, seen))
  end)

  test.it("holds a Terminal with a Snooze until its time, then queues it from that time", function()
    local projects = {{path = "C:/A", panes = {
      {id = "held", terminal = {session = "held", state = "running", bell = 10}},
      {id = "asks", terminal = {session = "asks", state = "running"}},
      {id = "due", terminal = {session = "due", state = "running"}},
      {id = "bell", terminal = {session = "bell", state = "running", bell = 30}}},
      terminals = {{id = "asks", state = "running", agent_state = "blocked", agent_since = 5}}}}
    local later = os.time() + 3600
    local snoozes = {held = later, asks = later, due = 40}
    local function targets()
      local ids = {}
      for n = 1, numbered.COUNT do
        local item = numbered.target(projects, n, {}, snoozes)
        ids[#ids + 1] = item and item.id
      end
      return table.concat(ids, ",")
    end
    test.equal(targets(), "bell,due")
    -- A held result comes back at its Snooze time, not at its own older time.
    snoozes.held = 35
    test.equal(targets(), "bell,held,due")
  end)

  test.it("removes a viewed result but keeps an agent waiting for an answer", function()
    local projects = {{id = 1, path = "C:/A", panes = {active = 1,
      {id = "active", terminal = {session = "s", state = "running"}}},
      terminals = {{id = "s", state = "running", agent_state = "done", agent_since = 10}}},
      windows = {{id = 1, selected_project = 1}}}
    test.is_nil(numbered.target(projects, 1, {}))
    projects[1].terminals[1].agent_state = "blocked"
    test.equal(numbered.target(projects, 1, {}).id, "active")
  end)

  test.it("keeps a focused waiting agent ahead of history and caps navigation at five", function()
    local projects = {{id = 1, path = "C:/A", panes = {active = 1,
      {id = "active", focused = 100, terminal = {session = "s", state = "running"}},
      {id = "previous", focused = 90}},
      terminals = {{id = "s", state = "running", agent_state = "blocked", agent_since = 10}}},
      {path = "C:/B", panes = {{id = "remote", focused = 80}}},
      windows = {{selected_project = 1}}}
    test.equal(numbered.target(projects, 1, {}).id, "active")
    test.equal(numbered.target(projects, 2, {}).id, "previous")
    test.equal(numbered.target(projects, 3, {}).id, "remote")
    test.is_nil(numbered.target(projects, 4, {}))
    for n = 1, 5 do
      projects[2].panes[#projects[2].panes + 1] = {
        id = "bell" .. n, terminal = {session = "b" .. n, state = "running", bell = 10 + n}}
    end
    test.equal(numbered.target(projects, 5, {}).id, "bell4")
    test.is_nil(numbered.target(projects, 6, {}))
    local numbers = numbered.numbers(projects, {})
    test.is_nil(numbers[numbered.key("C:/A", "previous")])
    test.is_nil(numbers[numbered.key("C:/B", "remote")])
  end)

  test.it("routes the numbered command to the oldest pending Pane in another Project", function()
    local core = require "core"
    local command = require "core.command"
    local old_model, old_request = core.project_sidebar, system.pane_request
    local requests = {}
    local ok, err = pcall(function()
      core.project_sidebar = {{path = "C:/pending-number-test", panes = {
        {id = "new", terminal = {session = "new", state = "running", bell = os.time() + 2}},
        {id = "old", terminal = {session = "old", state = "running", bell = os.time() + 1}}}}}
      system.pane_request = function(...)
        requests[#requests + 1] = {...}
        return true
      end
      test.ok(command.perform("pane:focus_number_1"))
      test.equal(#requests, 1)
      test.equal(requests[1][2], "C:/pending-number-test")
      local request = assert(load("return " .. requests[1][3], "=request", "t", {}))()
      test.same(request, {action = "focus", pane = "old", feedback = "numbered"})
    end)
    core.project_sidebar, system.pane_request = old_model, old_request
    test.ok(ok, err)
  end)
end)
