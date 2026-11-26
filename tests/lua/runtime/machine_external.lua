local common = require "core.common"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local MachineClient = require "core.machine_client"
local test = require "core.test"

-- Seam: External Agent threads in `anvil serve`, through the Machine protocol.
test.describe("External Agents on a Machine", function()
  local TIMEOUT = 30

  local function wait_until(predicate, message)
    local deadline = system.get_time() + TIMEOUT
    while system.get_time() < deadline do
      if predicate() then return end
      coroutine.yield(0.01)
    end
    test.fail(message)
  end

  local function begin(client, method, params)
    local request = {}
    client:request(method, params, nil, function(err, result) request.done, request.err, request.result = true, err, result end)
    return request
  end

  local function finish(request, method)
    wait_until(function() return request.done end, "No reply to " .. method)
    return request.err, request.result
  end

  local function call(client, method, params) return finish(begin(client, method, params), method) end

  local function connect(path)
    local client = MachineClient.new(path)
    wait_until(function() return client.state == "ready" end, "The Machine did not connect: " .. tostring(client.error))
    return client
  end

  test.before_each(function(context)
    context.user = USERDIR .. PATHSEP .. "machine-external-" .. math.floor(system.get_time() * 1000000)
    context.project = context.user .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.project))
    context.server = machine_server.start(context.user, {context.project})
    context.owner = connect(machine_server.discovery_path(context.user))
  end)

  test.after_each(function(context)
    for _, name in ipairs {"owner", "device"} do
      if context[name] then context[name]:close() end
    end
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.user))
  end)

  test.it("wakes a waiting agent with a message, and finds its answer by request", function(context)
    local project = context.project
    local err, first = call(context.owner, "external.read", {project = project, agent = "agy", listen = true})
    test.is_nil(err)
    test.equal(#first.messages, 0)
    test.ok(first.listening)

    local waiting = begin(context.owner, "external.read", {project = project, agent = "agy", listen = true, wait = true,
      after = first.cursor})
    local deadline = system.get_time() + 0.5
    while system.get_time() < deadline do
      test.not_ok(waiting.done, "A wait without messages answered")
      coroutine.yield(0.05)
    end
    local posted
    err, posted = call(context.owner, "external.post", {project = project, agent = "agy", text = "Check the tests",
      from = {kind = "agent", name = "brave-otter", terminal = string.rep("a", 32)}})
    test.is_nil(err)
    local _, woken = finish(waiting, "external.read")
    test.equal(#woken.messages, 1)
    test.equal(woken.messages[1].text, "Check the tests")
    test.equal(woken.messages[1].from.name, "brave-otter")
    test.equal(woken.messages[1].request, posted.request)

    -- The agent does not read its own answer. The thread keeps both, in order.
    test.is_nil(call(context.owner, "external.post", {project = project, agent = "agy", text = "All green",
      reply_to = posted.request, from = {kind = "self"}}))
    local _, next_page = call(context.owner, "external.read", {project = project, agent = "agy", listen = true,
      after = woken.cursor})
    test.equal(#next_page.messages, 0)
    test.equal(next_page.cursor, 2)
    local _, thread = call(context.owner, "external.read", {project = project, agent = "agy"})
    test.equal(#thread.messages, 2)
    test.equal(thread.messages[2].from.kind, "self")
    test.is_nil(thread.messages[2].request)
    local _, answer = call(context.owner, "external.read", {project = project, agent = "agy", reply_to = posted.request})
    test.equal(#answer.messages, 1)
    test.equal(answer.messages[1].text, "All green")

    local _, list = call(context.owner, "external.list", {project = project})
    test.equal(#list.agents, 1)
    test.equal(list.agents[1].name, "agy")
    test.ok(list.agents[1].listening)
  end)

  test.it("tells a waiting View when the agent reads a message", function(context)
    local project = context.project
    local _, first = call(context.owner, "external.read", {project = project, agent = "agy", listen = true})
    test.equal(first.read, 0)
    test.is_nil(call(context.owner, "external.post", {project = project, agent = "agy", text = "Unread for now",
      from = {kind = "user"}}))
    local _, shown = call(context.owner, "external.read", {project = project, agent = "agy"})
    test.equal(shown.read, 0, "A View's read must not mark messages as read")

    local view = begin(context.owner, "external.read", {project = project, agent = "agy", wait = true,
      after = shown.cursor})
    local _, received = call(context.owner, "external.read", {project = project, agent = "agy", listen = true,
      after = first.cursor})
    test.equal(#received.messages, 1)
    test.equal(received.read, received.cursor)
    local _, woken = finish(view, "external.read")
    test.equal(#woken.messages, 0)
    test.equal(woken.read, received.cursor)
  end)

  test.it("refuses unknown agents, other Projects and invalid messages", function(context)
    local err = call(context.owner, "external.read", {project = context.project, agent = "agy"})
    test.equal(err.code, "not_found")
    err = call(context.owner, "external.post", {project = context.project, agent = "agy", text = "hello"})
    test.equal(err.code, "not_found")
    err = call(context.owner, "external.read", {project = context.project .. "-other", agent = "agy", listen = true})
    test.equal(err.code, "outside_project")
    err = call(context.owner, "external.read", {project = context.project, agent = "../agy", listen = true})
    test.equal(err.code, "invalid_request")
    test.is_nil(call(context.owner, "external.read", {project = context.project, agent = "agy", listen = true}))
    err = call(context.owner, "external.post", {project = context.project, agent = "agy", text = "  "})
    test.equal(err.code, "invalid_request")
  end)

  test.it("lets a View device read a thread but not post or register", function(context)
    test.is_nil(call(context.owner, "external.read", {project = context.project, agent = "agy", listen = true}))
    test.is_nil(call(context.owner, "external.post", {project = context.project, agent = "agy", text = "hello",
      from = {kind = "user"}}))
    local _, pairing = call(context.owner, "pairing.start", {level = "view"})
    local discovery = machine_server.wait_discovery(context.user, context.server)
    local paired, path
    MachineClient.pair("127.0.0.1", discovery.port, pairing.code, "Phone", function(e, record) paired, path = e or true, record end)
    wait_until(function() return paired end, "The device did not pair")
    test.ok(path, paired)
    context.device = connect(path)

    local err, thread = call(context.device, "external.read", {project = context.project, agent = "agy"})
    test.is_nil(err)
    test.equal(thread.messages[1].text, "hello")
    err = call(context.device, "chat.recipients", {project = context.project})
    test.equal(err.code, "forbidden")
    err = call(context.device, "chat.send", {project = context.project, recipient = {external = "agy"}, text = "hello"})
    test.equal(err.code, "forbidden")
    err = call(context.device, "external.post", {project = context.project, agent = "agy", text = "from the phone"})
    test.equal(err.code, "forbidden")
    err = call(context.device, "external.read", {project = context.project, agent = "other", listen = true})
    test.equal(err.code, "forbidden")
  end)

  test.it("keeps threads and cursors when the Machine restarts", function(context)
    test.is_nil(call(context.owner, "external.read", {project = context.project, agent = "agy", listen = true}))
    test.is_nil(call(context.owner, "external.post", {project = context.project, agent = "agy", text = "before restart",
      from = {kind = "user"}}))
    -- The server writes the thread within a second.
    local deadline = system.get_time() + 2
    while system.get_time() < deadline do coroutine.yield(0.05) end
    context.owner:close()
    machine_server.stop(context.server)
    context.server = machine_server.start(context.user, {context.project})
    context.owner = connect(machine_server.discovery_path(context.user))

    local err, thread = call(context.owner, "external.read", {project = context.project, agent = "agy"})
    test.is_nil(err)
    test.equal(#thread.messages, 1)
    test.equal(thread.messages[1].text, "before restart")
    test.is_nil(call(context.owner, "external.post", {project = context.project, agent = "agy", text = "after restart",
      from = {kind = "user"}}))
    local _, page = call(context.owner, "external.read", {project = context.project, agent = "agy", listen = true, after = 1})
    test.equal(#page.messages, 1)
    test.equal(page.messages[1].seq, 2)
  end)
end)
