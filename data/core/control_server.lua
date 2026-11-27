-- A local, stateless Streamable HTTP MCP endpoint. No SSE stream or browser access.
-- The Machine server opens Anvil's MCP server: one endpoint, with a `hub`, for all Projects and agents. It answers
-- agent operations and sends editor operations to the Project process. Each Project process opens a private
-- endpoint, with one Control, that only the Machine server and its own Terminals' Pis call.
local core = require "core"
local net = require "net"
-- Preserve empty JSON arrays in conversation pages and activity reports.
local json = require "core.lsp.json"
local Control = require "core.control"
local common = require "core.common"
local agent_name = require "core.agent_name"
local machine_agents = require "core.machine_agents"
local agents_methods = machine_agents.methods
local M = {}
local USE_SERVER = "This private endpoint serves only the editor operations of its own Project. Use Anvil's MCP server."
M.__index = M
local MAX_BODY, MAX_CLIENTS = 512 * 1024, 32
local protocol_versions = { ["2025-03-26"] = true, ["2025-06-18"] = true, ["2025-11-25"] = true }

---`hub` gives `control(path)`, the Control of a Project on this Machine or nil, `project_of(caller)`, the Project
---of a Terminal credential, and `tick()`.
function M.open(control, hub)
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
    url = "http://127.0.0.1:" .. port, host = "127.0.0.1:" .. port, hub = hub,
    control = not hub and (control or Control.new()) or nil }, M)
end

-- The Control that knows `caller`: the Project of its Terminal, or this endpoint's Project.
function M:home(caller)
  if not self.hub then return self.control end
  local project = self.hub.project_of(caller)
  return project and self.hub.control(project)
end

function M:add_client(caller)
  local token = net.random_token()
  self.credentials[token] = caller
  return {version = 1, url = self.url, token = token}
end

function M:remove_client(token)
  local caller = self.credentials[token]
  local control = caller and self:home(caller)
  local peer = control and control.peers[caller]
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

-- An External Agent's answer to a request is the thread message that names it. A failed read tries again.
local function external_reply_route(machine, path, agent, request)
  local deadline = system.get_time() + 3600
  return function(_, done, cancelled)
    if system.get_time() > deadline then return done({connected = true, status = "expired"}) end
    require("core.machine_agents").request(machine, "external.read", {project = path, agent = agent, reply_to = request},
      function(ok, value)
        local message = ok and type(value) == "table" and type(value.messages) == "table" and value.messages[1]
        done({connected = true, status = message and "completed" or "pending", explicit_reply = message and true,
          result = message and message.text})
      end, cancelled)
  end
end

-- A Pi's reply to an External Agent goes into the agent's thread.
local function post_external_reply(source, target, task, text)
  require("core.machine_agents").request(source.machine, "external.post", {project = source.path, agent = source.external,
    text = text, reply_to = task, from = {kind = "agent", name = require("core.agent_name").for_terminal(target.terminal),
      terminal = target.terminal, project = target.project}}, function(ok, err)
    if not ok then core.log_quiet("Control: could not post a reply to External Agent %s: %s", source.external, tostring(err)) end
  end, function() return false end)
end

-- Follow the result from the side that sent the request. A Machine needs no reverse pairing.
-- `source` is the sending Pi with its `control`, or an External Agent with `external`, `machine`, `path` and
-- `deadline`.
-- `target.external` names an External Agent that got the request.
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
    if source.external then return not self.listener or system.get_time() > source.deadline end
    local peer = source.control.peers[source.terminal]
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
      else value = (target.control or source.control):agent_read(args) end
      if value.explicit_reply == true and type(value.result) == "string"
          and #value.result <= (target.external and 32768 or 8192) then
        if source.external then return post_external_reply(source, target, task, value.result) end
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
        source.control:deliver_agent_reply(source, {terminal = target.terminal, instance = target.instance,
          project = target.project, other_project = target.other_project, external = target.external}, task, value.result)
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

local EXTERNAL_METHODS = {wait = "external.read", read = "external.read", say = "external.post", list = "external.list"}
local NAME_PROJECT = "Name the Project with project. workspace_state lists the loaded Projects."

-- External Agent threads belong to the Project's Machine: this PC's own server for a local Project.
-- `source` is the calling Pi, which gets the agent's answer to its `agent_send`. `control` knows the caller.
function M:external(client, name, args, source, tool_result, control)
  local ok, err = pcall(Control.check, name, args)
  if not ok then return tool_result(false, err) end
  if not (args.project or control) then return tool_result(false, NAME_PROJECT) end
  local machine, path = machine_agents.machine_of(args.project or control.project_key, args.project or control.project)
  if not machine then return tool_result(false, "Anvil's Machine server is not running") end
  if args.agent and not require("core.serve_external").valid_name(args.agent) then
    return tool_result(false, "An agent name uses letters, digits, '.', '_' and '-'")
  end
  local method, params
  if name == "agent_send" then
    if args.terminal then return tool_result(false, "Name a terminal or an agent, not both") end
    local sender = control and control:sender(client.caller, args.from_agent)
      or {terminal = client.caller, external = args.from_agent}
    local terminal = sender.terminal ~= "local" and sender.terminal or nil
    method, params = "external.post", {agent = args.agent, text = args.text, expect_reply = args.expect_reply,
      from = {kind = "agent", name = sender.external or terminal and agent_name.for_terminal(terminal) or nil,
        terminal = terminal, project = sender.project}}
  else
    method = EXTERNAL_METHODS[args.action]
    if args.action ~= "list" and not args.agent then return tool_result(false, "Name the External Agent with agent") end
    params = {agent = args.agent}
    if args.action == "wait" then
      params.listen, params.wait, params.after, params.timeout_ms = true, true, args.after, args.timeout_ms
    elseif args.action == "read" then
      params.after = args.after
    elseif args.action == "say" then
      if not args.text then return tool_result(false, "say needs text") end
      params.text, params.reply_to, params.from = args.text, args.reply_to, {kind = "self"}
    end
  end
  params.project = path
  -- A wait holds the reply for its timeout_ms, 25 seconds by default.
  local timeout = 11 + math.max(25, params.wait and (params.timeout_ms or 0) / 1000 or 0)
  client.forwarding, client.deadline = true, system.get_time() + timeout + 12
  machine_agents.request(machine, method, params, function(success, value)
    if not success or type(value) ~= "table" then return tool_result(false, value or "The Machine did not answer") end
    if name == "agent_send" then
      value = {agent = args.agent, task = value.request, status = "delivered"}
      if source and not source.external and args.expect_reply ~= false then
        self:follow_reply(source, {external = args.agent, project = path}, value.task,
          external_reply_route(machine, path, args.agent, value.task))
      end
    end
    -- Keep empty lists as JSON arrays for the model.
    if value.messages then value.messages = json.array(value.messages) end
    if value.agents then value.agents = json.array(value.agents) end
    tool_result(true, value)
  end, function() return client.dead end, timeout)
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
    local control = assert(self:home(client.caller), "This Terminal Session has no Project")
    return reply(client, "200 OK", control:exchange(client.caller, request))
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
      instructions = "Control Anvil through stable Pane and Terminal Session IDs. Preserve focus unless asked. Use request_id for safe retries. A timeout does not cancel work. Close approves only the calling agent's own running Terminal; other Views keep normal confirmation. Self-close can stop the agent before the reply arrives. An agent that does not run in an Anvil Terminal is an External Agent: it receives messages through external_agent action=wait with its name, called again and again." }
  elseif request.method == "ping" then return result({})
  elseif request.method == "tools/list" then return result {tools = Control.tools}
  elseif request.method == "tools/call" then
    if type(params.arguments or {}) ~= "table" then return failure(-32602, "Invalid arguments") end
    local args = params.arguments or {}
    params.arguments = args
    local tool_result = self:tool_result(client, result)
    if not self.hub then return self:project_call(client, params, args, tool_result) end
    return self:hub_call(client, request, params, args, tool_result)
  end
  return failure(-32601, "Method not found")
end

-- The reply of a tool call. A text result is for the model. JSON would escape it again, so it has no structured copy.
function M:tool_result(client, result)
  return function(success, data)
    if success and client.observe then client.observe(data) end
    client.reply_wait = nil
    if success and type(data) == "string" then
      return result {isError = false, content = {{type = "text", text = data}}}
    end
    result {isError = not success, content = {{type = "text", text = success and json.encode(data) or tostring(data)}},
      structuredContent = success and data or {error = tostring(data)}}
  end
end

-- Runs a tool of `control` in this process. A conversation read and a wait end in `poll`.
function M:run(client, control, name, args, caller, sender, tool_result)
  local ok, value = pcall(control.call, control, name, args, caller, sender)
  if ok and name == "agent_transcript" then
    client.control, client.transcript = control, {query = value, result = tool_result}
    client.deadline = value.deadline + 5
    return
  end
  if ok and name == "agent_wait" and task_pending(value) and not value.waiting_for_user then
    client.control = control
    client.waiting = {args = args, result = tool_result, until_time = system.get_time() + (args.timeout_ms or 30000) / 1000}
    client.deadline = client.waiting.until_time + 5
    return
  end
  return tool_result(ok, value)
end

-- A Project process answers the editor operations of its own Project. The Machine server names the Terminal
-- that called it.
function M:project_call(client, params, args, tool_result)
  local name, control = params.name, self.control
  if agents_methods[name] or name == "external_agent" or name == "agent_send"
      or args.project ~= nil and not (type(args.project) == "string" and common.path_equals(args.project, control.project_key)) then
    return tool_result(false, USE_SERVER)
  end
  local caller = client.caller
  if caller == "local" and type(params._meta) == "table" and type(params._meta.anvil_caller) == "string" then
    caller = params._meta.anvil_caller
  end
  local function run()
    local ok, value = pcall(control.call, control, name, args, caller)
    if ok and name == "workspace_state" then
      return self:discover(client, function(endpoints)
        value.projects = {}
        value.projects[control.project_key] = {project = control.project_key}
        for _, endpoint in ipairs(endpoints) do value.projects[endpoint.project] = {project = endpoint.project} end
        tool_result(true, value)
      end)
    end
    return tool_result(ok, value)
  end
  -- An export detaches the Pane's Terminals, so move only to a Project that runs. Use its own name for it.
  if name == "pane" and type(args.target_project) == "string" then
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

-- Anvil's MCP server. It answers agent operations of this Machine's Projects, sends those of another Machine's
-- Projects through that Machine, and sends editor operations to the Project process.
function M:hub_call(client, request, params, args, tool_result)
  local hub, name = self.hub, params.name
  local projects = require "core.machine_project"
  -- A key of this Machine names a local Project.
  if type(args.project) == "string" then
    local machine, path = projects.parse(args.project)
    if machine and machine == projects.own_id() then args.project = path end
  end
  -- The Control that knows the caller: its Terminal's Project. Without a Terminal, the Project that it names.
  local control = self:home(client.caller)
  if not control and type(args.project) == "string" then control = hub.control(args.project) end
  local peer = control and control.peers[client.caller]
  local source = peer and {terminal = client.caller, instance = peer.instance, control = control}
  -- An External Agent's own send: the reply goes into its thread, on the Machine of this Project.
  local external_source
  if name == "agent_send" and control and type(args.from_agent) == "string" and not args.agent then
    local machine, path = machine_agents.machine_of(control.project_key, control.project)
    external_source = machine and {external = args.from_agent, machine = machine, path = path, control = control,
      deadline = system.get_time() + 3600}
  end
  local target, route, sender_project
  client.observe = function(value)
    local follower = external_source or source
    if not follower or client.dead or type(value) ~= "table" then return end
    if name == "agent_send" and value.task then
      self:follow_reply(follower, {terminal = value.terminal, instance = value.instance, control = target,
        project = sender_project, other_project = target ~= control}, value.task, route)
    elseif name == "agent_wait" and value.explicit_reply and peer then
      peer.waited_replies = peer.waited_replies or {}
      peer.waited_replies[#peer.waited_replies + 1] = value.task
      if #peer.waited_replies > 256 then table.remove(peer.waited_replies, 1) end
    end
  end
  if source and name == "agent_wait" then
    client.reply_wait = {task = args.task, terminal = source.terminal, instance = source.instance}
  end
  if name == "external_agent" or name == "agent_send" and args.agent ~= nil then
    return self:external(client, name, args, external_source or source, tool_result, control)
  end
  local project = args.project or hub.project_of(client.caller) or control and control.project
  if type(project) ~= "string" then
    if name ~= "workspace_state" then return tool_result(false, NAME_PROJECT) end
    -- A client without a Terminal learns the loaded Projects first.
    return self:discover(client, function(endpoints)
      local loaded = {}
      for _, endpoint in ipairs(endpoints) do loaded[endpoint.project] = {project = endpoint.project} end
      tool_result(true, {projects = loaded})
    end)
  end
  if agents_methods[name] then
    local sender = name == "agent_send" and control and control:sender(client.caller, args.from_agent) or nil
    local machine, path = projects.parse(project)
    if machine then
      -- Another Machine keeps its own agents. A reply comes back on the same route.
      sender_project = path
      route = function(query, done, cancelled)
        machine_agents.route(machine, path, "agent_read", query, client.caller, function(ok, value) done(ok and value or nil) end, cancelled)
      end
      client.forwarding, client.deadline = true, system.get_time() + 48
      return machine_agents.route(machine, path, name, args, client.caller, tool_result, function() return client.dead end, sender)
    end
    target = hub.control(project)
    if not target then return tool_result(false, "This Machine does not serve the Project " .. project) end
    sender_project = target.project_key
    -- A sender in another Project of this Machine shows its Project.
    if sender and target ~= control then sender.other_project = true else sender = nil end
    args.project = nil
    return self:run(client, target, name, args, client.caller, sender, tool_result)
  end
  -- The Project process owns its Panes, so it answers editor operations.
  return self:discover(client, function(endpoints)
    local found
    for _, endpoint in ipairs(endpoints) do
      if common.path_equals(endpoint.project, project) then
        if found then return tool_result(false, "Project has more than one control endpoint") end
        found = endpoint
      end
    end
    if not found then return tool_result(false, "Project is not loaded or has no control endpoint") end
    args.project = nil -- The destination already identifies the Project. Never forward twice.
    params._meta = {anvil_caller = client.caller ~= "local" and client.caller or nil}
    project_request(found, request, function(body)
      if not body then return tool_result(false, "Project control is unavailable") end
      client.reply_wait = nil
      reply(client, "200 OK", body)
    end, function() return client.dead end)
  end)
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
    local ok, err = pcall(self.dispatch, self, client, client.buffer:sub(client.header_end + 1))
    if not ok then
      core.log_quiet("Control: refused a request to %s: %s", client.path, tostring(err))
      reply(client, "400 Bad Request", {error = "Invalid control request"})
    end
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
      local ok, value = pcall(client.control.transcript_read, client.control, read.query)
      if not ok or value then
        client.control:cancel_transcript(read.query)
        client.transcript = nil
        read.result(ok, value)
      end
    elseif client.waiting and not client.dead then
      local wait = client.waiting
      if not wait.next_read or system.get_time() >= wait.next_read then
        wait.next_read = system.get_time() + 0.1
        local ok, value = pcall(client.control.wait_result, client.control, wait.args, wait.until_time)
        if not ok or value then
          wait.result(ok, value)
          client.waiting = nil
        end
      end
    elseif not client.replied and not client.dead and not client.forwarding then self:read(client) end
    if client.dead or system.get_time() > client.deadline
        or client.replied and (client.socket:get_pending_writes() or 0) == 0 then
      if client.transcript then client.control:cancel_transcript(client.transcript.query) end
      client.socket:close()
      client.dead = true
      table.remove(self.clients, i)
    end
    if system.get_time() >= stop then break end
  end
  if self.hub then self.hub.tick() elseif self.control.tick then self.control:tick() end
end

function M:close()
  for _, client in ipairs(self.clients) do
    if client.transcript then client.control:cancel_transcript(client.transcript.query) end
    client.dead = true; client.socket:close()
  end
  self.clients = {}
  if self.listener then self.listener:close(); self.listener = nil end
end

return M
