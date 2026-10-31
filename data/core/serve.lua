-- `anvil serve <project>...`: the Machine server. It runs Anvil's Lua without a window.
-- It listens on loopback only. Each Client sends `hello` with the token from the discovery file first.
local common = require "core.common"
local json = require "core.json"
local machine = require "machine"
local net = require "net"

local core = {}
local PROTOCOL, FEATURES = 1, {"files.read"}
local MAX_CLIENTS, MAX_REQUEST_JSON, MAX_READ, HELLO_TIMEOUT = 32, 64 * 1024, 16 * 1024 * 1024, 10
local server

-- A server often ends by a forced stop, and it logs little. So each record goes to disk at once.
local function log(...)
  if not core.session_log then return end
  core.session_log:write("INFO", string.format(...), "Machine")
  core.session_log:flush()
end

local function write_file(path, text)
  local temporary = path .. ".tmp" .. system.get_process_id()
  local file = assert(io.open(temporary, "wb"))
  file:write(text)
  file:close()
  assert(system.replace_file(temporary, path))
end

-- The Machine ID is random and stays in USERDIR, because a path or a PC name can change.
local function machine_id(directory)
  local path = directory .. PATHSEP .. "id"
  local file = io.open(path, "rb")
  local id = file and file:read("*a")
  if file then file:close() end
  if id and id:match("^%x+$") then return id end
  id = net.random_token():sub(1, 32)
  write_file(path, id)
  return id
end

local function open_listener(token)
  local address = assert(net.resolve_address("127.0.0.1"))
  assert(address:wait_until_resolved(5000) == "success", "Cannot resolve the loopback address")
  local listener, port, err
  for i = 1, 128 do
    -- Spread attempts across the range: Windows can exclude many adjacent ports.
    port = 49152 + (tonumber(token:sub(1, 4), 16) + i * 127) % 16384
    listener, err = net.create_server(address, port)
    if listener then return listener, port end
  end
  error("Cannot open the Machine server's listener: " .. tostring(err))
end

local function reply(client, id, value, bytes)
  client.socket:write(machine.frame("reply", id, json.encode(value), bytes))
end

local function fail(client, id, code, message, details)
  local err = {code = code, message = message}
  for key, value in pairs(details or {}) do err[key] = value end
  reply(client, id, {error = err})
end

local function read_file(client, id, params)
  local path = params.path
  if type(path) ~= "string" or not common.is_absolute_path(path) then
    return fail(client, id, "invalid_path", "The path must be absolute")
  end
  path = system.absolute_path(path) or path
  local inside = false
  for _, root in ipairs(server.projects) do
    inside = inside or common.path_equals(path, root) or common.path_belongs_to(path, root)
  end
  if not inside then return fail(client, id, "outside_project", "The path is not in a Project of this Machine") end
  local info = system.get_file_info(path)
  if not info then return fail(client, id, "not_found", "The file does not exist") end
  if info.type ~= "file" then return fail(client, id, "not_a_file", "The path is not a file") end
  if info.size > MAX_READ then return fail(client, id, "too_large", "The file is too large", {limit = MAX_READ}) end
  local file, err = io.open(path, "rb")
  if not file then return fail(client, id, "read_failed", tostring(err)) end
  local bytes = file:read("*a") or ""
  file:close()
  reply(client, id, {result = {size = #bytes, version = machine.content_version(bytes)}}, bytes)
end

local function handle(client, id, body)
  local ok, request = pcall(json.decode, body)
  local params = ok and type(request) == "table" and (request.params or {})
  if type(params) ~= "table" or type(request.method) ~= "string" then
    if not client.authorized then client.closing = true end
    return fail(client, id, "invalid_request", "The request needs a method and a params object")
  end
  if request.method == "hello" then
    -- The version comes first: a later protocol can send its credentials in another way.
    if params.protocol ~= PROTOCOL then
      client.closing = true
      return fail(client, id, "protocol", "This Machine uses another protocol version", {protocol = PROTOCOL})
    end
    if params.token ~= server.token then
      client.closing = true
      log("Machine server refused a Client: wrong token")
      return fail(client, id, "unauthorized", "The token is not valid")
    end
    client.authorized = true
    return reply(client, id, {result = {protocol = PROTOCOL, machine = server.machine, epoch = server.epoch,
      os = PLATFORM, features = FEATURES}})
  end
  if not client.authorized then
    client.closing = true
    return fail(client, id, "unauthorized", "Send hello first")
  end
  if request.method == "files.read" then return read_file(client, id, params) end
  fail(client, id, "unknown_method", "This Machine has no method " .. request.method)
end

local function poll_client(client)
  while not client.closing do
    local chunk = client.socket:read(65536)
    if not chunk then client.dead = true; return end
    if chunk == "" then break end
    client.decoder:feed(chunk)
    while not client.closing do
      local kind, id, body = client.decoder:next()
      if not kind then
        if id then client.dead = true end
        break
      end
      if kind ~= "request" then client.dead = true; break end
      handle(client, id, body)
    end
    if client.dead then return end
  end
end

local function poll()
  for _ = 1, 4 do
    if #server.clients >= MAX_CLIENTS then break end
    local socket = server.listener:accept()
    if not socket then break end
    server.clients[#server.clients + 1] = {socket = socket, decoder = machine.decoder(MAX_REQUEST_JSON, 0),
      deadline = system.get_time() + HELLO_TIMEOUT}
  end
  local now = system.get_time()
  for i = #server.clients, 1, -1 do
    local client = server.clients[i]
    if not client.dead then poll_client(client) end
    if client.dead or not client.authorized and now > client.deadline
        or client.closing and (client.socket:get_pending_writes() or 0) == 0 then
      client.socket:close()
      table.remove(server.clients, i)
    end
  end
end

function core.init()
  common.mkdirp(USERDIR)
  core.session_log = require("core.session_log").start(USERDIR .. PATHSEP .. "logs")
  local projects = {}
  for i = 3, #ARGS do
    local path = system.absolute_path(ARGS[i])
    local info = path and system.get_file_info(path)
    if not info or info.type ~= "dir" then
      io.stderr:write("Not a folder: " .. ARGS[i] .. "\n")
      os.exit(1)
    end
    projects[#projects + 1] = path
  end
  local directory = USERDIR .. PATHSEP .. "machine"
  net.private_directory(directory)
  local token = net.random_token()
  local listener, port = open_listener(token)
  server = {listener = listener, port = port, token = token, projects = projects, clients = {},
    machine = machine_id(directory), epoch = net.random_token():sub(1, 16),
    discovery = directory .. PATHSEP .. "server.json"}
  write_file(server.discovery, json.encode {version = 1, port = port, token = token,
    pid = system.get_process_id(), machine = server.machine, epoch = server.epoch})
  log("Machine server started: port=%d machine=%s epoch=%s projects=%d", port, server.machine, server.epoch, #projects)
  io.stdout:write("Anvil Machine server on 127.0.0.1:" .. port .. "\n")
  io.stdout:flush()
end

function core.run() end

local function shutdown()
  for _, client in ipairs(server.clients) do client.socket:close() end
  server.listener:close()
  -- Another server can have replaced the discovery file. Remove only this server's file.
  local file = io.open(server.discovery, "rb")
  local found = file and json.decode(file:read("*a") or "")
  if file then file:close() end
  if type(found) == "table" and found.pid == system.get_process_id() then os.remove(server.discovery) end
  log("Machine server stopped")
  if core.session_log then core.session_log:close() end
end

function core.run_step()
  while true do
    local name = system.poll_event()
    if not name then break end
    if name == "quit" then shutdown(); return false end
  end
  poll()
  -- The transport polls its sockets. Poll often only while a Client is connected.
  system.wait_event(#server.clients > 0 and 0.005 or 0.05)
  return true
end

function core.on_error(err)
  log("Machine server error: %s", tostring(err))
end

return core
