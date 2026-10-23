local test = require "core.test"
local numbered = require "core.numbered_panes"

-- The isolated test Project can open its initial Terminal during startup.
-- End that test shell without a shutdown dialog after the tests finish.
require("core.storage").save("plugins.terminal", "quit_choice", "end")

-- Seam: the shared numbering and navigation API consumes Project reports and seen times.
test.describe("Pending Pane numbers", function()
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

  test.it("removes a viewed result but keeps an agent waiting for an answer", function()
    local projects = {{id = 1, path = "C:/A", panes = {active = 1,
      {id = "active", terminal = {session = "s", state = "running"}}},
      terminals = {{id = "s", state = "running", agent_state = "done", agent_since = 10}}},
      windows = {{id = 1, selected_project = 1}}}
    test.is_nil(numbered.target(projects, 1, {}))
    projects[1].terminals[1].agent_state = "blocked"
    test.equal(numbered.target(projects, 1, {}).id, "active")
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
      test.same(request, {action = "focus", pane = "old"})
    end)
    core.project_sidebar, system.pane_request = old_model, old_request
    test.ok(ok, err)
  end)
end)
