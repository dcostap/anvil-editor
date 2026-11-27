-- The External Agent service of the Machine server (`core.serve`). An External Agent runs outside Anvil's Terminal
-- Sessions, such as Antigravity's agent. It has a name in a Project and a thread of messages. Its first waiting read
-- with `listen` creates it. Full control Clients post to the thread. The agent reads the messages of others.
-- `read` is the last message that the agent has received. Threads stay in `USERDIR/machine/external`, so a server
-- restart keeps them.
local common = require "core.common"
local agent_name = require "core.agent_name"
local json = require "core.lsp.json"
local net = require "net"
local M = {}

local MAX_AGENTS, MAX_MESSAGES, MAX_TEXT, MAX_PAGE, MAX_WAITS = 16, 200, 32768, 100, 8
-- A read waits at most MAX_WAIT seconds. An agent listens while it waits, and for LISTEN_SECONDS after a read.
local MAX_WAIT, LISTEN_SECONDS = 25, 60
local FROM_KINDS = {user = true, agent = true, self = true}
local FROM_FIELDS = {"name", "terminal", "instance", "project", "machine"}
-- The kinds of Project Chat messages that a Pi posts. See CONTEXT.md.
local CHAT_KINDS = {user = true, output = true, answer = true, agent = true}
local NO_CLIENT = {}

function M.valid_name(name)
  return type(name) == "string" and #name <= 64 and name:match("^[%w][%w%._%-]*$") ~= nil
end

-- A file name for a Project. Two hashes keep collisions rare; the file also names its Project.
local function file_key(root)
  local key, a, b = common.path_compare_key(root), 0, 0
  for i = 1, #key do
    a = (a * 31 + key:byte(i)) % 4294967291
    b = (b * 131 + key:byte(i)) % 4294967279
  end
  return string.format("%08x%08x", a, b)
end

local function clean_from(from, client)
  local result = {kind = type(from) == "table" and FROM_KINDS[from.kind] and from.kind or "user"}
  for _, field in ipairs(FROM_FIELDS) do
    local value = type(from) == "table" and from[field]
    if type(value) == "string" and value ~= "" then result[field] = value:sub(1, 256) end
  end
  -- A paired device names itself. Only the owner's own processes can name another Machine.
  if client.device then result.machine = client.name or client.device end
  return result
end

-- `server` gives: reply, fail, project_root, log and on_close.
function M.new(server, directory)
  directory = directory or USERDIR .. PATHSEP .. "machine" .. PATHSEP .. "external"
  local projects, waits, dirty = {}, {}, {}

  local function project(root)
    local key = common.path_compare_key(root)
    if projects[key] then return projects[key] end
    local state = {root = root, agents = {}, chat = {messages = {}, seq = 0, last_listen = 0}, path = directory .. PATHSEP .. file_key(root) .. ".json"}
    local file = io.open(state.path, "rb")
    local ok, saved = pcall(json.decode, file and file:read("*a") or "")
    if file then file:close() end
    if ok and type(saved) == "table" and saved.version == 1 and type(saved.project) == "string"
        and common.path_equals(saved.project, root) and type(saved.agents) == "table" then
      if type(saved.chat) == "table" then state.chat = saved.chat end
      for _, agent in ipairs(saved.agents) do
        if M.valid_name(agent.name) and type(agent.seq) == "number" and type(agent.messages) == "table" then
          state.agents[agent.name] = {name = agent.name, seq = agent.seq, messages = agent.messages, last_listen = 0,
            read = type(agent.read) == "number" and agent.read or 0}
          state.agents[agent.name].shown_read = state.agents[agent.name].read
        end
      end
    end
    projects[key] = state
    return state
  end

  local function listening(agent)
    return (agent.listeners or 0) > 0 or system.get_time() - agent.last_listen < LISTEN_SECONDS
  end

  local function agent_list(state)
    local list = json.array()
    for _, agent in pairs(state.agents) do
      local last = agent.messages[#agent.messages]
      list[#list + 1] = {name = agent.name, listening = listening(agent), seq = agent.seq, time = last and last.time}
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
  end

  -- The messages after `after`, up to MAX_PAGE. A listening agent does not read its own messages.
  local function page(agent, wait)
    local messages, cursor = json.array(), wait.after
    for _, message in ipairs(agent.messages) do
      local matches
      if wait.reply_to then matches = message.reply_to == wait.reply_to
      else matches = message.seq > wait.after and not (wait.listen and message.from.kind == "self") end
      if matches then
        if #messages >= (wait.limit or MAX_PAGE) then break end
        messages[#messages + 1] = message
        cursor = math.max(cursor, message.seq)
      end
    end
    -- A listening agent's cursor passes its own messages, so the next wait does not find them again.
    if wait.listen and #messages < MAX_PAGE then cursor = math.max(cursor, agent.seq) end
    return {agent = agent.name, messages = messages, cursor = cursor, seq = agent.seq, listening = listening(agent),
      read = agent.read}
  end

  -- Sends a read's result. The messages of a listening read reach the agent, so they count as read.
  local function deliver(wait, result)
    local agent = wait.agent
    if wait.listen and not wait.reply_to and result.cursor > agent.read then
      agent.read, result.read = result.cursor, result.cursor
      dirty[wait.state] = true
    end
    server.reply(wait.client, wait.id, {result = result})
  end

  local function finish(wait, result)
    for i, item in ipairs(waits) do
      if item == wait then table.remove(waits, i); break end
    end
    if wait.listen then wait.agent.listeners = wait.agent.listeners - 1 end
    deliver(wait, result)
  end

  -- Answers each wait that now has messages. `changed` also answers the waits of Views, for a change of the
  -- agent's listening or read state.
  local function wake(agent, changed)
    for i = #waits, 1, -1 do
      local wait = waits[i]
      if wait and wait.agent == agent then
        local result = page(agent, wait)
        if #result.messages > 0 or changed and not wait.listen then finish(wait, result) end
      end
    end
  end

  local function read(client, id, params, chat)
    local root = server.project_root(params.project)
    if not root then return server.fail(client, id, "outside_project", "Unknown Project") end
    if chat ~= true and not M.valid_name(params.agent) then return server.fail(client, id, "invalid_request", "Invalid agent name") end
    local state = project(root)
    local agent = chat == true and state.chat or state.agents[params.agent]
    if not agent then
      if not params.listen then return server.fail(client, id, "not_found", "No External Agent " .. params.agent) end
      if client.level ~= "full" then return server.fail(client, id, "forbidden", "This device has View access") end
      local count = 0
      for _ in pairs(state.agents) do count = count + 1 end
      if count >= MAX_AGENTS then return server.fail(client, id, "busy", "This Project has too many External Agents") end
      agent = {name = params.agent, seq = 0, messages = {}, last_listen = 0, read = 0, shown_read = 0}
      state.agents[agent.name] = agent
      dirty[state] = true
      server.log("External Agent %s registered in %s", agent.name, root)
    end
    local after = type(params.after) == "number" and params.after >= 0 and math.floor(params.after) or 0
    -- A lost thread file starts again at 1. Its old cursor must not hide the new messages.
    if after > agent.seq then after = 0 end
    local wait = {client = client, id = id, agent = agent, state = state, after = after, listen = params.listen == true,
      reply_to = type(params.reply_to) == "string" and params.reply_to or nil}
    if chat == true then wait.limit, wait.listen, wait.reply_to = 4, false, nil end
    if wait.listen then agent.last_listen = system.get_time() end
    local result = page(agent, wait)
    if #result.messages > 0 or params.wait ~= true then return deliver(wait, result) end
    local count = 0
    for _, item in ipairs(waits) do if item.client == client then count = count + 1 end end
    if count >= MAX_WAITS then return server.fail(client, id, "busy", "Too many waiting reads") end
    local seconds = type(params.timeout_ms) == "number" and params.timeout_ms / 1000 or MAX_WAIT
    wait.deadline = system.get_time() + math.max(0, math.min(MAX_WAIT, seconds))
    if wait.listen then agent.listeners = (agent.listeners or 0) + 1 end
    waits[#waits + 1] = wait
  end

  local function append(state, message)
    local chat = state.chat
    chat.seq = chat.seq + 1
    message.seq, message.time = chat.seq, os.time()
    chat.messages[#chat.messages + 1] = message
    if #chat.messages > MAX_MESSAGES then table.remove(chat.messages, 1) end
    dirty[state] = true
    wake(chat, true)
  end

  -- A Pi posts the readable messages of its conversation: what the user typed, its output and answers, and the
  -- messages of other agents to it, and its replies to them. Each message has one author that posts it, so a lost
  -- acknowledgement is the only source of a copy, and `source` finds that copy.
  server.chat_post = function(root, terminal, instance, post)
    local state = project(root)
    local key = terminal .. ":" .. instance .. ":" .. post.id
    for _, m in ipairs(state.chat.messages) do if m.source == key or m.request == key then return end end
    local pi = {kind = "agent", terminal = terminal, instance = instance, name = agent_name.for_terminal(terminal)}
    local function id(value) return type(value) == "string" and #value <= 128 and value or nil end
    -- A Pi without kinds posts only answers.
    local kind = CHAT_KINDS[post.kind] and post.kind or "answer"
    local message = {kind = kind, source = key, request = id(post.request) or key, text = post.text,
      reply_to = id(post.reply_to)}
    if kind == "user" then
      message.from, message.to = {kind = "user"}, {name = pi.name, terminal = terminal, instance = instance}
    elseif kind == "agent" and type(post.from) == "table" then
      -- A message from another agent. A reply goes to its author: an External Agent, or a Pi in this Project.
      local from = clean_from(post.from, NO_CLIENT)
      from.kind = "agent"
      if M.valid_name(post.from.external) then
        from.name, message.external = post.from.external, post.from.external
      elseif from.terminal and from.instance and not post.from.other_project and not from.machine then
        message.pi = true
      end
      message.from, message.to = from, {name = pi.name, terminal = terminal, instance = instance}
    else
      message.pi, message.from = true, pi
      if kind == "agent" and type(post.to) == "table" then
        message.to = clean_from(post.to, NO_CLIENT)
        message.to.kind = "agent"
      end
    end
    append(state, message)
  end

  local function post(client, id, params, parent)
    local root = server.project_root(params.project)
    if not root then return server.fail(client, id, "outside_project", "Unknown Project") end
    if not M.valid_name(params.agent) then return server.fail(client, id, "invalid_request", "Invalid agent name") end
    if type(params.text) ~= "string" or not params.text:find("%S") or #params.text > MAX_TEXT then
      return server.fail(client, id, "invalid_request", "A message needs 1 to 32768 bytes of text")
    end
    local state = project(root)
    local agent = state.agents[params.agent]
    if not agent then return server.fail(client, id, "not_found", "No External Agent " .. params.agent) end
    local from = clean_from(params.from, client)
    agent.seq = agent.seq + 1
    local message = {seq = agent.seq, time = os.time(), from = from, text = params.text,
      reply_to = type(params.reply_to) == "string" and params.reply_to:sub(1, 128) or nil}
    -- A message to the agent gets a request ID, so its answer can name it.
    if from.kind ~= "self" then
      message.request = "r" .. net.random_token():sub(1, 15)
      if params.expect_reply == false then message.expect_reply = false end
    end
    -- The agent's answer to an agent is an agent message too, and names that agent.
    local to, kind = {name = agent.name, external = agent.name}, from.kind
    if from.kind == "self" then
      to, kind = nil, "answer"
      for _, asked in ipairs(agent.messages) do
        if message.reply_to and asked.request == message.reply_to and asked.from.kind == "agent" then
          to, kind = asked.from, "agent"
        end
      end
    end
    agent.messages[#agent.messages + 1] = message
    append(state, {kind = kind, from = from.kind == "self" and {kind = "agent", name = agent.name} or from,
      external = from.kind == "self" and agent.name or nil, text = message.text, to = to,
      request = message.request or net.random_token(), reply_to = type(parent) == "table" and parent.request or message.reply_to})
    if #agent.messages > MAX_MESSAGES then table.remove(agent.messages, 1) end
    dirty[state] = true
    wake(agent)
    server.reply(client, id, {result = {agent = agent.name, seq = message.seq, request = message.request}})
  end

  local function send_pi(client, id, state, target, text, parent)
    if not server.chat_deliver then return server.fail(client, id, "not_connected", "Pi is not connected") end
    local request = net.random_token()
    local ok, err = pcall(server.chat_deliver, state.root, target, request, text, parent and parent.time,
      function(accepted, reason)
        if not accepted then return server.fail(client, id, "not_connected", reason) end
        append(state, {kind = "user", from = clean_from(nil, client), request = request, text = text,
          to = {name = agent_name.for_terminal(target.terminal), terminal = target.terminal, instance = target.instance},
          reply_to = parent and parent.request})
        server.reply(client, id, {result = {task = request}})
      end)
    if not ok then server.fail(client, id, "not_connected", tostring(err)) end
  end

  local function valid_text(text)
    return type(text) == "string" and #text <= MAX_TEXT and text:find("%S") ~= nil
  end

  local function valid_id(id)
    return type(id) == "string" and #id > 0 and #id <= 128
  end

  local function save(state)
    local agents = json.array()
    for _, agent in pairs(state.agents) do
      agents[#agents + 1] = {name = agent.name, seq = agent.seq, read = agent.read, messages = agent.messages}
    end
    local temporary = state.path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then return server.log("External Agents: cannot write %s", temporary) end
    file:write(json.encode {version = 1, project = state.root, agents = agents, chat = state.chat})
    file:close()
    if not system.replace_file(temporary, state.path) then server.log("External Agents: cannot replace %s", state.path) end
  end

  server.on_close(function(client)
    for i = #waits, 1, -1 do
      local wait = waits[i]
      if wait.client == client then
        table.remove(waits, i)
        if wait.listen then wait.agent.listeners = wait.agent.listeners - 1 end
      end
    end
  end)

  require("core").add_thread(function()
    local ready = false
    while true do
      local now = system.get_time()
      for i = #waits, 1, -1 do
        local wait = waits[i]
        if wait and now >= wait.deadline then finish(wait, page(wait.agent, wait)) end
      end
      -- An agent that stopped reading stops listening. The Views of its thread learn it, and what it read, at once.
      for _, state in pairs(projects) do
        for _, agent in pairs(state.agents) do
          local now_listening = listening(agent)
          if agent.shown_read ~= agent.read or agent.shown_listening ~= nil and agent.shown_listening ~= now_listening then
            wake(agent, true)
          end
          agent.shown_listening, agent.shown_read = now_listening, agent.read
        end
      end
      if next(dirty) then
        if not ready then net.private_directory(directory); ready = true end
        for state in pairs(dirty) do save(state) end
        dirty = {}
      end
      coroutine.yield(0.25)
    end
  end)

  return {
    ["chat.read"] = function(client, id, params) return read(client, id, params, true) end,
    ["chat.recipients"] = function(client, id, params)
      local root = server.project_root(params.project)
      if not root then return server.fail(client, id, "outside_project", "Unknown Project") end
      local recipients = json.array()
      for name in pairs(project(root).agents) do
        recipients[#recipients + 1] = {name = name, external = name}
      end
      if server.chat_recipients then server.chat_recipients(root, recipients) end
      server.reply(client, id, {result = {agents = recipients}})
    end,
    ["chat.send"] = function(client, id, params)
      local root = server.project_root(params.project)
      if not root then return server.fail(client, id, "outside_project", "Unknown Project") end
      if not valid_text(params.text) then
        return server.fail(client, id, "invalid_request", "A message needs 1 to 32768 bytes")
      end
      local target = params.recipient
      if type(target) == "table" then
        if M.valid_name(target.external) and target.terminal == nil then
          return post(client, id, {project = root, agent = target.external, text = params.text})
        end
        if target.external == nil and valid_id(target.terminal) and valid_id(target.instance) then
          return send_pi(client, id, project(root), target, params.text)
        end
      end
      return server.fail(client, id, "invalid_request", "Choose a chat recipient")
    end,
    ["chat.reply"] = function(client, id, params)
      local root = server.project_root(params.project)
      if not root then return server.fail(client, id, "outside_project", "Unknown Project") end
      if not valid_text(params.text) then
        return server.fail(client, id, "invalid_request", "A reply needs 1 to 32768 bytes")
      end
      local state = project(root)
      for _, m in ipairs(state.chat.messages) do
        if m.request == params.parent and type(params.parent) == "string" then
          if m.external then return post(client, id, {project = root, agent = m.external, text = params.text}, m) end
          if m.pi then return send_pi(client, id, state, m.from, params.text, m) end
        end
      end
      return server.fail(client, id, "not_found", "This result is no longer available for reply")
    end,
    ["external.list"] = function(client, id, params)
      local root = server.project_root(params.project)
      if not root then return server.fail(client, id, "outside_project", "Unknown Project") end
      server.reply(client, id, {result = {agents = agent_list(project(root))}})
    end,
    ["external.read"] = read,
    ["external.post"] = post,
  }
end

return M
