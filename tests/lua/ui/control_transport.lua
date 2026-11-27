local core = require "core"
local command = require "core.command"
local dialog = require "core.ui.dialog"
local http = require "core.http"
local json = require "core.json"
local test = require "core.test"

-- Seam: the dialog reads the discovery file of the Machine server's MCP server. This process stands for the server.
test.describe("Anvil MCP Server Dialog", function()
  local mcp = USERDIR .. PATHSEP .. "machine" .. PATHSEP .. "mcp.json"

  test.before_each(function(context)
    context.clipboard = system.get_clipboard()
    context.enabled = os.getenv("ANVIL_CONTROL")
    system.setenv("ANVIL_CONTROL", "1")
    os.remove(mcp)
  end)

  test.after_each(function(context)
    local open = dialog.current()
    if open then open:close() end
    os.remove(mcp)
    system.setenv("ANVIL_CONTROL", context.enabled or "")
    system.set_clipboard(context.clipboard or "")
  end)

  local function publish()
    require("core.common").mkdirp(USERDIR .. PATHSEP .. "machine")
    local file = assert(io.open(mcp, "wb"))
    file:write(json.encode {version = 1, url = "http://127.0.0.1:49999", token = string.rep("f", 64),
      pid = system.get_process_id(), created = system.get_process_creation_time()})
    file:close()
  end

  local function open_dialog()
    test.ok(command.perform("anvil:mcp_server"))
    local open = dialog.current()
    test.not_nil(open)
    dialog.update()
    return open
  end

  local function wait_for(open, label)
    local deadline = system.get_time() + 15
    repeat
      coroutine.yield()
      dialog.update()
    until open.status.label == label or system.get_time() > deadline
    test.equal(open.status.label, label)
  end

  test.it("shows the live endpoint and copies setup instructions for all Projects without the token", function()
    local open = open_dialog()
    wait_for(open, "Unavailable")
    test.contains(open.reason.text, "Machine server is not running")
    test.not_ok(open.copy.enabled)
    publish()
    wait_for(open, "Ready")

    test.equal(open.discovery.text, mcp)
    test.equal(open.url.text, "http://127.0.0.1:49999/mcp")
    test.ok(open.copy:activate())
    local text = system.get_clipboard()
    local config = json.decode(text:match("\n(%b{})\n"))
    local args = config.mcpServers.anvil.args
    test.ok(system.get_file_info(args[1]), "The setup must name the installed MCP bridge")
    test.same({args[2], args[3], args[4]}, {"--userdir", system.absolute_path(USERDIR), nil},
      "One entry serves all Projects, so it names none")
    test.contains(text, "external_agent")
    test.contains(text, core.root_project().path)
    test.not_ok(text:find(string.rep("f", 64), 1, true), "The clipboard must not contain the token")

    os.remove(mcp)
    wait_for(open, "Unavailable")
    test.not_ok(open.copy:activate())
    test.equal(system.get_clipboard(), text)
  end)

  test.it("shows when the server is disabled", function()
    system.setenv("ANVIL_CONTROL", "0")
    publish()
    local open = open_dialog()
    test.equal(open.status.label, "Disabled")
    test.not_ok(open.copy.enabled)
  end)
end)

-- Seam: listener startup when the OS rejects a range of ports or every bind.
test.describe("Anvil control listener", function()
  test.it("opens outside an unavailable port range", function()
    local net = require "net"
    local create, random = net.create_server, net.random_token
    net.random_token = function() return string.rep("0", 64) end
    net.create_server = function(address, port)
      if port >= 49152 and port <= 50175 then return nil, "Port range unavailable" end
      return create(address, port)
    end
    local ok, server = pcall(require("core.control_server").open)
    net.create_server, net.random_token = create, random
    test.ok(ok, server)
    local port = server.listener:get_port()
    server:close()
    test.ok(port < 49152 or port > 50175)
  end)

  test.it("reports the bind error when no listener can open", function()
    local net = require "net"
    local create = net.create_server
    net.create_server = function() return nil, "Bind denied by test policy" end
    local ok, err = pcall(require("core.control_server").open)
    net.create_server = create
    if ok then err:close() end
    test.equal(ok, false)
    test.contains(err, "Bind denied by test policy")
  end)
end)

-- Anvil's MCP server for one Project of this process, as the Machine server opens it for its Projects.
local function open_hub()
  local control = require("core.control").new()
  local server = require("core.control_server").open(nil, {
    control = function(project) return require("core.common").path_equals(project, control.project) and control or nil end,
    project_of = function(caller) return caller ~= "local" and control.project or nil end,
    tick = function() control:tick() end,
  })
  return server, control
end

-- Seam: authenticated MCP over a real loopback connection.
test.describe("Anvil MCP", function()
  test.it("reads conversation pages through Pi without creating agent tasks or changing focus", function()
    local server, control = open_hub()
    local endpoint = server:add_client("reader-target")
    local headers = {Authorization = "Bearer " .. server.token}
    local agent_headers = {Authorization = "Bearer " .. endpoint.token}
    local function begin(path, message, auth)
      local request = {}
      http.post(server.url .. path, "application/json", message, {headers = auth, on_done = function(ok, err, body)
        request.done, request.ok, request.body, request.error = true, ok, body, err
      end})
      return request
    end
    local function wait(request)
      local deadline = system.get_time() + 15
      repeat server:poll(); coroutine.yield() until request.done or system.get_time() > deadline
      test.ok(request.done and request.ok, request.error or "MCP response timed out")
      return request.body
    end
    local function exchange(extra)
      local report = {instance = "pi-one", busy = true, receipts = {}, tasks = {}, capabilities = {transcript = true}}
      for key, value in pairs(extra or {}) do report[key] = value end
      return wait(begin("/agent", report, agent_headers))
    end
    local function read(args)
      args.project = control.project
      return begin("/mcp", {jsonrpc = "2.0", id = 1, method = "tools/call",
        params = {name = "agent_transcript", arguments = args}}, headers)
    end
    local focused = core.active_view
    local ok, err = pcall(function()
      exchange()
      local request = read {terminal = "reader-target", instance = "pi-one", limit = 2, include_tools = true, format = "json"}
      local queries
      local deadline = system.get_time() + 15
      repeat queries = exchange().transcript_requests until queries and #queries > 0 or system.get_time() > deadline
      test.ok(queries and #queries == 1, "Pi did not receive a conversation read")
      test.equal(queries[1].options.limit, 2)
      test.ok(queries[1].options.include_tools)
      local reply = exchange {transcripts = {{id = queries[1].id, result = {
        messages = {{id = "message-a", role = "user", text = "Review this", timestamp = "2026-01-01T00:00:00Z"}},
        next_before = "message-a", active_turn = true, truncated = false,
      }}}}
      test.equal(reply.transcript_acks[1], queries[1].id)
      test.equal(#reply.commands, 0)
      local result = wait(request).result
      test.equal(result.isError, false)
      test.equal(result.structuredContent.messages[1].text, "Review this")
      test.equal(result.structuredContent.terminal, "reader-target")
      test.equal(result.structuredContent.instance, "pi-one")
      test.equal(result.structuredContent.next_before, "message-a")
      test.equal(core.active_view, focused)
      -- Text goes to the model without JSON escaping. A read without an instance names the conversation.
      local text_request = read {terminal = "reader-target"}
      deadline = system.get_time() + 15
      repeat queries = exchange().transcript_requests until #queries > 0 or system.get_time() > deadline
      test.ok(#queries > 0, "Pi did not receive the text conversation read")
      exchange {transcripts = {{id = queries[1].id, result = {text = '[a 00:00:00 user]\n{"x":1}'}}}}
      result = wait(text_request).result
      test.equal(result.content[1].text, 'instance pi-one\n[a 00:00:00 user]\n{"x":1}')
      test.is_nil(result.structuredContent)
      local invalid = wait(read {terminal = "reader-target", instance = "pi-one", offset = 4})
      test.ok(invalid.result.isError, "An offset needs an entry ID")
      local oversized = read {terminal = "reader-target", instance = "pi-one"}
      deadline = system.get_time() + 15
      repeat queries = exchange().transcript_requests until #queries > 0 or system.get_time() > deadline
      test.ok(#queries > 0, "Pi did not receive the oversized conversation read")
      reply = exchange {transcripts = {{id = queries[1].id, result = {
        messages = {}, session_name = string.rep("x", 300 * 1024),
      }}}}
      test.equal(reply.transcript_acks[1], queries[1].id)
      local rejected = wait(oversized).result
      test.ok(rejected.isError, "An oversized reply must fail only its conversation read")
      test.contains(rejected.content[1].text, "too large")
      local pending = read {terminal = "reader-target", instance = "pi-one"}
      deadline = system.get_time() + 15
      repeat queries = exchange().transcript_requests until #queries > 0 or system.get_time() > deadline
      test.ok(#queries > 0, "Pi did not receive the second conversation read")
      exchange {instance = "pi-two"}
      test.ok(wait(pending).result.isError, "A replacement conversation must end the pending read")
      server:remove_client(endpoint.token)
      local status = control:call("agent_read", {terminal = "reader-target", instance = "pi-two"})
      test.equal(status.connected, false)
      test.equal(status.activity_stale, true)
      test.ok(wait(read {terminal = "reader-target", instance = "pi-two"}).result.isError)
    end)
    server:close()
    assert(ok, err)
  end)

  test.it("discovers tools and refuses unauthorized or browser requests", function()
    local server = require("core.control_server").open()
    local function post(path, message, headers)
      local done, result, info, success
      http.post(server.url .. path, "application/json", message, {headers = headers,
        on_done = function(ok, err, body, response) success, result, info, done = ok, body or err, response, true end})
      local deadline = system.get_time() + 15
      repeat server:poll(); coroutine.yield() until done or system.get_time() > deadline
      test.ok(done, "MCP response timed out")
      return success, result, info
    end
    local ok, err = pcall(function()
      local headers = {Authorization = "Bearer " .. server.token}
      local success, result = post("/mcp", {jsonrpc = "2.0", id = 1, method = "initialize",
        params = {protocolVersion = "2025-06-18", capabilities = {}, clientInfo = {name = "test", version = "1"}}}, headers)
      test.ok(success)
      test.equal(result.result.protocolVersion, "2025-06-18")
      success, result = post("/mcp", {jsonrpc = "2.0", id = 2, method = "tools/list"}, headers)
      test.ok(success)
      test.ok(#result.result.tools >= 2)
      success, result = post("/mcp", {jsonrpc = "2.0", id = 3, method = "tools/call",
        params = {name = "workspace_state", arguments = {}}}, headers)
      test.ok(success)
      test.equal(result.result.isError, false)
      test.ok(result.result.structuredContent.panes)
      success, result = post("/mcp", {jsonrpc = "2.0", id = "memory", method = "tools/call",
        params = {name = "memory_report", arguments = {}}}, headers)
      test.ok(success)
      test.equal(result.result.isError, false)
      test.equal(result.result.structuredContent.pid, system.get_process_id())
      test.equal(result.result.structuredContent.collected, false)
      success = post("/mcp", {jsonrpc = "2.0", id = 4, method = "tools/list"}, {})
      test.equal(success, false)
      headers.Origin = "https://example.com"
      success = post("/mcp", {jsonrpc = "2.0", id = 5, method = "tools/list"}, headers)
      test.equal(success, false)
      headers.Origin = nil
      local endpoint = server:add_client("test-terminal")
      local agent_headers = {Authorization = "Bearer " .. endpoint.token}
      success = post("/agent", {instance = "test-instance", receipts = {}, tasks = {}}, agent_headers)
      test.ok(success)
      server:remove_client(endpoint.token)
      success = post("/agent", {instance = "test-instance", receipts = {}, tasks = {}}, agent_headers)
      test.equal(success, false)
      test.equal(server.control:call("agent_read", {terminal = "test-terminal", instance = "test-instance"}).connected, false,
        "A revoked agent must not appear connected")
      -- This private endpoint answers only editor operations. Anvil's MCP server answers agent operations.
      success, result = post("/mcp", {jsonrpc = "2.0", id = 6, method = "tools/call",
        params = {name = "agent_read", arguments = {terminal = "test-terminal"}}}, headers)
      test.ok(success)
      test.ok(result.result.isError)
      test.contains(result.result.content[1].text, "MCP server")
    end)
    server:close()
    assert(ok, err)
  end)
end)

-- Seam: Anvil's MCP server routes editor operations to the private endpoint of the named Project process.
test.describe("Anvil Project routing", function()
  test.it("sends editor operations to the named Project past records of ended processes, and removes them", function()
    local Control = require "core.control"
    local Server = require "core.control_server"
    local other = USERDIR .. "/other-project"
    local remote = Server.open(Control.new(other))
    local terminals = {["pi-terminal"] = other}
    local hub = Server.open(nil, {control = function() end, project_of = function(caller) return terminals[caller] end,
      tick = function() end})
    local own = Server.open()
    local common = require "core.common"
    common.mkdirp(USERDIR .. PATHSEP .. "control" .. PATHSEP .. "terminals")
    local function record(name, value)
      local file = assert(io.open(USERDIR .. "/control/" .. name, "wb"))
      file:write(json.encode(value)); file:close()
      return USERDIR .. "/control/" .. name
    end
    local function endpoint(url, token, pid, created)
      return {version = 1, url = url, token = token, project = other, executable = EXEFILE, pid = pid, created = created}
    end
    local pid, created = system.get_process_id(), system.get_process_creation_time()
    local stale_url, stale_token = "http://127.0.0.1:9", string.rep("a", 64)
    local path = record("987654320.json", endpoint(remote.url, remote.token, pid, created))
    -- A crash leaves the record of a process that ended, or whose ID Windows gave to another process.
    local ended = record("987654324.json", endpoint(stale_url, stale_token, 987654324, "01d0000000000000"))
    local reused = record("987654328.json", endpoint(stale_url, stale_token, pid, "01d0000000000000"))
    local stale_terminal = record("terminals/" .. string.rep("5", 32) .. ".json", {version = 1, url = stale_url, token = stale_token})
    local live_terminal = record("terminals/" .. string.rep("6", 32) .. ".json", {version = 1, url = remote.url, token = stale_token})
    local pi = hub:add_client("pi-terminal")
    local function call(server, name, args, token)
      local done, result, failure
      http.post(server.url .. "/mcp", "application/json", {jsonrpc = "2.0", id = 7, method = "tools/call",
        params = {name = name, arguments = args}}, {headers = {Authorization = "Bearer " .. (token or server.token)},
        on_done = function(success, error, body) done, result, failure = true, body, not success and error end})
      local deadline = system.get_time() + 20
      repeat hub:poll(); remote:poll(); own:poll(); coroutine.yield() until done or system.get_time() > deadline
      test.ok(done and not failure, failure or "Project request timed out")
      return result.result
    end
    local ok, err = pcall(function()
      local result = call(hub, "workspace_state", {project = other})
      test.equal(result.isError, false, result.content and result.content[1].text)
      test.equal(result.structuredContent.project, other)
      test.not_equal(core.root_project().path, other)
      test.not_ok(system.get_file_info(ended), "The record of an ended process must be removed")
      test.not_ok(system.get_file_info(reused), "The record of a reused process ID must be removed")
      test.not_ok(system.get_file_info(stale_terminal), "Terminal records of an ended endpoint must be removed")
      test.ok(system.get_file_info(path), "The live record must stay")
      test.ok(system.get_file_info(live_terminal), "Terminal records of a live endpoint must stay")

      -- A Pi's call goes to its own Project, and the Project process learns which Terminal called.
      result = call(hub, "workspace_state", {}, pi.token)
      test.equal(result.structuredContent.project, other)
      test.equal(result.structuredContent.caller_terminal, "pi-terminal")

      -- A client without a Terminal names the Project. Without one, it learns the loaded Projects.
      result = call(hub, "workspace_state", {})
      test.not_nil(result.structuredContent.projects[other], "The loaded Projects must include the other Project")
      test.is_nil(result.structuredContent.panes)
      result = call(hub, "agent_read", {terminal = "pi-terminal"})
      test.ok(result.isError)
      test.contains(result.content[1].text, "Name the Project")

      -- A Project process answers only for itself. Anvil's MCP server reaches the other Projects.
      result = call(own, "workspace_state", {project = other})
      test.ok(result.isError)
      test.contains(result.content[1].text, "MCP server")
    end)
    hub:close(); remote:close(); own:close()
    for _, name in ipairs {path, ended, reused, stale_terminal, live_terminal} do os.remove(name) end
    assert(ok, err)
  end)
end)

-- Seam: External Agents through MCP, with their threads on this PC's own Machine server.
test.describe("External Agents through MCP", function()
  local machine_server = dofile("tests/fixtures/machine_server.lua")
  local common = require "core.common"
  local agent_name = require "core.agent_name"

  test.before_each(function(context)
    context.project = USERDIR .. PATHSEP .. "external-agents-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.project))
    context.machine = machine_server.start(USERDIR, {context.project})
    -- This process stands for the Machine server: its Anvil MCP server knows one Project with one Pi.
    context.control = require("core.control").new(context.project)
    context.server = require("core.control_server").open(nil, {
      control = function(project) return common.path_equals(project, context.project) and context.control or nil end,
      project_of = function(caller) return caller == "pi-terminal" and context.project or nil end,
      tick = function() context.control:tick() end,
    })
    context.pi = context.server:add_client("pi-terminal")
    core.add_thread(function()
      while context.server.listener do context.server:poll(); coroutine.yield(.01) end
    end)
  end)

  test.after_each(function(context)
    context.server:close()
    machine_server.stop(context.machine)
    test.ok(test.remove_tree(context.project))
  end)

  local function wait_until(predicate, message)
    local deadline = system.get_time() + 30
    while system.get_time() < deadline do
      if predicate() then return end
      coroutine.yield(.02)
    end
    test.fail(message)
  end

  -- A client without a Terminal names the Project. A Pi's calls use its own Project.
  local function begin(context, name, args, token)
    if not token then args.project = args.project or context.project end
    local request = {}
    http.post(context.server.url .. "/mcp", "application/json", {jsonrpc = "2.0", id = 1, method = "tools/call",
      params = {name = name, arguments = args}}, {headers = {Authorization = "Bearer " .. (token or context.server.token)},
      on_done = function(ok, err, body) request.done, request.ok, request.body, request.error = true, ok, body, err end})
    return request
  end

  local function finish(request)
    wait_until(function() return request.done end, "MCP response timed out")
    test.ok(request.ok, request.error)
    local result = request.body.result
    test.not_ok(result.isError, result.content[1].text)
    return result.structuredContent
  end

  local function tool(context, name, args, token) return finish(begin(context, name, args, token)) end

  local function pi_commands(context, report)
    report = report or {}
    report.instance, report.receipts, report.tasks = "pi-one", report.receipts or {}, {}
    return context.control:exchange("pi-terminal", report).commands
  end

  test.it("carries a Pi's message to a waiting External Agent and its answer back", function(context)
    pi_commands(context)
    local first = tool(context, "external_agent", {action = "wait", agent = "agy", timeout_ms = 0})
    test.equal(#first.messages, 0)
    local waiting = begin(context, "external_agent", {action = "wait", agent = "agy", after = first.cursor})
    local sent = tool(context, "agent_send", {agent = "agy", text = "Check the tests"}, context.pi.token)
    test.equal(sent.status, "delivered")
    local page = finish(waiting)
    test.equal(page.messages[1].text, "Check the tests")
    test.equal(page.messages[1].request, sent.task)
    test.equal(page.messages[1].from.name, agent_name.for_terminal("pi-terminal"))

    tool(context, "external_agent", {action = "say", agent = "agy", text = "All green", reply_to = sent.task})
    local reply
    wait_until(function()
      reply = pi_commands(context)[1]
      return reply ~= nil
    end, "The Pi did not receive the External Agent's answer")
    test.equal(reply.action, "reply")
    test.equal(reply.reply_to, sent.task)
    test.equal(reply.text, "All green")
    test.equal(reply.sender.name, "agy")
    test.equal(reply.sender.external, "agy")

    local listed = tool(context, "external_agent", {action = "list"})
    test.equal(listed.agents[1].name, "agy")
    test.ok(listed.agents[1].listening)
  end)

  test.it("lets an External Agent wait and answer through Anvil's MCP server in a named Project", function(context)
    test.skip_if(PLATFORM ~= "Windows", "The Machine server runs Anvil's MCP server with its Terminal service")
    local mcp = machine_server.wait_mcp(USERDIR, context.machine)
    local function hub(args)
      local request = {}
      http.post(mcp.url .. "/mcp", "application/json", {jsonrpc = "2.0", id = 1, method = "tools/call",
        params = {name = "external_agent", arguments = args}}, {headers = {Authorization = "Bearer " .. mcp.token},
        on_done = function(ok, err, body) request.done, request.ok, request.body, request.error = true, ok, body, err end})
      wait_until(function() return request.done end, "Anvil's MCP server did not answer")
      test.ok(request.ok, request.error)
      return request.body.result
    end
    local unnamed = hub({action = "wait", agent = "agy", timeout_ms = 0})
    test.ok(unnamed.isError, "One server serves all Projects, so a call names its Project")
    test.contains(unnamed.content[1].text, "Name the Project")
    pi_commands(context)
    local first = hub({action = "wait", agent = "agy", timeout_ms = 0, project = context.project}).structuredContent
    local sent = tool(context, "agent_send", {agent = "agy", text = "Check the tests"}, context.pi.token)
    local page = hub({action = "wait", agent = "agy", after = first.cursor, project = context.project}).structuredContent
    test.equal(page.messages[1].request, sent.task)
    test.not_ok(hub({action = "say", agent = "agy", text = "All green", reply_to = sent.task,
      project = context.project}).isError)
    local reply
    wait_until(function()
      reply = pi_commands(context)[1]
      return reply ~= nil
    end, "The Pi did not receive the External Agent's answer")
    test.equal(reply.text, "All green")
  end)

  test.it("names an External Agent's message to a Pi and puts the Pi's reply in its thread", function(context)
    pi_commands(context)
    local first = tool(context, "external_agent", {action = "wait", agent = "agy", timeout_ms = 0})
    -- No instance or request ID: the message goes to the Terminal's current conversation.
    local sent = tool(context, "agent_send", {terminal = "pi-terminal", text = "Status?", from_agent = "agy"})
    local received = pi_commands(context)[1]
    test.equal(received.id, sent.task)
    test.equal(received.sender.name, "agy")
    test.equal(received.sender.external, "agy")
    local notice = tool(context, "agent_send", {terminal = "pi-terminal", text = "FYI", expect_reply = false})
    test.equal(pi_commands(context, {receipts = {{id = sent.task, status = "accepted", task = sent.task}}})[1].expect_reply,
      false)
    test.not_equal(notice.task, sent.task)

    pi_commands(context, {receipts = {{id = sent.task, status = "completed", result = "Busy with the parser"}}})
    local page = tool(context, "external_agent", {action = "wait", agent = "agy", after = first.cursor})
    test.equal(page.messages[1].text, "Busy with the parser")
    test.equal(page.messages[1].reply_to, sent.task)
    test.equal(page.messages[1].from.name, agent_name.for_terminal("pi-terminal"))
  end)
end)
