local core = require "core"
local common = require "core.common"
local config = require "core.config"
local panes = require "core.panes"
local http = require "core.http"
local json = require "core.json"
local test = require "core.test"
local terminal = require "plugins.terminal"

-- Seam: real Pi TUI -> native MCP client -> real editor -> another real Pi TUI.
-- Only the external model is scripted. The test never calls a provider.
test.describe("Pi controls Anvil", function()
  test.it("starts a visible child and receives its answer without moving user focus", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows Terminal test")
    local programs = os.getenv("ProgramFiles") or "C:/Program Files"
    local pi, node = programs .. "/pi/pi.exe", programs .. "/nodejs/node.exe"
    test.skip_if(not system.get_file_info(pi) or not system.get_file_info(node), "Installed Pi and Node are required")
    local root = USERDIR .. "/control-pi"
    assert(common.mkdirp(root))
    assert(common.mkdirp(root .. "/agent"))
    assert(common.mkdirp(root .. "/sessions"))
    local saved = {path = os.getenv("PATH"), agent = os.getenv("PI_CODING_AGENT_DIR"),
      sessions = os.getenv("PI_CODING_AGENT_SESSION_DIR"),
      shell = config.plugins.terminal.shell, prepare = config.plugins.terminal.prepare_session,
      prepare_pi = config.plugins.terminal.prepare_pi}
    config.plugins.terminal.shell = "powershell.exe -NoLogo -NoProfile"
    config.plugins.terminal.prepare_session, config.plugins.terminal.prepare_pi = false, false
    system.setenv("PI_CODING_AGENT_DIR", root .. "/agent")
    system.setenv("PI_CODING_AGENT_SESSION_DIR", root .. "/sessions")
    system.setenv("PATH", programs .. "/pi;" .. saved.path)
    local stream = assert(require("core.process_stream").start({node, system.getcwd() .. "/tests/fixtures/control-model.cjs", root}, {stderr = true}))
    local runtime = require "core.control_runtime"
    local function wait(check, seconds)
      local deadline = system.get_time() + (seconds or 90)
      repeat
        for _, view in ipairs(terminal.open_views()) do view:update() end
        if check() then return true end
        coroutine.yield(0.02)
      until system.get_time() > deadline
      return false
    end
    local endpoint
    local function call(name, args)
      local done, result, failure
      http.post(endpoint.url .. "/mcp", "application/json", {jsonrpc = "2.0", id = 1,
        method = "tools/call", params = {name = name, arguments = args}}, {
        headers = {Authorization = "Bearer " .. endpoint.token},
        on_done = function(ok, err, body)
          failure = not ok and tostring(err) or body.error and body.error.message
          result, done = body and body.result, true
        end})
      test.ok(wait(function() return done end, 40), "MCP call timed out: " .. name)
      test.ok(not failure, failure)
      test.ok(not result.isError, result.content and result.content[1].text)
      return result.structuredContent
    end
    local source = panes.create {factory = function() return require("core.view")() end}
    local initial = {}
    for _, pane in ipairs(panes.ordered()) do initial[pane.id] = true end
    local ok, err = pcall(function()
      local port
      test.ok(wait(function() port = stream:read_line(); return port end, 30), "Scripted model did not start")
      local models = {providers = {["anvil-test"] = {baseUrl = "http://127.0.0.1:" .. port .. "/v1",
        api = "openai-completions", apiKey = "local-test", models = {{id = "scripted", name = "Scripted",
          reasoning = false, input = {"text"}, contextWindow = 32768, maxTokens = 1024,
          cost = {input = 0, output = 0, cacheRead = 0, cacheWrite = 0}}}}}}
      local file = assert(io.open(root .. "/agent/models.json", "wb")); file:write(json.encode(models)); file:close()
      runtime.start()
      test.ok(wait(function()
        local file = io.open(USERDIR .. "/control/" .. system.get_process_id() .. ".json", "rb")
        if file then endpoint = json.decode(file:read("*a")); file:close() end
        return endpoint
      end, 10), "Editor control did not start")
      local launched = call("pi_start", {cwd = root, provider = "anvil-test", model = "scripted", thinking = "off",
        task = "ANVIL_PARENT_TASK", request_id = "test-parent"})
      local ready
      test.ok(wait(function()
        ready = call("operation_read", {operation = launched.operation})
        return ready.status ~= "starting"
      end), "Pi did not connect")
      test.equal(ready.status, "ready", ready.error)
      local result
      test.ok(wait(function()
        result = call("agent_read", {terminal = ready.terminal, instance = ready.instance, task = ready.task})
        return result.status == "completed" or result.status == "failed" or result.status == "interrupted"
      end, 120), "Pi task did not finish")
      local diagnostic = io.open(root .. "/model-error.txt", "rb")
      local detail = diagnostic and diagnostic:read("*a")
      if diagnostic then diagnostic:close() end
      test.equal(result.status, "completed", detail or result.error)
      test.equal(result.result, "ANVIL_PARENT_RESULT", detail)
      test.equal(panes.active(), source, "An agent took the user's focus")
      local count = 0
      for _, pane in ipairs(panes.ordered()) do if not initial[pane.id] then count = count + 1 end end
      test.equal(count, 2, "The parent and child each need one visible Pane")
    end)
    runtime.stop()
    for _, pane in ipairs(panes.ordered()) do if not initial[pane.id] then panes.close(pane, {force = true}) end end
    panes.close(source, {force = true})
    stream:cancel()
    system.setenv("PATH", saved.path)
    system.setenv("PI_CODING_AGENT_DIR", saved.agent or "")
    system.setenv("PI_CODING_AGENT_SESSION_DIR", saved.sessions or "")
    config.plugins.terminal.shell, config.plugins.terminal.prepare_session = saved.shell, saved.prepare
    config.plugins.terminal.prepare_pi = saved.prepare_pi
    if not ok then
      -- Keep failure evidence in the test log before cleanup.
      for _, name in ipairs {"model-error.txt"} do
        local file = io.open(root .. "/" .. name, "rb")
        if file then core.log_quiet("Control test: %s", file:read("*a")); file:close() end
      end
    end
    test.ok(test.remove_tree(root))
    assert(ok, err)
  end)
end)
