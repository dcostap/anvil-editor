-- A local, stateless Streamable HTTP MCP endpoint. No SSE stream or browser access.
local core = require "core"
local net = require "net"
-- Preserve empty JSON arrays in conversation pages and activity reports.
local json = require "core.lsp.json"
local Control = require "core.control"
local common = require "core.common"
local M = {}
M.__index = M
local MAX_BODY, MAX_CLIENTS = 512 * 1024, 32
local protocol_versions = { ["2025-03-26"] = true, ["2025-06-18"] = true, ["2025-11-25"] = true }

function M.open(control)
  local token = net.random_token()
  local address = assert(net.resolve_address("127.0.0.1"))
  local deadline = system.get_time() + 5
  while address:get_status() == "waiting" and system.get_time() < deadline do coroutine.yield(0.01) end
  assert(address:get_status() == "success", "Cannot resolve loopback address")
  local listener, port, err
  for i = 1, 128 do
    -- Spread attempts across the range: Windows can exclude many adjacent ports.
    port = 49152 + (tonumber(token:sub(1, 4), 16) + i * 127) % 16384
    listener, err = net.create_server(address, port)
    if listener then break end
  end
  assert(listener, "Cannot open local control listener: " .. tostring(err))
  return setmetatable({ listener = listener, token = token, clients = {}, credentials = {},
    url = "http://127.0.0.1:" .. port, host = "127.0.0.1:" .. port,
    control = control or Control.new() }, M)
end

function M:add_client(caller)
  local token = net.random_token()
  self.credentials[token] = caller
  return {version = 1, url = self.url, token = token}
end

function M:remove_client(token)
  local caller = self.credentials[token]
  local peer = caller and self.control.peers[caller]
  if peer then peer.seen = -math.huge end
  self.credentials[token] = nil
  for _, client in ipairs(self.clients) do if client.token == token then client.dead = true end end
end

local function reply(client, status, value)
  if client.replied or client.dead then return end
  client.replied = true
  local body = value and json.encode(value) or ""
  client.socket:write("HTTP/1.1 " .. status .. "\r\nContent-Type: application/json\r\nContent-Length: "
    .. #body .. "\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n" .. body)
end

local function project_request(target, request, done, cancelled)
  require("core.http").post(target.url .. "/mcp", "application/json", nil, {
    body = json.encode(request), decode_json = false,
    headers = {Authorization = "Bearer " .. target.token, ["Content-Type"] = "application/json"}, timeout = 35,
    is_cancelled = cancelled,
    on_redirect = function(response)
      for key in pairs(response.headers) do if key:lower() == "location" then response.headers[key] = nil end end
    end,
    on_done = function(ok, _, body)
      if ok and type(body) == "string" then body = json.decode(body) end
      done(ok and type(body) == "table" and body.jsonrpc == "2.0" and body or nil)
    end})
end

local function task_pending(value)
  return value.connected and (value.status == "pending" or value.status == "running" or value.status == "awaiting_reply")
end

-- Follow the result from the side that sent the request. A Machine needs no reverse pairing.
function M:follow_reply(source, target, task, route)
  self.reply_watches = self.reply_watches or {}
  local watches = self.reply_watches
  if watches[task] then return end
  local count = 0
  for _ in pairs(watches) do count = count + 1 end
  if count >= 64 then return end
  watches[task] = true
  local args = {terminal = target.terminal, instance = target.instance, task = task, include_activity = false}
  local function stopped()
    local peer = self.control.peers[source.terminal]
    if not self.listener or not peer or peer.instance ~= source.instance or system.get_time() - peer.seen >= 10 then return true end
    for _, waited in ipairs(peer.waited_replies or {}) do if waited == task then return true end end
    return false
  end
  local function follow()
    while not stopped() do
      local value
      if route then
        local done
        route(args, function(result) value, done = result, true end, stopped)
        while not done and not stopped() do coroutine.yield(.1) end
        if not value then return end
      else value = self.control:agent_read(args) end
      if value.explicit_reply == true and type(value.result) == "string" and #value.result <= 8192 then
        -- A matching wait already returns the answer to this Pi. Do not send it twice.
        repeat
          if stopped() then return end
          local waiting
          for _, client in ipairs(self.clients) do
            local wait = client.reply_wait
            if not client.dead and wait and wait.task == task and wait.terminal == source.terminal
                and wait.instance == source.instance then waiting = true; break end
          end
          if waiting then coroutine.yield(.1) end
        until not waiting
        self.control:deliver_agent_reply(source, target, task, value.result)
        return
      end
      if not task_pending(value) then return end
      coroutine.yield(route and 2 or .1)
    end
  end
  core.add_thread(function()
    local ok, err = pcall(follow)
    watches[task] = nil
    if not ok then core.log_quiet("Control: could not forward an agent reply: %s", tostring(err)) end
  end)
end

function M:discover(client, callback)
  client.forwarding, client.deadline = true, system.get_time() + 40
  local handle, err = require("core.worker_pool").named("control", {worker_count = 1}):submit {
    kind = "control_discovery", payload = {directory = USERDIR .. "/control", executable = EXEFILE},
    on_result = function(message)
      if message.type == "result" and not client.dead then callback(message.payload.endpoints) end
    end,
    on_error = function() if not client.dead then callback({}) end end,
  }
  if not handle then callback({}); core.log_quiet("Control: discovery failed: %s", tostring(err)) end
end

function M:dispatch(client, body)
  local request = json.decode(body)
  assert(type(request) == "table", "Invalid request")
  if client.path == "/agent" then
    assert(client.caller ~= "local", "An agent needs a Terminal Session credential")
    return reply(client, "200 OK", self.control:exchange(client.caller, request))
  end
  if client.path ~= "/mcp" then return reply(client, "404 Not Found") end
  local function result(value)
    reply(client, "200 OK", {jsonrpc = "2.0", id = request.id, result = value})
  end
  local function failure(code, message)
    reply(client, "200 OK", {jsonrpc = "2.0", id = request.id or json.null, error = {code = code, message = message}})
  end
  if request.jsonrpc ~= "2.0" or type(request.method) ~= "string"
      or (request.id ~= nil and type(request.id) ~= "string" and type(request.id) ~= "number") then
    return failure(-32600, "Invalid JSON-RPC request")
  end
  if request.id == nil then
    -- Notifications never execute mutations. MCP initialization needs no session state.
    return reply(client, "202 Accepted")
  end
  local params = request.params or {}
  if type(params) ~= "table" then return failure(-32602, "Invalid parameters") end
  if request.method == "initialize" then
    return result { protocolVersion = protocol_versions[params.protocolVersion] and params.protocolVersion or "2025-06-18",
      capabilities = {tools = {listChanged = false}}, serverInfo = {name = "anvil", version = "1"},
      instructions = "Control Anvil through stable Pane and Terminal Session IDs. Preserve focus unless asked. Use request_id for safe retries. A timeout does not cancel work. Close approves only the calling agent's own running Terminal; other Views keep normal confirmation. Self-close can stop the agent before the reply arrives." }
  elseif request.method == "ping" then return result({})
  elseif request.method == "tools/list" then
    if not self.control.headless then return result {tools = Control.tools} end
    local tools = {}
    for _, tool in ipairs(Control.tools) do
      if require("core.machine_agents").methods[tool.name] then tools[#tools + 1] = tool end
    end
    return result {tools = tools}
  elseif request.method == "tools/call" then
    local args = params.arguments or {}
    local peer = self.control.peers[client.caller]
    local source = peer and {terminal = client.caller, instance = peer.instance}
    local route, sender_project
    local function observe(value)
      if not source or client.dead or type(value) ~= "table" then return end
      if params.name == "agent_send" and value.task then
        self:follow_reply(source, {terminal = value.terminal, instance = value.instance,
          project = sender_project or self.control.project_key, other_project = route ~= nil}, value.task, route)
      elseif params.name == "agent_wait" and value.explicit_reply then
        peer.waited_replies = peer.waited_replies or {}
        peer.waited_replies[#peer.waited_replies + 1] = value.task
        if #peer.waited_replies > 256 then table.remove(peer.waited_replies, 1) end
      end
    end
    local function tool_result(success, data)
      if success then observe(data) end
      client.reply_wait = nil
      -- A text result is for the model. JSON would escape it again, so it has no structured copy.
      if success and type(data) == "string" then
        return result {isError = false, content = {{type = "text", text = data}}}
      end
      result {isError = not success, content = {{type = "text", text = success and json.encode(data) or tostring(data)}},
        structuredContent = success and data or {error = tostring(data)}}
    end
    if type(args) ~= "table" then return tool_result(false, "Invalid arguments") end
    if source and params.name == "agent_wait" then
      client.reply_wait = {task = args.task, terminal = source.terminal, instance = source.instance}
    end
    local agents = require "core.machine_agents"
    if self.control.headless and not agents.methods[params.name] then
      return tool_result(false, "This operation needs a loaded editor Project")
    end
    if agents.methods[params.name] then
      local projects = require "core.machine_project"
      local machine, path = projects.parse(args.project or self.control.project_key)
      if self.control.headless and not machine and (not args.project or common.path_equals(args.project, self.control.project)) then
        machine, path = projects.own_id(), self.control.project
      end
      if machine then
        sender_project = path
        route = function(query, done, cancelled)
          agents.route(machine, path, "agent_read", query, source.terminal, function(ok, value) done(ok and value or nil) end, cancelled)
        end
        client.forwarding, client.deadline = true, system.get_time() + 48
        return agents.route(machine, path, params.name, args, client.caller, tool_result, function() return client.dead end,
          params.name == "agent_send" and self.control:sender(client.caller) or nil)
      end
    end
    if args.project and (type(args.project) ~= "string" or not common.path_equals(args.project, self.control.project_key)) then
      return self:discover(client, function(endpoints)
        local target
        for _, endpoint in ipairs(endpoints) do
          if type(args.project) == "string" and common.path_equals(endpoint.project, args.project) then
            if target then return tool_result(false, "Project has more than one control endpoint") end
            target = endpoint
          end
        end
        if not target then return tool_result(false, "Project is not loaded or has no control endpoint") end
        args.project = nil -- The destination already identifies the Project. Never forward twice.
        params._meta = {anvil_caller = client.caller, sender = params.name == "agent_send" and self.control:sender(client.caller) or nil}
        sender_project = target.project
        route = function(query, done, cancelled)
          project_request(target, {jsonrpc = "2.0", id = 1, method = "tools/call",
            params = {name = "agent_read", arguments = query}}, function(body)
              done(body and body.result and body.result.structuredContent)
            end, cancelled)
        end
        project_request(target, request, function(body)
          if not body then return tool_result(false, "Project control is unavailable") end
          if body.result and not body.result.isError then observe(body.result.structuredContent) end
          client.reply_wait = nil
          reply(client, "200 OK", body)
        end, function() return client.dead end)
      end)
    end
    local caller, sender = client.caller, nil
    if caller == "local" and type(params._meta) == "table" and type(params._meta.anvil_caller) == "string" then
      caller = params._meta.anvil_caller
      sender = params._meta.sender
      if sender then sender.other_project = true end
    end
    local function run()
      local ok, value = pcall(self.control.call, self.control, params.name, args, caller, sender)
      if ok and params.name == "agent_transcript" then
        client.transcript = {query = value, result = tool_result}
        client.deadline = value.deadline + 5
        return
      end
      if ok and params.name == "workspace_state" then
        return self:discover(client, function(endpoints)
          value.projects = {}
          value.projects[self.control.project_key] = {project = self.control.project_key}
          for _, endpoint in ipairs(endpoints) do value.projects[endpoint.project] = {project = endpoint.project} end
          tool_result(true, value)
        end)
      end
      if ok and params.name == "agent_wait" and task_pending(value) and not value.waiting_for_user then
        client.waiting = {args = params.arguments, result = tool_result,
          until_time = system.get_time() + (params.arguments.timeout_ms or 30000) / 1000}
        client.deadline = client.waiting.until_time + 5
        return
      end
      return tool_result(ok, value)
    end
    -- An export detaches the Pane's Terminals, so move only to a Project that runs. Use its own name for it.
    if params.name == "pane" and type(args.target_project) == "string" then
      return self:discover(client, function(endpoints)
        local target
        for _, endpoint in ipairs(endpoints) do
          if common.path_equals(endpoint.project, args.target_project) then target = endpoint.project end
        end
        if not target then return tool_result(false, "Target Project is not loaded or has no control endpoint") end
        args.target_project = target
        run()
      end)
    end
    return run()
  end
  return failure(-32601, "Method not found")
end

function M:read(client)
  local bytes, err = client.socket:read(16384)
  if not bytes then client.dead = true; return end
  if bytes == "" then return end
  client.buffer = client.buffer .. bytes
  if not client.header_end then
    local last = client.buffer:find("\r\n\r\n", 1, true)
    if not last then
      if #client.buffer > 8192 then reply(client, "431 Request Header Fields Too Large") end
      return
    end
    if last > 8192 then return reply(client, "431 Request Header Fields Too Large") end
    local head = client.buffer:sub(1, last + 1)
    local method, path = head:match("^(%u+) ([^ ]+) HTTP/1%.[01]\r\n")
    local headers = {}
    for line in head:gmatch("[^\r\n]+") do
      local key, value = line:match("^([%w-]+):%s*(.-)%s*$")
      if key then
        key = key:lower()
        if headers[key] then return reply(client, "400 Bad Request") end
        headers[key] = value
      end
    end
    -- No CORS and no browser origins, including same-origin pages. Bind only to loopback.
    if headers.origin or headers.host ~= self.host then return reply(client, "403 Forbidden") end
    local token = (headers.authorization or ""):match("^Bearer ([0-9a-f]+)$")
    client.token = token
    client.caller = token == self.token and "local" or self.credentials[token]
    if not client.caller then return reply(client, "401 Unauthorized") end
    if method ~= "POST" then return reply(client, "405 Method Not Allowed") end
    if headers["transfer-encoding"] or not (headers["content-length"] or ""):match("^%d+$") then
      return reply(client, "400 Bad Request")
    end
    client.length = tonumber(headers["content-length"])
    if client.length > MAX_BODY then return reply(client, "413 Content Too Large") end
    if not (headers["content-type"] or ""):match("^application/json") then
      return reply(client, "415 Unsupported Media Type")
    end
    client.header_end, client.path = last + 3, path
  end
  local size = #client.buffer - client.header_end
  if size > client.length then return reply(client, "400 Bad Request") end
  if size == client.length then
    local ok = pcall(self.dispatch, self, client, client.buffer:sub(client.header_end + 1))
    if not ok then reply(client, "400 Bad Request", {error = "Invalid control request"}) end
    client.buffer = ""
  end
end

function M:poll()
  if not self.listener then return end
  for _ = 1, 4 do
    if #self.clients >= MAX_CLIENTS then break end
    local socket = self.listener:accept()
    if not socket then break end
    self.clients[#self.clients + 1] = {socket = socket, buffer = "", deadline = system.get_time() + 10}
  end
  local stop = system.get_time() + 0.002
  for i = #self.clients, 1, -1 do
    local client = self.clients[i]
    if client.transcript and not client.dead then
      local read = client.transcript
      local ok, value = pcall(self.control.transcript_read, self.control, read.query)
      if not ok or value then
        self.control:cancel_transcript(read.query)
        client.transcript = nil
        read.result(ok, value)
      end
    elseif client.waiting and not client.dead then
      local wait = client.waiting
      if not wait.next_read or system.get_time() >= wait.next_read then
        wait.next_read = system.get_time() + 0.1
        local ok, value = pcall(self.control.wait_result, self.control, wait.args, wait.until_time)
        if not ok or value then
          wait.result(ok, value)
          client.waiting = nil
        end
      end
    elseif not client.replied and not client.dead and not client.forwarding then self:read(client) end
    if client.dead or system.get_time() > client.deadline
        or client.replied and (client.socket:get_pending_writes() or 0) == 0 then
      if client.transcript then self.control:cancel_transcript(client.transcript.query) end
      client.socket:close()
      client.dead = true
      table.remove(self.clients, i)
    end
    if system.get_time() >= stop then break end
  end
  if self.control.tick then self.control:tick() end
end

function M:close()
  for _, client in ipairs(self.clients) do
    if client.transcript then self.control:cancel_transcript(client.transcript.query) end
    client.dead = true; client.socket:close()
  end
  self.clients = {}
  if self.listener then self.listener:close(); self.listener = nil end
end

return M
