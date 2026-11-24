-- A Pi with no editor View uses the Machine's loopback agent endpoint. Never export its credential.
local core = require "core"
local common = require "core.common"
local json = require "core.lsp.json"
local net = require "net"
local agents = require "core.machine_agents"
local M = {}

function M.new(server, live_record)
  local projects, registered = {}, {}
  local directory = USERDIR .. "/machine/agents"
  net.private_directory(directory)
  local function forget(id, item)
    item.server:remove_client(item.endpoint.token)
    item.server.control.peers[id] = nil
    os.remove(directory .. "/" .. id .. ".json")
    registered[id] = nil
  end
  local function observe(record)
    if os.getenv("ANVIL_CONTROL") == "0" then return end
    local id, project = record.session_id, record.project_path
    local item = registered[id]
    if item and common.path_equals(item.server.control.project, project) then return item end
    if item then forget(id, item) end
    while projects[project] == false do coroutine.yield(.01) end
    if registered[id] then return registered[id] end
    local listener = projects[project]
    if not listener then
      local control = require("core.control").new(project)
      control.headless = true
      projects[project] = false
      local ok, opened = pcall(require("core.control_server").open, control)
      if not ok then projects[project] = nil; error(opened) end
      listener = opened
      projects[project] = listener
    end
    local ep = listener:add_client(id)
    local path = directory .. "/" .. id .. ".json"
    local file = assert(io.open(path .. ".tmp", "wb")); file:write(json.encode(ep)); file:close()
    assert(system.replace_file(path .. ".tmp", path))
    item = {server = listener, endpoint = ep}
    registered[id] = item
    return item
  end
  core.add_thread(function()
    local next_check = 0
    while true do
      for _, listener in pairs(projects) do if listener then listener:poll() end end
      if system.get_time() >= next_check then
        for id, item in pairs(registered) do
          local record = live_record(id)
          if not record or not common.path_equals(record.project_path, item.server.control.project) then forget(id, item) end
        end
        for root, listener in pairs(projects) do
          if listener and not next(listener.credentials) then listener:close(); projects[root] = nil end
        end
        next_check = system.get_time() + 2
      end
      coroutine.yield(next(projects) and .02 or .2)
    end
  end)
  local function call(method, client, id, args)
    local record = live_record(args.terminal)
    if not record or type(args.project) ~= "string" or not common.path_equals(record.project_path, args.project) then
      return server.fail(client, id, "not_found", "This Project has no such running Terminal Session")
    end
    if os.getenv("ANVIL_CONTROL") == "0" then return server.fail(client, id, "disabled", "Agent control is disabled") end
    if (client.agent_pending or 0) >= 16 then return server.fail(client, id, "busy", "Too many agent requests") end
    client.agent_pending = (client.agent_pending or 0) + 1
    core.add_thread(function()
      local function finish(ok, value)
        client.agent_pending = client.agent_pending - 1
        if client.dead then return end
        if ok then server.reply(client, id, {result = {}}, json.encode(value))
        else server.fail(client, id, "not_connected", value or "Pi is not connected") end
      end
      local ok, err = pcall(function()
        local item = observe(record)
        local deadline = system.get_time() + 2
        while not item.server.control.peers[args.terminal] and system.get_time() < deadline and not client.dead do coroutine.yield(.05) end
        if not item.server.control.peers[args.terminal] then return finish(false) end
        if client.dead then return finish(false) end
        local control = item.server.control
        local sender = "machine:" .. (client.device or "owner") .. "/" .. tostring(args.sender or "local"):sub(1, 128)
        local info = args.sender_info
        if type(info) == "table" then
          info.terminal = args.sender
          info.machine = client.device and (client.name or client.device) or nil
          info.other_project = info.machine ~= nil or info.project ~= control.project_key
        end
        args.sender, args.sender_info = nil, nil
        local value = control:call(method, args, sender, info)
        if method == "agent_transcript" then
          local query = value
          repeat
            value = control:transcript_read(query)
            if not value then coroutine.yield(.05) end
          until value or client.dead
          control:cancel_transcript(query)
        elseif method == "agent_wait" then
          local until_time = system.get_time() + (args.timeout_ms or 30000) / 1000
          repeat
            value = control:wait_result(args, until_time)
            if not value then coroutine.yield(.1) end
          until value or client.dead
        end
        finish(true, value)
      end)
      if not ok then finish(false, tostring(err)) end
    end)
  end
  local methods = {}
  for method in pairs(agents.methods) do methods[method] = function(...) return call(method, ...) end end
  return methods, observe
end
return M
