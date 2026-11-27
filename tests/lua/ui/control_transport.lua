local core = require "core"
local command = require "core.command"
local dialog = require "core.ui.dialog"
local http = require "core.http"
local json = require "core.json"
local test = require "core.test"

test.describe("Anvil MCP Server Dialog", function()
  local runtime = require "core.control_runtime"

  test.before_each(function(context)
    context.clipboard = system.get_clipboard()
    context.enabled = os.getenv("ANVIL_CONTROL")
    context.create_server = require("net").create_server
    system.setenv("ANVIL_CONTROL", "1")
  end)

  test.after_each(function(context)
    local open = dialog.current()
    if open then open:close() end
    runtime.stop()
    require("net").create_server = context.create_server
    system.setenv("ANVIL_CONTROL", context.enabled or "")
    system.set_clipboard(context.clipboard or "")
  end)

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

  test.it("shows the live endpoint and copies setup instructions without the token", function()
    runtime.start()
    local open = open_dialog()
    test.equal(open.status.label, "Starting")
    test.not_ok(open.copy.enabled)
    wait_for(open, "Ready")

    local file = assert(io.open(open.discovery.text, "rb"))
    local record = file:read("*a")
    file:close()
    local endpoint = json.decode(record)
    test.equal(open.project.text, endpoint.project)
    test.equal(open.url.text, endpoint.url .. "/mcp")
    test.ok(open.copy:activate())
    local text = system.get_clipboard()
    local config = json.decode(text:match("\n(%b{})\n"))
    local args = config.mcpServers.anvil.args
    test.ok(system.get_file_info(args[1]), "The setup must name the installed MCP bridge")
    test.equal(args[3], system.absolute_path(USERDIR))
    test.equal(args[5], endpoint.project)
    test.contains(text, "external_agent")
    test.not_ok(text:find(endpoint.token, 1, true), "The clipboard must not contain the token")

    runtime.stop()
    dialog.update()
    test.equal(open.status.label, "Unavailable")
    test.not_ok(open.copy:activate())
    test.equal(system.get_clipboard(), text)
  end)

  test.it("shows why setup is unavailable when the listener cannot open", function()
    require("net").create_server = function() return nil, "Bind denied by test policy" end
    runtime.start()
    local open = open_dialog()
    wait_for(open, "Unavailable")
    test.contains(open.reason.text, "Bind denied by test policy")
    test.not_ok(open.copy.enabled)
  end)

  test.it("shows when the server is disabled", function()
    system.setenv("ANVIL_CONTROL", "0")
    runtime.start()
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

-- Seam: authenticated MCP over a real loopback connection.
test.describe("Anvil MCP", function()
  test.it("reads conversation pages through Pi without creating agent tasks or changing focus", function()
    local server = require("core.control_server").open()
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
      local status = server.control:call("agent_read", {terminal = "reader-target", instance = "pi-two"})
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
      success, result = post("/mcp", {jsonrpc = "2.0", id = 6, method = "tools/call",
        params = {name = "agent_read", arguments = {terminal = "test-terminal", instance = "test-instance"}}}, headers)
      test.ok(success)
      test.equal(result.result.structuredContent.connected, false, "A revoked agent must not appear connected")
    end)
    server:close()
    assert(ok, err)
  end)
end)

test.describe("Anvil Project routing", function()
  test.it("routes an explicit Project past records of ended processes, and removes them", function()
    local Control = require "core.control"
    local Server = require "core.control_server"
    local remote = Server.open(Control.new(USERDIR .. "/other-project"))
    local source = Server.open()
    local common = require "core.common"
    common.mkdirp(USERDIR .. PATHSEP .. "control" .. PATHSEP .. "terminals")
    local function record(name, value)
      local file = assert(io.open(USERDIR .. "/control/" .. name, "wb"))
      file:write(json.encode(value)); file:close()
      return USERDIR .. "/control/" .. name
    end
    local function endpoint(url, token, pid, created)
      return {version = 1, url = url, token = token, project = USERDIR .. "/other-project",
        executable = EXEFILE, pid = pid, created = created}
    end
    local pid, created = system.get_process_id(), system.get_process_creation_time()
    local stale_url, stale_token = "http://127.0.0.1:9", string.rep("a", 64)
    local path = record("987654320.json", endpoint(remote.url, remote.token, pid, created))
    -- A crash leaves the record of a process that ended, or whose ID Windows gave to another process.
    local ended = record("987654324.json", endpoint(stale_url, stale_token, 987654324, "01d0000000000000"))
    local reused = record("987654328.json", endpoint(stale_url, stale_token, pid, "01d0000000000000"))
    local stale_terminal = record("terminals/" .. string.rep("5", 32) .. ".json", {version = 1, url = stale_url, token = stale_token})
    local live_terminal = record("terminals/" .. string.rep("6", 32) .. ".json", {version = 1, url = remote.url, token = stale_token})
    local ok, err = pcall(function()
      local done, result, failure
      http.post(source.url .. "/mcp", "application/json", {jsonrpc = "2.0", id = 7, method = "tools/call",
        params = {name = "workspace_state", arguments = {project = USERDIR .. "/other-project"}}}, {
        headers = {Authorization = "Bearer " .. source.token},
        on_done = function(success, error, body) done, result, failure = true, body, not success and error end})
      local deadline = system.get_time() + 20
      repeat source:poll(); remote:poll(); coroutine.yield() until done or system.get_time() > deadline
      test.ok(done and not failure, failure or "Project request timed out")
      test.equal(result.result.isError, false, result.result.content and result.result.content[1].text)
      test.equal(result.result.structuredContent.project, USERDIR .. "/other-project")
      test.not_equal(core.root_project().path, USERDIR .. "/other-project")
      test.not_ok(system.get_file_info(ended), "The record of an ended process must be removed")
      test.not_ok(system.get_file_info(reused), "The record of a reused process ID must be removed")
      test.not_ok(system.get_file_info(stale_terminal), "Terminal records of an ended endpoint must be removed")
      test.ok(system.get_file_info(path), "The live record must stay")
      test.ok(system.get_file_info(live_terminal), "Terminal records of a live endpoint must stay")
      -- Empty arrays must survive both the target response and Project forwarding.
      remote.control:exchange("remote-pi", {instance = "pi-one", receipts = {}, tasks = {}, capabilities = {transcript = true}})
      done, result, failure = nil, nil, nil
      http.post(source.url .. "/mcp", "application/json", {jsonrpc = "2.0", id = 8, method = "tools/call",
        params = {name = "agent_transcript", arguments = {project = USERDIR .. "/other-project", terminal = "remote-pi", instance = "pi-one"}}}, {
        headers = {Authorization = "Bearer " .. source.token}, decode_json = false,
        on_done = function(success, error, body) done, result, failure = true, body, not success and error end})
      deadline = system.get_time() + 20
      local protocol_json = require "core.lsp.json"
      repeat
        source:poll(); remote:poll()
        local queries = remote.control:exchange("remote-pi", {instance = "pi-one", receipts = {}, tasks = {},
          capabilities = {transcript = true}}).transcript_requests
        if #queries > 0 then
          remote.control:exchange("remote-pi", {instance = "pi-one", receipts = {}, tasks = {},
            transcripts = {{id = queries[1].id, result = {messages = protocol_json.array(), active_turn = false, truncated = false}}}})
        end
        coroutine.yield()
      until done or system.get_time() > deadline
      test.ok(done and not failure, failure or "Cross-Project conversation read timed out")
      result = assert(protocol_json.decode(result))
      test.not_ok(result.result.isError, result.result.content[1].text)
      test.ok(protocol_json.is_array(result.result.structuredContent.messages), "An empty history must remain a JSON array")

      local author = source:add_client("source-pi")
      local source_report = {instance = "source-one", receipts = {}, tasks = {}}
      local remote_report = {instance = "pi-one", receipts = {}, tasks = {}}
      source.control:exchange("source-pi", source_report)
      done, result, failure = nil, nil, nil
      http.post(source.url .. "/mcp", "application/json", {jsonrpc = "2.0", id = 9, method = "tools/call",
        params = {name = "agent_send", arguments = {project = USERDIR .. "/other-project", terminal = "remote-pi",
          instance = "pi-one", request_id = "cross-project-question", text = "Any update?"}}}, {
        headers = {Authorization = "Bearer " .. author.token},
        on_done = function(success, error, body) done, result, failure = true, body, not success and error end})
      deadline = system.get_time() + 15
      repeat source:poll(); remote:poll(); coroutine.yield() until done or system.get_time() > deadline
      test.ok(done and not failure, failure or "Cross-Project send timed out")
      test.not_ok(result.result.isError, result.result.content[1].text)
      local task = result.result.structuredContent.task
      test.equal(remote.control:exchange("remote-pi", remote_report).commands[1].id, task)
      remote_report.receipts = {{id = task, status = "completed", result = "Yes"}}
      remote.control:exchange("remote-pi", remote_report)
      local answer
      repeat
        source:poll(); remote:poll()
        answer = source.control:exchange("source-pi", source_report).commands[1]
        if not answer then coroutine.yield() end
      until answer or system.get_time() > deadline
      test.not_nil(answer, "A cross-Project reply must reach the source Project")
      test.equal(answer.reply_to, task)
      test.equal(answer.text, "Yes")
    end)
    source:close(); remote:close()
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
    context.server = require("core.control_server").open(require("core.control").new(context.project))
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

  local function begin(context, name, args, token)
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
    return context.server.control:exchange("pi-terminal", report).commands
  end

  test.it("carries a Pi's message to a waiting External Agent and its answer back", function(context)
    pi_commands(context)
    local first = tool(context, "external_agent", {action = "wait", agent = "agy", timeout_ms = 0})
    test.equal(#first.messages, 0)
    local waiting = begin(context, "external_agent", {action = "wait", agent = "agy", after = first.cursor,
      timeout_ms = 180000})
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
