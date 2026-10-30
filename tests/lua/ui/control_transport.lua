local core = require "core"
local http = require "core.http"
local json = require "core.json"
local test = require "core.test"

-- Seam: authenticated MCP over a real loopback connection.
test.describe("Anvil MCP", function()
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
    end)
    source:close(); remote:close(); os.remove(path)
    assert(ok, err)
  end)
end)
