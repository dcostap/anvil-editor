local common = require "core.common"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local MachineClient = require "core.machine_client"
local machine_terminal = require "core.machine_terminal"
local test = require "core.test"

-- Seam: a Terminal Session on this PC, reached by remote sessions through `anvil serve` and the Machine protocol.
-- The server shares this test's user folder, as a Machine shares it with its own Anvil.
test.describe("Remote Terminal Session", function()
  local TIMEOUT = 30
  local ECHO_SHELL = [[powershell.exe -NoLogo -NoProfile -Command "[Console]::WriteLine('ANVIL_ECHO_READY'); ]]
    .. [[while ($true) { $l = [Console]::ReadLine(); if ($l -eq $null) { break }; [Console]::WriteLine('ECHO:' + $l) }"]]

  local function text_of(session)
    session:update()
    local parts = {}
    for _, row in ipairs(session:snapshot().rows or {}) do
      for _, run in ipairs(row.text_runs or {}) do parts[#parts + 1] = run.text end
      parts[#parts + 1] = "\n"
    end
    return table.concat(parts)
  end

  local function wait_until(predicate, message)
    local deadline = system.get_time() + TIMEOUT
    while system.get_time() < deadline do
      if predicate() then return end
      coroutine.yield(0.01)
    end
    test.fail(message)
  end

  local function wait_text(session, expected)
    wait_until(function() return text_of(session):find(expected, 1, true) end,
      "Missing " .. expected .. ":\n" .. text_of(session))
  end

  local function call(client, method, params)
    local done, err, result
    client:request(method, params, nil, function(e, r) done, err, result = true, e, r end)
    wait_until(function() return done end, "No reply to " .. method)
    return err, result
  end

  local function connect(path)
    local client = MachineClient.new(path)
    wait_until(function() return client.state == "ready" end, "The Machine did not connect: " .. tostring(client.error))
    return client
  end

  local function remote_session()
    local session = assert(require("terminal_native").new {remote = true, cols = 60, rows = 10, cell_width = 8,
      cell_height = 16})
    return session
  end

  test.before_each(function(context)
    test.skip_if(PLATFORM ~= "Windows", "Terminal hosts use ConPTY")
    context.project = USERDIR .. PATHSEP .. "machine-terminal-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.project))
    context.local_session = assert(require("terminal_native").new {cols = 80, rows = 10, cell_width = 8,
      cell_height = 16, cwd = context.project, project_path = context.project, shell = ECHO_SHELL})
    wait_text(context.local_session, "ANVIL_ECHO_READY")
    context.id = context.local_session:stats().session_id
    context.server = machine_server.start(USERDIR, {context.project})
    context.owner = connect(machine_server.discovery_path(USERDIR))
  end)

  test.after_each(function(context)
    if context.restore then context.restore() end
    if context.source then context.source:close() end
    if context.pair_path then os.remove(context.pair_path) end
    for _, name in ipairs {"remote", "viewer"} do
      if context[name] then context[name]:close() end
    end
    for _, name in ipairs {"owner", "device"} do
      if context[name] then context[name]:close() end
    end
    machine_server.stop(context.server)
    if context.local_session then
      -- A close while the server's link still shows the session only detaches it. Close the shell last.
      wait_until(function() return (select(2, context.local_session:update()).clients or 0) <= 1 end,
        "The server's link stays attached")
      context.local_session:close()
    end
    if context.project then test.ok(test.remove_tree(context.project)) end
  end)

  test.it("shows the Machine's screen, and typing takes control", function(context)
    local err, result = call(context.owner, "terminal.list", {project = context.project})
    test.is_nil(err)
    test.equal(#result.sessions, 1)
    test.equal(result.sessions[1].id, context.id)

    context.remote = remote_session()
    machine_terminal.connect(context.owner, context.remote, context.id)
    wait_text(context.remote, "ANVIL_ECHO_READY")
    -- The local View keeps control. The remote session shows its screen.
    wait_until(function() return select(2, context.remote:update()).viewer end, "The remote session is not a Viewer")

    context.remote:write("from-remote\r")
    wait_text(context.local_session, "ECHO:from-remote")
    wait_text(context.remote, "ECHO:from-remote")
    wait_until(function() return select(2, context.local_session:update()).viewer end,
      "The local View did not become a Viewer")
    wait_until(function() return not select(2, context.remote:update()).viewer end,
      "The remote session did not take control")
  end)

  test.it("answers a waiting list only when the Machine's sessions change", function(context)
    local err, first = call(context.owner, "terminal.list", {project = context.project})
    test.is_nil(err)
    local waited
    context.owner:request("terminal.list", {project = context.project, known = first.revision, wait = true}, nil,
      function(e, r) waited = e or r end)
    local deadline = system.get_time() + 1
    while system.get_time() < deadline do
      test.is_nil(waited, "An unchanged list answered")
      coroutine.yield(0.05)
    end

    local start_err, started = call(context.owner, "terminal.start", {project = context.project, cwd = context.project,
      shell = ECHO_SHELL, scrollback_lines = 1000, cols = 60, rows = 10, cell_width = 8, cell_height = 16})
    test.is_nil(start_err)
    wait_until(function() return waited end, "The waiting list did not answer the new shell")
    local ids = {}
    for _, session in ipairs(waited.sessions or {}) do ids[#ids + 1] = session.id end
    test.contains(ids, started.session_id)
    test.ok(waited.revision > first.revision)
    -- The new shell ends: nothing read it.
    test.is_nil(call(context.owner, "terminal.detach", {link = started.link}))
  end)

  test.it("resolves an agent only in its own Machine Project", function(context)
    local args = {project = context.project, terminal = context.id}
    local err = call(context.owner, "agent_read", args)
    test.equal(err.code, "not_connected") -- The running shell is not Pi.
    args.project = context.project .. "-other"
    err = call(context.owner, "agent_read", args)
    test.equal(err.code, "not_found")
  end)

  test.it("sends to a host Pi without a Pane and reads the task reply through its Machine address", function(context)
    local json = require "core.lsp.json"
    local ep
    wait_until(function()
      local f = io.open(USERDIR .. "/machine/agents/" .. context.id .. ".json", "rb")
      if f then ep = json.decode(f:read("*a")); f:close(); return true end
    end, "No host agent endpoint")
    local function post(path, message, endpoint)
      endpoint = endpoint or ep
      local done, value, failure
      require("core.http").post(endpoint.url .. path, "application/json", nil, {body = json.encode(message), decode_json = false,
        headers = {Authorization = "Bearer " .. endpoint.token, ["Content-Type"] = "application/json"}, on_done = function(ok, err, body)
          done, value, failure = true, ok and json.decode(body), err
        end})
      wait_until(function() return done end, "Host agent request timed out")
      test.ok(value, failure)
      return value
    end
    local report = {instance = "test-conversation", receipts = json.array(), tasks = json.array(), capabilities = {transcript = true}}
    post("/agent", report)
    local projects = require "core.machine_project"
    local key = projects.key(context.owner.machine, context.project)
    local _, pairing = call(context.owner, "pairing.start", {level = "full"})
    local discovery = machine_server.wait_discovery(USERDIR, context.server)
    MachineClient.pair("127.0.0.1", discovery.port, pairing.code, "Client", function(_, path) context.pair_path = path end)
    wait_until(function() return context.pair_path end, "The test Client did not pair")
    -- These processes share a test user folder. Only the simulated Client has a different Machine ID.
    local own = projects.own_id
    context.restore = function() projects.own_id = own end
    projects.own_id = function() return string.rep("0", 32) end
    context.source = require("core.control_server").open(require("core.control").new(context.project))
    local source = context.source:add_client("source-terminal")
    context.source.control:exchange("source-terminal", {instance = "source-pi", receipts = {}, tasks = {}})
    context.source.control:exchange(context.id, {instance = "wrong-local-agent", receipts = {}, tasks = {}})
    require("core").add_thread(function()
      while context.source.listener do context.source:poll(); coroutine.yield(.01) end
    end)
    local function tool(name, args)
      args.project, args.terminal = key, context.id
      local reply = post("/mcp", {jsonrpc = "2.0", id = 1, method = "tools/call", params = {name = name, arguments = args}}, source)
      test.not_ok(reply.result.isError, reply.result.content[1].text)
      return reply.result.structuredContent or reply.result.content[1].text
    end
    local state = tool("agent_read", {})
    test.equal(state.instance, report.instance)
    local task = tool("agent_send", {instance = state.instance, request_id = "ping", text = "ping"}).task
    test.equal(tool("agent_send", {instance = state.instance, request_id = "ping", text = "ping"}).task, task)
    local received = post("/agent", report).commands[1]
    test.equal(received.id, task)
    test.equal(received.text, "ping")
    -- The host derives the Agent Name from the sending Terminal.
    test.equal(received.sender.name, require("core.agent_name").for_terminal("source-terminal"))
    test.equal(received.sender.instance, "source-pi")
    test.equal(received.sender.machine, "Client")
    test.equal(received.sender.project, context.project)
    report.receipts = {{id = task, status = "accepted", task = task}}
    report.tasks = {{id = task, status = "completed", result = "pong"}}
    post("/agent", report)
    test.equal(tool("agent_wait", {instance = state.instance, task = task}).result, "pong")
    local steer = tool("agent_send", {instance = state.instance, request_id = "ask", text = "Check log"}).task
    report.receipts = {{id = steer, status = "completed", result = "One client remains"}}
    post("/agent", report)
    test.equal(tool("agent_wait", {instance = state.instance, task = steer}).result, "One client remains")
    local interrupt = tool("agent_interrupt", {instance = state.instance, request_id = "interrupt"})
    test.equal(post("/agent", report).commands[1].id, interrupt.task)
    local transcript
    require("core").add_thread(function() transcript = tool("agent_transcript", {instance = state.instance}) end)
    local query
    wait_until(function()
      query = post("/agent", report).transcript_requests[1]
      return query
    end, "Pi did not receive the transcript request")
    report.transcripts = {{id = query.id, result = {text = "conversation on the host"}}}
    post("/agent", report)
    wait_until(function() return transcript end, "Missing conversation reply")
    test.equal(transcript, "conversation on the host")
  end)

  test.it("keeps the shell when a device closes it while another device shows it", function(context)
    context.remote = remote_session()
    machine_terminal.connect(context.owner, context.remote, context.id)
    wait_text(context.remote, "ANVIL_ECHO_READY")
    local function clients(session) return select(2, session:update()).clients end
    wait_until(function() return clients(context.local_session) == 2 and clients(context.remote) == 2 end,
      "The sessions do not count two Clients")
    local record = load(require("terminal_native").read_session_record(context.id), "=record", "t", {})()

    -- The close only detaches this device. The other device keeps the shell.
    context.remote:close()
    context.remote = nil
    wait_until(function() return clients(context.local_session) == 1 end, "The local session still counts the closed device")
    context.local_session:write("after-close\r")
    wait_text(context.local_session, "ECHO:after-close")

    -- The last close ends the shell.
    context.local_session:close()
    context.local_session = nil
    local alive = require("terminal_link").host_alive
    wait_until(function() return not alive(record.host_pid, record.host_creation_time) end,
      "The last close did not end the shell")
  end)

  test.it("attaches again with a new snapshot after the Machine restarts", function(context)
    context.remote = remote_session()
    machine_terminal.connect(context.owner, context.remote, context.id)
    wait_text(context.remote, "ANVIL_ECHO_READY")

    machine_server.stop(context.server)
    context.local_session:write("while-offline\r")
    wait_text(context.local_session, "ECHO:while-offline")
    context.server = machine_server.start(USERDIR, {context.project})
    wait_text(context.remote, "ECHO:while-offline")

    context.remote:write("after-restart\r")
    wait_text(context.local_session, "ECHO:after-restart")
  end)

  test.it("ends a new shell when its device detaches before it reads the shell", function(context)
    local err, result = call(context.owner, "terminal.start", {project = context.project, cwd = context.project,
      shell = ECHO_SHELL, scrollback_lines = 1000, cols = 60, rows = 10, cell_width = 8, cell_height = 16})
    test.is_nil(err)
    local text = require("terminal_native").read_session_record(result.session_id)
    local record = text and load(text, "=record", "t", {})()
    test.ok(record, "The new shell has no record")
    test.ok(common.path_equals(record.project_path, context.project))
    -- A lost reply looks the same to the Machine. Nothing else knows the new shell.
    test.is_nil(call(context.owner, "terminal.detach", {link = result.link}))
    local alive = require("terminal_link").host_alive
    wait_until(function() return not alive(record.host_pid, record.host_creation_time) end,
      "The Machine kept the unread shell")
  end)

  test.it("does not let a View device type", function(context)
    local err, result = call(context.owner, "pairing.start", {level = "view"})
    test.is_nil(err)
    local discovery = machine_server.wait_discovery(USERDIR, context.server)
    local paired, path
    MachineClient.pair("127.0.0.1", discovery.port, result.code, "Phone", function(pair_err, record)
      paired, path = pair_err or true, record
    end)
    wait_until(function() return paired end, "The device did not pair")
    test.ok(path, paired)
    context.device = connect(path)

    local denied = call(context.device, "agent_send", {project = context.project, terminal = context.id,
      instance = "old", text = "must not arrive", request_id = "view-only"})
    test.equal(denied.code, "forbidden")

    context.viewer = remote_session()
    machine_terminal.connect(context.device, context.viewer, context.id)
    wait_text(context.viewer, "ANVIL_ECHO_READY")
    context.viewer:write("from-viewer\r")
    context.local_session:write("from-local\r")
    wait_text(context.viewer, "ECHO:from-local")
    test.not_ok(text_of(context.local_session):find("from-viewer", 1, true))
    test.ok(select(2, context.viewer:update()).viewer)
  end)
end)
