local core = require "core"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local test = require "core.test"

-- Seam: editor control operations, shared by MCP and other local clients.
test.describe("Agent editor control", function()
  local saved, control
  test.before_each(function()
    saved = { root = core.root_panel, active = core.active_view, focus = core.set_active_view }
    panes.reset_for_tests()
    core.set_active_view = function(view) core.active_view = view end
    core.root_panel = RootPanel()
    control = require("core.control").new()
  end)
  test.after_each(function()
    panes.reset_for_tests()
    core.root_panel, core.active_view, core.set_active_view = saved.root, saved.active, saved.focus
  end)
  test.it("creates a named split once without taking focus", function()
    local source = panes.create { factory = function() return View() end }
    local args = { action = "split", pane = source.id, direction = "right", request_id = "split-one" }
    local result = control:call("pane", args, "test-client")
    test.ok(result.pane and result.pane ~= source.id)
    test.equal(panes.find(result.pane).group, source.group)
    test.equal(panes.active(), source)
    test.equal(core.active_view, source.current_view)
    test.equal(control:call("pane", args, "test-client").pane, result.pane)
    test.equal(#panes.ordered(), 2)
    local state = control:call("workspace_state", {}, "test-client")
    test.ok(state.panes[result.pane])
    local ok = pcall(function()
      control:call("pane", { action = "create", request_id = "split-one" }, "test-client")
    end)
    test.equal(ok, false, "A retry key cannot describe different work")
  end)
  test.it("keeps close confirmation and rejects unrecognized fields", function()
    local approve
    local pane = panes.create { factory = function()
      local view = View()
      function view:can_close(done) approve = done end
      return view
    end }
    local result = control:call("pane", { action = "close", pane = pane.id, request_id = "close-one" }, "test-client")
    test.equal(result.status, "confirmation_required")
    test.ok(panes.find(pane.id))
    test.equal(pcall(function()
      control:call("pane", { action = "close", pane = pane.id, force = true, request_id = "close-force" }, "test-client")
    end), false)
    approve()
    test.is_nil(panes.find(pane.id))
  end)

  test.it("sends a task once to the selected Pi instance and keeps its result", function()
    control:exchange("terminal-b", {instance = "pi-one", session = "session.jsonl", busy = false,
      receipts = {}, tasks = {}})
    local args = {terminal = "terminal-b", instance = "pi-one", text = "Review the change",
      delivery = "queue", request_id = "review"}
    local sent = control:call("agent_send", args, "terminal-a")
    local response = control:exchange("terminal-b", {instance = "pi-one", busy = false, receipts = {}, tasks = {}})
    test.equal(#response.commands, 1)
    test.equal(response.commands[1].id, sent.task)
    test.equal(response.commands[1].from, "terminal-a")
    test.equal(control:call("agent_send", args, "terminal-a").task, sent.task)
    control:exchange("terminal-b", {instance = "pi-one", busy = false,
      receipts = {{id = sent.task, status = "accepted"}},
      tasks = {{id = sent.task, status = "completed", result = "No issues"}}})
    local result = control:call("agent_read", {terminal = "terminal-b", instance = "pi-one", task = sent.task}, "terminal-a")
    test.equal(result.status, "completed")
    test.equal(result.result, "No issues")
    control:exchange("terminal-b", {instance = "pi-two", busy = false, receipts = {}, tasks = {}})
    test.equal(pcall(function()
      control:call("agent_send", {terminal = "terminal-b", instance = "pi-one", text = "Again",
        delivery = "queue", request_id = "review-new"}, "terminal-a")
    end), false, "A stale request cannot target a replacement conversation")
  end)

  test.it("opens a file and a Terminal in explicit Panes without changing focus", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows Terminal test")
    local folder = USERDIR .. "/control-open"
    require("core.common").mkdirp(folder)
    local file = assert(io.open(folder .. "/note.txt", "wb"))
    file:write("first\nsecond\n"); file:close()
    local source = panes.create {factory = function() return View() end}
    local terminal
    local ok, err = pcall(function()
      local opened = control:call("open_file", {path = folder .. "/note.txt", line = 2,
        pane = source.id, placement = "split", direction = "right", request_id = "open-note"}, "test-client")
      test.equal(panes.find(opened.pane).current_view.buffer.abs_filename:gsub("\\", "/"), folder .. "/note.txt")
      test.equal(panes.active(), source)
      terminal = control:call("terminal_start", {cwd = folder, pane = source.id, placement = "split",
        direction = "down", request_id = "open-terminal"}, "test-client")
      test.equal(panes.active(), source)
      local deadline = system.get_time() + 30
      local result
      repeat
        panes.find(terminal.pane).current_view:update()
        control:tick()
        result = control:call("operation_read", {operation = terminal.operation}, "test-client")
        coroutine.yield()
      until result.status ~= "starting" or system.get_time() > deadline
      test.equal(result.status, "ready")
      test.ok(result.terminal)
      test.equal(panes.active(), source)
    end)
    if terminal and panes.find(terminal.pane) then panes.close(terminal.pane, {force = true}) end
    test.ok(test.remove_tree(folder))
    assert(ok, err)
  end)
end)
