-- Starts `anvil serve` with its own user folder, and waits for its discovery file.
local json = require "core.json"
local M = {}

-- The server stands for another Machine, so the Client's Machine guard does not apply to it.
local start_process = process.start

function M.discovery_path(user)
  return user .. PATHSEP .. "machine" .. PATHSEP .. "server.json"
end

-- Returns the server process and its discovery record.
function M.start(user, args)
  local path = M.discovery_path(user)
  os.remove(path)
  local command = { EXEFILE, "serve" }
  for _, arg in ipairs(args) do command[#command + 1] = arg end
  local server = assert(start_process(command, {
    stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD,
    env = { ANVIL_USERDIR = user },
  }))
  local deadline = system.get_time() + 30
  repeat
    local file = io.open(path, "rb")
    if file then
      local found = json.decode(file:read("*a") or "")
      file:close()
      if type(found) == "table" and found.pid == server:pid() then return server, found end
    end
    coroutine.yield(0.05)
  until system.get_time() >= deadline or not server:running()
  if server:running() then server:kill() end
  error("The Machine server did not publish its discovery file")
end

function M.stop(server)
  if server and server:running() then
    server:kill()
    server:wait(5000, 0.01)
  end
end

return M
