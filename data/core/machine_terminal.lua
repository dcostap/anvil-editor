-- A Terminal Session on another Machine. Its native session (`terminal_native.new {remote = true}`) reads and writes
-- a local pipe as if a host were there. This module carries the pipe's records through the Machine's Terminal
-- service (`core.serve_terminal`). After a disconnect, it attaches again, and the session gets a new snapshot.
local core = require "core"

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
  local client, ended = remote.client, false
  core.add_thread(function()
    while not ended do
      local err, result, bytes = call(client, "terminal.read", {link = link_id})
      if ended then return end
      if err or result.done then
        core.log_quiet("Remote Terminal Session %s link ended: %s", remote.id, err and err.code or "done")
        ended = true
        return
      end
      -- The session's reader empties the pipe quickly. A full link waits for it.
      while not ended do
        local ok, why = link:write(bytes)
        if ok then break end
        if why ~= "full" then ended = true; return end
        coroutine.yield(0.01)
      end
    end
  end)
  while not ended do
    local bytes = link:read()
    -- The session closed its pipe. Its last record, such as CLOSE, was in the previous bytes.
    if bytes == nil then break end
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

return machine_terminal
