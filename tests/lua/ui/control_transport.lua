local core = require "core"
local http = require "core.http"
local json = require "core.json"
local test = require "core.test"

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
  test.it("routes an explicit Project without changing the source Project", function()
    local Control = require "core.control"
    local Server = require "core.control_server"
    local remote = Server.open(Control.new(USERDIR .. "/other-project"))
    local source = Server.open()
    require("core.common").mkdirp(USERDIR .. "/control")
    local path = USERDIR .. "/control/987654321.json"
    local file = assert(io.open(path, "wb"))
    file:write(json.encode {version = 1, url = remote.url, token = remote.token,
      project = USERDIR .. "/other-project", executable = EXEFILE})
    file:close()
    local ok, err = pcall(function()
      local done, result, failure
      http.post(source.url .. "/mcp", "application/json", {jsonrpc = "2.0", id = 7, method = "tools/call",
        params = {name = "workspace_state", arguments = {project = USERDIR .. "/other-project"}}}, {
        headers = {Authorization = "Bearer " .. source.token},
        on_done = function(success, error, body) done, result, failure = true, body, not success and error end})
      local deadline = system.get_time() + 20
      repeat source:poll(); remote:poll(); coroutine.yield() until done or system.get_time() > deadline
      test.ok(done and not failure, failure or "Project request timed out")
      test.equal(result.result.isError, false)
      test.equal(result.result.structuredContent.project, USERDIR .. "/other-project")
      test.not_equal(core.root_project().path, USERDIR .. "/other-project")
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
    end)
    source:close(); remote:close(); os.remove(path)
    assert(ok, err)
  end)
end)
