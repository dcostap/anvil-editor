-- The private endpoint of this Project process. Only the Machine server, which runs Anvil's MCP server, and the Pis
-- of this Project's Terminal Views call it. Discovery follows Terminal Session ownership.
local core = require "core"
local json = require "core.json"
local M = {}
local server, starting, stopped, discovery, failure
local generation = 0
local sessions = {}
local checked

-- The state of Anvil's MCP server in the Machine server, from its discovery file. Never return the token.
function M.status()
  if os.getenv("ANVIL_CONTROL") == "0" then return "disabled" end
  local now = system.get_time()
  if not checked or now - checked.time >= 1 then
    local path = USERDIR .. PATHSEP .. "machine" .. PATHSEP .. "mcp.json"
    local file = io.open(path, "rb")
    local ok, record = pcall(json.decode, file and file:read(4096) or "")
    if file then file:close() end
    checked = {time = now, state = "unavailable", reason = "Anvil's Machine server is not running"}
    if ok and type(record) == "table" and type(record.url) == "string" and type(record.pid) == "number"
        and system.process_state(record.pid, type(record.created) == "string" and record.created or nil) == "running" then
      checked = {time = now, state = "ready", url = record.url, path = path}
    end
  end
  return checked.state, checked.url, checked.path, checked.reason
end

local function write_json(path, value)
  local temporary = path .. ".tmp-" .. system.get_process_id()
  local file, err = io.open(temporary, "wb")
  if not file then return nil, err end
  local ok
  ok, err = file:write(json.encode(value))
  file:close()
  if ok then ok, err = system.replace_file(temporary, path) end
  if not ok then os.remove(temporary) end
  return ok, err
end

function M.observe(view)
  if not server or view.machine or not view.session_id or sessions[view.session_id] then return end
  local id = view.session_id
  local endpoint = server:add_client(id)
  local path = USERDIR .. "/control/terminals/" .. id .. ".json"
  local ok, err = write_json(path, endpoint)
  if not ok then
    server:remove_client(endpoint.token)
    core.log_quiet("Control: Terminal discovery failed: %s", tostring(err))
    return
  end
  sessions[id] = {path = path, endpoint = endpoint, view = view}
  core.log_quiet("Control: registered Terminal=%s", id)
end

function M.release(view)
  local item = view.session_id and sessions[view.session_id]
  if not item or item.view ~= view then return end
  if server then server:remove_client(item.endpoint.token) end
  -- A transfer can already have published the destination's endpoint.
  local file = io.open(item.path, "rb")
  if file then
    local ok, data = pcall(json.decode, file:read(4096)); file:close()
    if ok and type(data) == "table" and data.token == item.endpoint.token then os.remove(item.path) end
  end
  sessions[view.session_id] = nil
end

function M.stop()
  generation = generation + 1
  stopped = true
  local views = {}
  for _, item in pairs(sessions) do views[#views + 1] = item.view end
  for _, view in ipairs(views) do M.release(view) end
  if discovery then os.remove(discovery); discovery = nil end
  if server then server:close(); server = nil end
  starting, failure = false, nil
end

function M.start()
  if server or starting or os.getenv("ANVIL_CONTROL") == "0" then return end
  generation = generation + 1
  local current = generation
  starting, stopped, failure = true, false, nil
  core.add_background_thread(function()
    local ok, result = pcall(require("core.control_server").open)
    if stopped or generation ~= current then
      if ok then result:close() end
      return
    end
    if not ok then
      starting, failure = false, tostring(result)
      core.log_quiet("Control: listener failed: %s", failure)
      return
    end
    local directory = USERDIR .. "/control"
    local secured, err = pcall(function()
      require("net").private_directory(directory)
      require("net").private_directory(directory .. "/terminals")
    end)
    if not secured then
      result:close()
      starting, failure = false, "Cannot secure the discovery folder: " .. tostring(err)
      core.log_quiet("Control: %s", failure)
      return
    end
    server, starting = result, false
    discovery = directory .. "/" .. system.get_process_id() .. ".json"
    local project = core.root_project()
    local written, err = write_json(discovery, {version = 1, url = server.url, token = server.token,
      project = project and require("core.machine_project").root_key(project.path), executable = EXEFILE, pid = system.get_process_id(),
      created = system.get_process_creation_time()})
    if not written then
      failure = "Cannot write the discovery file: " .. tostring(err)
      core.log_quiet("Control: %s", failure)
    end
    for _, view in ipairs(require("plugins.terminal").open_views()) do M.observe(view) end
    core.log_quiet("Control: listening at %s", server.url)
    while not stopped and server and generation == current do
      local polled, failure = pcall(server.poll, server)
      if not polled then core.log_quiet("Control: poll failed: %s", tostring(failure)) end
      coroutine.yield(0.02)
    end
  end)
end

local exit = core.exit
function core.exit(fn, force)
  return exit(function() M.stop(); fn() end, force)
end

return M
