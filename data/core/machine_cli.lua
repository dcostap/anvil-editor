-- `anvil machine <command>`: manages the paired devices of the Machine server that runs on this PC.
-- It runs without a window, connects as the local owner through the discovery file, and exits.
local json = require "core.json"
local machine = require "machine"
local net = require "net"

local core = {}
local PROTOCOL, TIMEOUT = 1, 10

local USAGE = [[
Usage: anvil machine <command>

  code full|view   Make a pairing code for a new device, with Full control or View access
  devices          List the paired devices
  revoke <device>  Remove a device and close its connections
]]

local function fail(message)
  io.stderr:write(message, "\n")
  os.exit(1)
end

local function read_discovery()
  local path = USERDIR .. PATHSEP .. "machine" .. PATHSEP .. "server.json"
  local file = io.open(path, "rb")
  if not file then fail("The Machine server is not running. Start it with: anvil serve <project>...") end
  local ok, found = pcall(json.decode, file:read("*a") or "")
  file:close()
  if not ok or type(found) ~= "table" or type(found.port) ~= "number" or type(found.token) ~= "string" then
    fail("The Machine server's discovery file is not valid: " .. path)
  end
  return found
end

local function connect(port)
  local address = net.resolve_address("127.0.0.1")
  if not address or address:wait_until_resolved(TIMEOUT * 1000) ~= "success" then
    fail("Cannot resolve the loopback address")
  end
  local socket = net.open_tcp(address, port)
  if not socket or socket:wait_until_connected(TIMEOUT * 1000) ~= "success" then
    fail("Cannot connect to the Machine server on port " .. port)
  end
  return {socket = socket, decoder = machine.decoder(), next_id = 1}
end

-- Sends one request and waits for its reply. Exits with the Machine's message on an error.
local function call(client, method, params)
  local id = client.next_id
  client.next_id = id + 1
  client.socket:write(machine.frame("request", id, json.encode({method = method, params = params})))
  local deadline = system.get_time() + TIMEOUT
  while system.get_time() < deadline do
    local kind, reply_id, body = client.decoder:next()
    if kind == "reply" and reply_id == id then
      local value = json.decode(body)
      if value.error then fail(value.error.message or value.error.code) end
      return value.result
    end
    local chunk = client.socket:read(65536)
    if not chunk then fail("The Machine server closed the connection") end
    if chunk == "" then system.sleep(0.01) else client.decoder:feed(chunk) end
  end
  fail("The Machine server did not answer " .. method)
end

function core.init()
  local name, argument = ARGS[3], ARGS[4]
  if name == "code" and (argument == "full" or argument == "view") then
    local found = read_discovery()
    local client = connect(found.port)
    call(client, "hello", {protocol = PROTOCOL, token = found.token})
    local result = call(client, "pairing.start", {level = argument})
    io.stdout:write(string.format("Pairing code: %s\nAccess: %s\nPort: %d\nThe code works one time, for %d minutes.\n",
      result.code, argument == "full" and "Full control" or "View", found.port, math.floor(result.expires_in / 60)))
  elseif name == "devices" then
    local found = read_discovery()
    local client = connect(found.port)
    call(client, "hello", {protocol = PROTOCOL, token = found.token})
    local devices = call(client, "devices.list", {}).devices
    if #devices == 0 then io.stdout:write("No paired devices.\n") end
    for _, device in ipairs(devices) do
      io.stdout:write(string.format("%s  %-4s  %s  %s\n", device.id, device.level,
        os.date("%Y-%m-%d", device.paired), device.name))
    end
  elseif name == "revoke" and argument then
    local found = read_discovery()
    local client = connect(found.port)
    call(client, "hello", {protocol = PROTOCOL, token = found.token})
    call(client, "devices.revoke", {device = argument})
    io.stdout:write("Revoked device " .. argument .. ".\n")
  else
    io.stdout:write(USAGE)
    os.exit(name and 1 or 0)
  end
  io.stdout:flush()
  os.exit(0)
end

function core.run() end

return core
