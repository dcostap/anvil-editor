-- Only these operations cross the Machine boundary. The host never forwards arbitrary editor tools.
local core = require "core"
local json = require "core.lsp.json"
local M = { methods = { agent_read = true, agent_send = true, agent_wait = true, agent_transcript = true, agent_interrupt = true } }

-- One connection per call bounds its lifetime and never replays a send after a disconnect.
function M.route(id, path, method, args, caller, done, cancelled)
  if #id ~= 32 or not id:match("^%x+$") then return done(false, "Invalid Machine ID") end
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
    if not supported then client:close(); return done(false, "Update Anvil on the host to enable Machine agent control") end
    local params = {}
    for k, v in pairs(args) do params[k] = v end
    params.project, params.sender = path, caller
    local finished
    client:request(method, params, nil, function(err, result, bytes)
      if finished then return end
      finished = true
      if err then done(false, err.message or err.code) else done(true, json.decode(bytes)) end
    end)
    deadline = system.get_time() + 36
    while not finished and not cancelled() and system.get_time() < deadline do coroutine.yield(.02) end
    if not finished then finished = true; done(false, "Machine agent did not answer; the task may still be running") end
    client:close()
  end)
end

return M
