-- Access to this PC's Machine server from other devices. The server listens on loopback only, so other
-- devices reach it through Tailscale Serve: Tailscale takes connections on the PC's tailnet address and forwards
-- them to the server's loopback port. Only devices in the user's tailnet reach that address.
local core = require "core"
local json = require "core.json"
local worker_pool = require "core.worker_pool"

local access = {}

-- `tailscale serve` waits while the tailnet has Serve turned off. A stop after this time shows its message.
local TIMEOUT = 20

-- The Tailscale CLI, or nil when Tailscale is not installed.
function access.executable()
  local name = PLATFORM == "Windows" and "tailscale.exe" or "tailscale"
  local folders = {}
  if PLATFORM == "Windows" then
    folders[1] = (os.getenv("ProgramFiles") or "C:\\Program Files") .. "\\Tailscale"
  elseif PLATFORM == "Mac OS X" then
    folders[1] = "/Applications/Tailscale.app/Contents/MacOS"
  end
  for folder in (os.getenv("PATH") or ""):gmatch(PLATFORM == "Windows" and "[^;]+" or "[^:]+") do
    folders[#folders + 1] = folder
  end
  for _, folder in ipairs(folders) do
    local path = folder .. PATHSEP .. name
    local info = system.get_file_info(path)
    if info and info.type == "file" then return path end
  end
end

-- Runs the Tailscale CLI with `args` in a worker. `on_done(output, err)` gets its standard output, or an error
-- message. Tests replace this function.
function access.run(args, on_done)
  local executable = access.executable()
  if not executable then return on_done(nil, "missing") end
  local command = {executable}
  for _, arg in ipairs(args) do command[#command + 1] = arg end
  local done = false
  local function finish(output, err)
    if done then return end
    done = true
    core.try(on_done, output, err)
  end
  local pool = worker_pool.named("tailscale", {worker_count = 1})
  local handle, err = pool:submit {
    kind = "process_capture",
    payload = {command = command, max_output = 1024 * 1024, max_stderr = 64 * 1024},
    on_result = function(message)
      local result = message.payload or {}
      if result.error then return finish(nil, result.error.message or result.error.kind) end
      if result.code ~= 0 then
        local text = (result.stderr ~= "" and result.stderr or result.stdout or ""):gsub("%s+", " ")
        return finish(nil, text ~= " " and text ~= "" and text or "Tailscale failed")
      end
      finish(result.stdout or "")
    end,
    on_error = function(message) finish(nil, tostring(message.error or "The Tailscale worker failed")) end,
    on_cancelled = function() finish(nil, "Tailscale did not answer") end,
  }
  if not handle then return finish(nil, tostring(err)) end
  core.add_thread(function()
    local deadline = system.get_time() + TIMEOUT
    while not done and system.get_time() < deadline do coroutine.yield(0.25) end
    if not done then
      pool:cancel(handle)
      finish(nil, "Tailscale did not answer in " .. TIMEOUT .. " seconds")
    end
  end)
end

local function decode(output)
  local ok, value = pcall(json.decode, output or "")
  return ok and type(value) == "table" and value or nil
end

-- Calls `on_done(status)` with the access of the server on `port`. `status.state` is one of:
--   "missing"       Tailscale is not installed
--   "disconnected"  Tailscale does not run, or is not signed in
--   "off"           Tailscale runs, but does not forward the port
--   "on"            tailnet devices reach the server at `status.address`
--   "error"         Tailscale failed, with `status.message`
function access.status(port, on_done)
  access.run({"status", "--json"}, function(output, err)
    if err == "missing" then return on_done({state = "missing"}) end
    local status = decode(output)
    if not status then return on_done({state = "disconnected", message = err}) end
    if status.BackendState ~= "Running" then return on_done({state = "disconnected"}) end
    local host = type(status.Self) == "table" and type(status.Self.DNSName) == "string"
      and status.Self.DNSName:gsub("%.$", "") or nil
    access.run({"serve", "status", "--json"}, function(serve_output, serve_err)
      if serve_err then return on_done({state = "error", message = serve_err}) end
      local serve = decode(serve_output) or {}
      local handler = type(serve.TCP) == "table" and serve.TCP[tostring(port)]
      local target = type(handler) == "table" and handler.TCPForward
      local forwarded = type(target) == "string" and target:match(":(%d+)$") == tostring(port)
      core.log_quiet("Machine access: Tailscale %s, port %d forwarded=%s", tostring(host), port, tostring(forwarded))
      on_done({state = forwarded and "on" or "off", address = host and (host .. ":" .. port)})
    end)
  end)
end

-- Turns the forwarding of `port` on or off, then calls `on_done(status)` with the new status.
function access.set(port, on, on_done)
  local args = on and {"serve", "--bg", "--tcp", tostring(port), "tcp://localhost:" .. port}
    or {"serve", "--tcp", tostring(port), "off"}
  core.log_quiet("Machine access: turn Tailscale forwarding %s for port %d", on and "on" or "off", port)
  access.run(args, function(_, err)
    if err then return on_done({state = "error", message = err}) end
    access.status(port, on_done)
  end)
end

return access
