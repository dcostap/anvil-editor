-- The Terminal service of the Machine server (`core.serve`): the Terminal Sessions of the Machine's Projects, for
-- Terminals on a Client. The server attaches to a session's host as one more Client of the host, and carries the
-- host's framed records (`src/terminal_protocol.h`) in both directions. A View device attaches view-only.
local core = require "core"
local common = require "core.common"
local terminal_native = require "terminal_native"
local terminal_link = require "terminal_link"

local terminal = {}

-- A reply carries at most CHUNK bytes of whole records. Each Client has at most MAX_LINKS attached sessions.
local CHUNK, MAX_LINKS = 1024 * 1024, 32

-- Returns the session's record, or nil.
local function read_record(id)
  if type(id) ~= "string" or #id ~= 32 or id:find("[^0-9a-f]") then return end
  local text = terminal_native.read_session_record(id)
  local chunk = text and load(text, "=record", "t", {})
  local ok, record = pcall(chunk or function() end)
  if ok and type(record) == "table" and record.session_id == id and type(record.host_pid) == "number"
      and type(record.host_creation_time) == "string" and type(record.project_path) == "string" then
    return record
  end
end

local function closed_marker(id)
  return USERDIR .. PATHSEP .. "terminal-sessions" .. PATHSEP .. id .. ".closed"
end

-- The host keeps 63 bytes of a device name. The cut must not split a character.
local function device_name(name)
  if type(name) ~= "string" then return nil end
  local parts, bytes = {}, 0
  for char in common.utf8_chars(name) do
    if bytes + #char > 63 then break end
    parts[#parts + 1] = char
    bytes = bytes + #char
  end
  return table.concat(parts)
end

local function size_param(params, name, high)
  local value = params[name]
  return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= high
end

-- `server` gives: reply, fail, project_root, log and on_close.
function terminal.new(server)
  local links, sequence = {}, 0

  local function find_record(client, id, params)
    local record = read_record(params.id)
    if record and record.status == "running" and server.project_root(record.project_path)
        and not system.get_file_info(closed_marker(params.id)) then
      return record
    end
    server.fail(client, id, "not_found", "This Machine has no such Terminal Session")
  end

  -- A read that waits for a removed link gets `done`, so the Client attaches again.
  local function remove(state)
    if links[state.id] ~= state then return end
    links[state.id] = nil
    state.client.links = state.client.links - 1
    state.link:close()
    local waiter = state.waiter
    state.waiter = nil
    if waiter then server.reply(state.client, waiter, {result = {done = true}}) end
  end

  -- Answers the attach when the host does, then each read when records wait.
  local function pump(state)
    while links[state.id] == state do
      if state.client.dead then return remove(state) end
      local status, info = state.link:status()
      if state.attach_waiter and status ~= "connecting" then
        local waiter = state.attach_waiter
        state.attach_waiter = nil
        if status == "closed" then
          server.log("Machine server cannot attach Terminal Session %s: error %s", state.session, tostring(info.error))
          server.fail(state.client, waiter, "attach_failed", "The Terminal Session did not answer")
          return remove(state)
        end
        info.link = state.id
        server.reply(state.client, waiter, {result = info})
      end
      if state.waiter then
        local bytes = state.link:read(CHUNK)
        if bytes == nil then
          server.log("Machine server Terminal link %s ended: error %s", state.id, tostring(info.error))
          return remove(state)
        end
        if bytes ~= "" then
          local waiter = state.waiter
          state.waiter = nil
          server.reply(state.client, waiter, {result = {}}, bytes)
        end
      end
      coroutine.yield(0.004)
    end
  end

  -- `terminal.list {project}` lists the running Terminal Sessions of a Project.
  local function list(client, id, params)
    local root = server.project_root(params.project)
    if not root then return server.fail(client, id, "outside_project", "This Machine has no such Project") end
    local sessions = {}
    for _, name in ipairs(system.list_dir(USERDIR .. PATHSEP .. "terminal-sessions") or {}) do
      local record = read_record(name:match("^(%x+)%.lua$"))
      if record and record.status == "running" and common.path_equals(record.project_path, root)
          and terminal_link.host_alive(record.host_pid, record.host_creation_time)
          and not system.get_file_info(closed_marker(record.session_id)) then
        sessions[#sessions + 1] = {id = record.session_id, title = record.title, cwd = record.cwd,
          shell = record.shell, busy = record.busy, activity = record.activity,
          agent_state = record.agent_state, agent_app = record.agent_app, agent_model = record.agent_model}
      end
    end
    table.sort(sessions, function(a, b) return (a.activity or 0) > (b.activity or 0) end)
    server.reply(client, id, {result = {sessions = sessions}})
  end

  -- `terminal.attach {id, cols, rows, cell_width, cell_height}` attaches to a session with the Client's size.
  -- The reply gives the `link` and the session's `shell_pid` and size. `terminal.read` then gives the snapshot
  -- and the output. A View device attaches view-only. Other Clients of the host see the paired device's name.
  local function attach(client, id, params)
    if not (size_param(params, "cols", 32767) and size_param(params, "rows", 32767)
        and size_param(params, "cell_width", 65535) and size_param(params, "cell_height", 65535)) then
      return server.fail(client, id, "invalid_request", "The size is not valid")
    end
    local record = find_record(client, id, params)
    if not record then return end
    client.links = client.links or 0
    if client.links >= MAX_LINKS then
      return server.fail(client, id, "too_many", "This device has too many attached Terminal Sessions")
    end
    local link, err = terminal_link.connect {session_id = record.session_id, host_pid = record.host_pid,
      host_creation_time = record.host_creation_time, cols = params.cols, rows = params.rows,
      cell_width = params.cell_width, cell_height = params.cell_height, name = device_name(client.name),
      full = client.level == "full"}
    if not link then return server.fail(client, id, "not_found", err) end
    sequence = sequence + 1
    local state = {id = tostring(sequence), session = record.session_id, client = client, link = link,
      attach_waiter = id}
    links[state.id], client.links = state, client.links + 1
    server.log("Machine server attaches Terminal Session %s: link=%s level=%s", state.session, state.id,
      tostring(client.level))
    core.add_thread(function() pump(state) end)
  end

  local function find(client, id, params)
    local state = links[params.link]
    if state and state.client == client and not state.attach_waiter then return state end
    server.fail(client, id, "not_found", "The Terminal link has ended")
  end

  -- `terminal.read {link}` waits for records. Its reply carries them in the bytes. `done = true` ends the link.
  local function read(client, id, params)
    local state = find(client, id, params)
    if state then state.waiter = id end
  end

  -- `terminal.write {link}` sends the records in the bytes to the host. A View device can only detach. A DETACH,
  -- CLOSE or END record ends the link after the host reads it.
  local function write(client, id, params, bytes)
    local state = find(client, id, params)
    if not state then return end
    local ok, err = state.link:write(bytes or "")
    if ok then return server.reply(client, id, {result = {}}) end
    if err == "invalid" then return server.fail(client, id, "forbidden", "The Terminal link refused the records") end
    if err == "full" then return server.fail(client, id, "busy", "The Terminal Session reads its input slowly") end
    server.fail(client, id, "not_found", "The Terminal link has ended")
  end

  -- `terminal.detach {link}` ends the link. The host keeps the session.
  local function detach(client, id, params)
    local state = links[params.link]
    if state and state.client == client then remove(state) end
    server.reply(client, id, {result = {}})
  end

  server.on_close(function(client)
    for _, state in pairs(links) do
      if state.client == client then remove(state) end
    end
  end)

  return {["terminal.list"] = list, ["terminal.attach"] = attach, ["terminal.read"] = read,
    ["terminal.write"] = write, ["terminal.detach"] = detach}
end

return terminal
