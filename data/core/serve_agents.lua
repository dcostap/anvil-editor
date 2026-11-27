-- Anvil's MCP server: one loopback endpoint of the Machine server for all its Projects. Each running Pi gets a
-- Terminal credential in `USERDIR/machine/agents`. Other local clients, such as the stdio bridge, use the owner
-- credential in `USERDIR/machine/mcp.json`. Never export a credential.
local core = require "core"
local agent_name = require "core.agent_name"
local common = require "core.common"
local json = require "core.lsp.json"
local net = require "net"
local agents = require "core.machine_agents"
local M = {}

-- Writes a credential file, so a reader never sees half of it.
local function publish(path, value)
  local file = assert(io.open(path .. ".tmp", "wb")); file:write(json.encode(value)); file:close()
  assert(system.replace_file(path .. ".tmp", path))
end

function M.new(server, live_record)
  -- One Control for each Project, keyed by its path. It holds the Project's Pi conversations.
  local controls, registered = {}, {}
  local pending = {}
  local directory = USERDIR .. "/machine/agents"
  net.private_directory(directory)
  local function control_of(project)
    local key = common.path_compare_key(project)
    if controls[key] then return controls[key] end
    local control = require("core.control").new(project)
    control.headless = true
    control.chat_receipt = function(terminal, instance, receipt)
      local item = pending[receipt.id]
      if item and item.terminal == terminal and item.instance == instance then
        pending[receipt.id] = nil
        item.finish(receipt.status == "accepted", receipt.error or "Pi refused the reply")
      end
    end
    control.chat_post = function(terminal, instance, message)
      local record = live_record(terminal)
      if record and common.path_equals(record.project_path, project) then server.chat_post(project, terminal, instance, message) end
    end
    controls[key] = control
    return control
  end
  -- The listener opens in the server's first thread step, because it waits for the loopback address.
  local hub
  local function open_hub()
    local ok, opened = pcall(require("core.control_server").open, nil, {
      -- A Project of a running Terminal, or a Project that this Machine serves.
      control = function(project)
        local root = controls[common.path_compare_key(project)] and project or server.project_root(project)
        return root and control_of(root)
      end,
      project_of = function(caller)
        local item = registered[caller]
        return item and item.control.project
      end,
      tick = function() for _, control in pairs(controls) do control:tick() end end,
    })
    if not ok then return server.log("Machine server cannot open Anvil's MCP server: %s", tostring(opened)) end
    hub = opened
    publish(USERDIR .. "/machine/mcp.json", {version = 1, url = hub.url, token = hub.token,
      pid = system.get_process_id(), created = system.get_process_creation_time()})
    server.log("Machine server opened Anvil's MCP server at %s", hub.url)
  end
  local function forget(id, item)
    hub:remove_client(item.endpoint.token)
    item.control.peers[id] = nil
    os.remove(directory .. "/" .. id .. ".json")
    registered[id] = nil
  end
  local function observe(record)
    if not hub then return end
    local id, project = record.session_id, record.project_path
    local item = registered[id]
    if item and common.path_equals(item.control.project, project) then return item end
    if item then forget(id, item) end
    local ep = hub:add_client(id)
    publish(directory .. "/" .. id .. ".json", ep)
    item = {control = control_of(project), endpoint = ep}
    registered[id] = item
    return item
  end
  server.chat_recipients = function(project, recipients)
    local now = system.get_time()
    for _, control in pairs(controls) do
      if common.path_equals(control.project, project) then
        for terminal, peer in pairs(control.peers) do
          if now - peer.seen < 10 then
            recipients[#recipients + 1] = {name = agent_name.for_terminal(terminal), terminal = terminal,
              instance = peer.instance}
          end
        end
      end
    end
  end
  server.chat_deliver = function(project, target, request, text, answer_time, finish)
    local record, item = live_record(target.terminal), registered[target.terminal]
    assert(record and item and common.path_equals(record.project_path, project)
      and common.path_equals(item.control.project, project), "The original Pi conversation is not connected")
    local control = item.control
    control:queue_agent_command(target, {action = "human", id = request, instance = target.instance,
      text = text, answer_time = answer_time})
    pending[request] = {terminal = target.terminal, instance = target.instance, finish = finish,
      control = control, deadline = system.get_time() + 10}
  end
  core.add_thread(function()
    if os.getenv("ANVIL_CONTROL") ~= "0" then open_hub() end
    local next_check = 0
    while true do
      if hub then hub:poll() end
      if system.get_time() >= next_check then
        for id, delivery in pairs(pending) do
          local peer = delivery.control.peers[delivery.terminal]
          if not peer or peer.instance ~= delivery.instance or system.get_time() >= delivery.deadline then
            if peer then peer.commands[id] = nil end
            pending[id] = nil
            delivery.finish(false, "Pi did not confirm this reply. Check the original conversation before retrying.")
          end
        end
        -- A locally opened Terminal need not attach through the Machine service.
        for _, name in ipairs(system.list_dir(USERDIR .. "/terminal-sessions") or {}) do
          local id = name:match("^(%x+)%.lua$")
          if id and not registered[id] then
            local record = live_record(id)
            if record then observe(record) end
          end
        end
        for id, item in pairs(registered) do
          local record = live_record(id)
          if not record or not common.path_equals(record.project_path, item.control.project) then forget(id, item) end
        end
        next_check = system.get_time() + 2
      end
      -- Pi exchanges every half second. A new connection waits at most one idle step.
      coroutine.yield(hub and #hub.clients > 0 and .02 or .1)
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
        if not item then return finish(false, "Anvil's MCP server is not open yet") end
        local deadline = system.get_time() + 2
        while not item.control.peers[args.terminal] and system.get_time() < deadline and not client.dead do coroutine.yield(.05) end
        if not item.control.peers[args.terminal] then return finish(false) end
        if client.dead then return finish(false) end
        local control = item.control
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
