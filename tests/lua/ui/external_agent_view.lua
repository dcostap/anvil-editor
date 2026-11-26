local common = require "core.common"
local core = require "core"
local fs = require "core.fs"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local panes = require "core.panes"
local Project = require "core.project"
local test = require "core.test"
local external_agents = require "plugins.external_agents"

-- Seam: an External Agent View in a Project process that uses a Machine. The Machine has its own user folder, as
-- the other PC has, and holds the thread.
test.describe("External Agent View on a Machine", function()
  local function wait_until(predicate, message)
    local deadline = system.get_time() + 30
    while system.get_time() < deadline do
      if predicate() then return end
      coroutine.yield(0.02)
    end
    test.fail(message)
  end

  local function request(context, method, params)
    params.project = context.project
    local done, err, result
    fs.machine:request(method, params, nil, function(e, r) done, err, result = true, e, r end)
    wait_until(function() return done end, method .. " timed out")
    test.is_nil(err, err and err.message)
    return result
  end

  test.before_each(function(context)
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "xagent" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.project = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.user))
    test.ok(common.mkdirp(context.project))
    context.projects = core.projects
    core.projects = { Project(context.project) }
    context.server = machine_server.start(context.user, { context.project })
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    wait_until(function() return fs.machine.state == "ready" end, "The Machine did not connect")
    -- The agent's first wait creates it, as Antigravity's first call does.
    request(context, "external.read", { agent = "agy", listen = true })
    request(context, "external.post", { agent = "agy", text = "Hello from agy", from = { kind = "self" } })
  end)

  test.after_each(function(context)
    if context.view then context.view:on_close() end
    panes.reset_for_tests()
    fs.use_local()
    core.projects = context.projects
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("shows the thread, sends a message and follows the agent's answer", function(context)
    local view = external_agents.open("agy")
    context.view = view
    test.ok(view and view:is(external_agents.View), "The command did not open an External Agent View")
    test.equal(view:get_name(), "agy")
    wait_until(function() return #view.messages == 1 end, "The View did not load the thread")
    test.equal(view.messages[1].text, "Hello from agy")
    test.equal(view:author(view.messages[1]), "agy")
    test.equal(view.status, "listening")
    -- The root panel sends View.cursor to the system as the mouse cursor name.
    test.equal(type(view.cursor), "string", "The View must keep a mouse cursor name")

    view.field:on_text("Check the build")
    test.ok(view:send())
    test.equal(view.field:get_text(), "")
    local thread
    wait_until(function()
      thread = request(context, "external.read", { agent = "agy" })
      return #thread.messages == 2
    end, "The message did not reach the Machine")
    test.equal(thread.messages[2].text, "Check the build")
    test.equal(thread.messages[2].from.kind, "user")
    wait_until(function() return #view.messages == 2 end, "The View did not show the sent message")
    test.equal(view:author(view.messages[2]), "You")

    -- The View waits on the Machine, so the answer shows without a new open.
    request(context, "external.post", { agent = "agy", text = "Build is green", reply_to = thread.messages[2].request,
      from = { kind = "self" } })
    wait_until(function() return #view.messages == 3 end, "The View did not show the agent's answer")
    test.equal(view.messages[3].text, "Build is green")

    -- Copy takes the selected message when the field has no selection.
    local clipboard = system.get_clipboard()
    view.selected = view.messages[3]
    test.ok(view:perform("copy"))
    test.equal(system.get_clipboard(), "Build is green")
    system.set_clipboard(clipboard or "")

    test.equal(external_agents.open("agy"), view, "A second open must show the open View")
    local restored = external_agents.View.from_state(view:get_state())
    test.equal(restored.agent, "agy")
    restored:on_close()
  end)

  test.it("keeps an unsent message when the Machine refuses it", function(context)
    local view = external_agents.View("nobody")
    context.view = view
    wait_until(function() return view.status == "unknown" end, "The View did not report an unknown agent")
    view.field:on_text("Are you there?")
    test.ok(view:send())
    wait_until(function() return view.field.error ~= nil end, "The refused message did not show an error")
    test.equal(view.field:get_text(), "Are you there?")
  end)
end)
