-- A Terminal Session on another Machine. Its native session (`terminal_native.new {remote = true}`) reads and writes
-- a local pipe as if a host were there. This module carries the pipe's records through the Machine's Terminal
-- service (`core.serve_terminal`). After a disconnect, it attaches again, and the session gets a new snapshot.
local core = require "core"
local common = require "core.common"

local machine_terminal = {}

-- Waits in this scheduler thread for the reply of one request. Returns its error, result and bytes.
local function call(client, method, params, bytes)
  local done, err, result, reply_bytes
  client:request(method, params, bytes, function(...) done, err, result, reply_bytes = true, ... end)
  while not done do coroutine.yield(0.005) end
  return err, result, reply_bytes
end

-- Carries the records of one attach until the link, the session or the Machine connection ends.
local function carry(remote, link, link_id)
  -- `ended`: the Machine's link ended. `closed`: the session closed its pipe.
  local client, ended, closed = remote.client, false, false
  core.add_thread(function()
    while not ended and not closed do
      local err, result, bytes = call(client, "terminal.read", {link = link_id})
      if ended or closed then return end
      if err or result.done then
        core.log_quiet("Remote Terminal Session %s link ended: %s", remote.id, err and err.code or "done")
        ended = true
        return
      end
      -- The session's reader empties the pipe quickly. A full link waits for it.
      while not ended do
        local ok, why = link:write(bytes)
        if ok then break end
        -- The session closed. Its last records still wait in the link for the loop below.
        if why ~= "full" then closed = true; return end
        coroutine.yield(0.01)
      end
    end
  end)
  while not ended do
    local bytes = link:read()
    -- The session closed its pipe after its last record, such as CLOSE. The Machine's link then ends, also when
    -- no read waits on it.
    if bytes == nil then
      closed = true
      call(client, "terminal.detach", {link = link_id})
      break
    end
    if bytes == "" then
      coroutine.yield(0.004)
    else
      local err = call(client, "terminal.write", {link = link_id}, bytes)
      while err and err.code == "busy" and not ended do
        coroutine.yield(0.05)
        err = call(client, "terminal.write", {link = link_id}, bytes)
      end
      -- A View device cannot type. Its Viewer keeps showing the screen.
      if err and err.code ~= "forbidden" then
        core.log_quiet("Remote Terminal Session %s write failed: %s", remote.id, tostring(err.code))
        break
      end
    end
  end
  ended = true
  -- The session then attaches again, unless it closed.
  link:close()
end

-- Errors of the Machine connection. The session attaches again after the reconnect.
local TRANSPORT = {offline = true, disconnected = true}

-- Connects `session` to the Terminal Session `id` of the Machine that `client` (`core.machine_client`) reaches.
-- With `start` ({project, cwd, shell, scrollback_lines}), a nil `id`, or an `id` that the Machine no longer has
-- at the first attach, starts a new shell. Returns an object whose `id` names the session once the Machine
-- answers, and whose `error` names why the session ended or did not start.
function machine_terminal.connect(client, session, id, start)
  local remote = {client = client, session = session, id = id}
  core.add_thread(function()
    local attached = false
    while session:wanted_size() and client.state ~= "closed" do
      if client.state ~= "ready" then
        coroutine.yield(0.1)
      else
        local cols, rows, cell_width, cell_height = session:wanted_size()
        local starting = remote.id == nil
        local params = {id = remote.id, cols = cols, rows = rows, cell_width = cell_width, cell_height = cell_height}
        if starting then
          for key, value in pairs(start) do params[key] = value end
        end
        local err, result = call(client, starting and "terminal.start" or "terminal.attach", params)
        if err and err.code == "not_found" and not starting and not attached and start then
          core.log_quiet("Remote Terminal Session %s is gone; start a new shell", remote.id)
          remote.id = nil
        elseif err and (err.code == "not_found" or (starting and not TRANSPORT[err.code])) then
          core.log_quiet("Remote Terminal Session %s ended on its Machine: %s %s", tostring(remote.id),
            tostring(err.code), tostring(err.message))
          remote.error = err.message or "The Terminal Session has ended"
          return
        else
          local link = not err and session:wanted_size() and session:attach_remote(result)
          if link then
            remote.id, attached = result.session_id, true
            core.log_quiet("Remote Terminal Session %s attached: link=%s", remote.id, tostring(result.link))
            carry(remote, link, result.link)
          elseif not err then
            -- The session closed during the attach. Its host must not keep this Client.
            call(client, "terminal.detach", {link = result.link})
          end
          coroutine.yield(0.25)
        end
      end
    end
  end)
  return remote
end

-- Text fields of a listed session, with their byte limits.
local TEXT = {title = 256, cwd = 1024, agent_state = 32, agent_kind = 32, agent_app = 64, agent_model = 128,
  agent_message = 256, agent_step = 256}
local TIMES = {"activity", "command_started", "command_finished", "agent_since", "agent_step_since"}
local LIST_INTERVAL = 2

-- Shortens text at a UTF-8 boundary.
local function cut(text, limit)
  if #text <= limit then return text end
  local size = limit
  while size > 0 and (text:byte(size + 1) or 0) >= 0x80 and (text:byte(size + 1) or 0) < 0xC0 do size = size - 1 end
  return text:sub(1, size)
end

-- A session of `terminal.list` as a Project Sidebar Terminal item, as the shell's scan makes from a record.
local function sidebar_item(session)
  if type(session) ~= "table" or type(session.id) ~= "string" or #session.id ~= 32 or session.id:find("[^0-9a-f]") then
    return nil
  end
  local item = {id = session.id, state = "running", attached = session.attached == true,
    busy = session.busy == true and 1 or session.busy == false and 0 or -1,
    command_exit = (tonumber(session.command_exit) or 0) ~= 0 and 1 or 0}
  for field, limit in pairs(TEXT) do
    local value = session[field]
    if type(value) == "string" and not value:find("%c") then item[field] = cut(value, limit) end
  end
  item.title, item.cwd = item.title or "", item.cwd or ""
  for _, field in ipairs(TIMES) do
    local value = tonumber(session[field])
    item[field] = value and value > 0 and value < 1e12 and math.floor(value) or 0
  end
  return item
end

local listed, watched

-- The Terminal Sessions that the Machine of `client` lists for `project`, newest first, as Project Sidebar items.
-- The first call starts a list every 2 seconds while the Machine is connected. Returns nil before the first list.
-- A Machine without a Terminal service lists nothing.
function machine_terminal.sessions(client, project)
  if watched == client then return listed end
  watched, listed = client, nil
  core.add_thread(function()
    while watched == client and client.state ~= "closed" do
      if client.state == "ready" then
        local err, result = call(client, "terminal.list", {project = project})
        if watched ~= client then return end
        if err and not TRANSPORT[err.code] then
          core.log_quiet("Machine Terminal Sessions are not listed: %s %s", tostring(err.code), tostring(err.message))
          return
        end
        if not err then
          local items = {}
          for _, session in ipairs(type(result.sessions) == "table" and result.sessions or {}) do
            items[#items + 1] = sidebar_item(session)
          end
          if common.serialize(items, {sort = true}) ~= common.serialize(listed or {}, {sort = true}) or not listed then
            core.log_quiet("Machine Terminal Sessions listed: %d", #items)
            listed = items
            core.redraw = true
          end
        end
      end
      coroutine.yield(LIST_INTERVAL)
    end
    if watched == client then watched, listed = nil, nil end
  end)
  return listed
end

-- True when the Machine listed the session in its last list.
function machine_terminal.listed(id)
  for _, item in ipairs(listed or {}) do
    if item.id == id then return true end
  end
  return false
end

return machine_terminal
