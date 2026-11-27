-- Only these operations cross the Machine boundary. The host never forwards arbitrary editor tools.
local core = require "core"
local json = require "core.lsp.json"
local M = { methods = { agent_read = true, agent_send = true, agent_wait = true, agent_transcript = true, agent_interrupt = true } }

-- Sends one request to Machine `id`. One connection per call bounds its lifetime and never replays a request after
-- a disconnect. `done(ok, value)` gets the decoded reply bytes, or else the result. The reply can take `timeout`
-- seconds, 36 by default.
function M.request(id, method, params, done, cancelled, timeout)
  if type(id) ~= "string" or #id ~= 32 or not id:match("^%x+$") then return done(false, "Invalid Machine ID") end
  local project = require "core.machine_project"
  local client = require("core.machine_client").new(project.machine_file(id))
  core.add_thread(function()
    local deadline = system.get_time() + 10
    while client.state == "connecting" and system.get_time() < deadline and not cancelled() do coroutine.yield(.01) end
    if cancelled() then return client:close() end
    if client.state ~= "ready" or client.machine ~= id then
      local reason = client.error or "Machine unavailable or identity does not match"
      client:close(); return done(false, reason)
    end
    local supported = false
    for _, name in ipairs(client.features or {}) do supported = supported or name == method end
    if not supported then client:close(); return done(false, "Update Anvil on the host to enable " .. method) end
    local finished
    client:request(method, params, nil, function(err, result, bytes)
      if finished then return end
      finished = true
      if err then done(false, err.message or err.code)
      elseif bytes and #bytes > 0 then done(true, json.decode(bytes))
      else done(true, result) end
    end)
    deadline = system.get_time() + (timeout or 36)
    while not finished and not cancelled() and system.get_time() < deadline do coroutine.yield(.02) end
    if not finished then finished = true; done(false, "Machine agent did not answer; the task may still be running") end
    client:close()
  end)
end

function M.route(id, path, method, args, caller, done, cancelled, sender)
  local params = {}
  for k, v in pairs(args) do params[k] = v end
  params.project, params.sender = path, caller
  params.sender_info = sender
  M.request(id, method, params, done, cancelled)
end

-- The Machine and the path on it of a Project key or a local path. A local Project uses this PC's own server.
function M.machine_of(key, local_path)
  local projects = require "core.machine_project"
  local machine, path = projects.parse(key)
  if machine then return machine, path end
  return projects.own_id(), local_path or key
end

return M
