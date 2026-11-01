-- Starts `anvil serve` with its own user folder, and waits for its discovery file.
local json = require "core.json"
local M = {}

-- The server stands for another Machine, so the Client's Machine guard does not apply to it.
local start_process = process.start

function M.discovery_path(user)
  return user .. PATHSEP .. "machine" .. PATHSEP .. "server.json"
end

-- Starts the server process and does not wait. Tests take any free port, not the default port.
function M.spawn(user, args)
  local command = { EXEFILE, "serve", "--port", "0" }
  for _, arg in ipairs(args) do command[#command + 1] = arg end
  return assert(start_process(command, {
    stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD,
    env = { ANVIL_USERDIR = user },
  }))
end

-- Returns the discovery record when `server` publishes it.
function M.wait_discovery(user, server)
  local deadline = system.get_time() + 30
  repeat
    local file = io.open(M.discovery_path(user), "rb")
    if file then
      local found = json.decode(file:read("*a") or "")
      file:close()
      if type(found) == "table" and found.pid == server:pid() then return found end
    end
    coroutine.yield(0.05)
  until system.get_time() >= deadline or not server:running()
  if server:running() then server:kill() end
  error("The Machine server did not publish its discovery file")
end

-- Returns the server process and its discovery record. The test process is the server's owner,
-- so the server ends when a test crashes.
function M.start(user, args)
  os.remove(M.discovery_path(user))
  local command = { "--owner", tostring(system.get_process_id()) }
  for _, arg in ipairs(args) do command[#command + 1] = arg end
  local server = M.spawn(user, command)
  return server, M.wait_discovery(user, server)
end

function M.stop(server)
  if server and server:running() then
    server:kill()
    server:wait(5000, 0.01)
  end
end

return M
