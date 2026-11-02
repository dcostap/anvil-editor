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

-- Connects `session` to the Terminal Session `id` of the Machine that `client` (`core.machine_client`) reaches.
-- Returns an object whose `error` names why the session ended on the Machine, such as a closed shell.
function machine_terminal.connect(client, session, id)
  local remote = {client = client, session = session, id = id}
  core.add_thread(function()
    while session:wanted_size() and client.state ~= "closed" do
      if client.state ~= "ready" then
        coroutine.yield(0.1)
      else
        local cols, rows, cell_width, cell_height = session:wanted_size()
        local err, result = call(client, "terminal.attach",
          {id = id, cols = cols, rows = rows, cell_width = cell_width, cell_height = cell_height})
        if err and err.code == "not_found" then
          core.log_quiet("Remote Terminal Session %s ended on its Machine: %s", id, tostring(err.message))
          remote.error = err.message or "The Terminal Session has ended"
          return
        end
        local link = not err and session:wanted_size() and session:attach_remote(result)
        if link then
          core.log_quiet("Remote Terminal Session %s attached: link=%s", id, tostring(result.link))
          carry(remote, link, result.link)
        elseif not err then
          -- The session closed during the attach. Its host must not keep this Client.
          call(client, "terminal.detach", {link = result.link})
        end
        coroutine.yield(0.25)
      end
    end
  end)
  return remote
end

return machine_terminal
