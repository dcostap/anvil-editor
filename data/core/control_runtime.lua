-- One local endpoint per loaded Project. Discovery follows Terminal Session ownership.
local core = require "core"
local json = require "core.json"
local M = {}
local server, starting, stopped, discovery
local generation = 0
local sessions = {}

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
  if not server or not view.session_id or sessions[view.session_id] then return end
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
  starting = false
end

function M.start()
  if server or starting or os.getenv("ANVIL_CONTROL") == "0" then return end
  generation = generation + 1
  local current = generation
  starting, stopped = true, false
  core.add_background_thread(function()
    local ok, result = pcall(require("core.control_server").open)
    if not ok then core.log_quiet("Control: listener failed: %s", tostring(result)); starting = false; return end
    if stopped or generation ~= current then result:close(); return end
    local directory = USERDIR .. "/control"
    local secured, failure = pcall(function()
      require("net").private_directory(directory)
      require("net").private_directory(directory .. "/terminals")
    end)
    if not secured then
      result:close(); starting = false
      core.log_quiet("Control: private discovery unavailable: %s", tostring(failure))
      return
    end
    server, starting = result, false
    discovery = directory .. "/" .. system.get_process_id() .. ".json"
    local project = core.root_project()
    local written, err = write_json(discovery, {version = 1, url = server.url, token = server.token,
      project = project and project.path, executable = EXEFILE, pid = system.get_process_id()})
    if not written then core.log_quiet("Control: Project discovery failed: %s", tostring(err)) end
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
