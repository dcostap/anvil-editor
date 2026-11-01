-- `anvil serve [<project>...]`: the Machine server. It runs Anvil's Lua without a window.
-- Without Projects, it serves the Projects of this user folder's Sidebar. One server runs for each user folder.
-- It listens on loopback only. Each Client sends `hello` first: the local owner with the token from the
-- discovery file, a paired device with its own token, and a new device with a pairing code.
local common = require "core.common"
local json = require "core.json"
local machine = require "machine"
local net = require "net"

local core = {}
local PROTOCOL = 1
local FEATURES = {"projects.list", "files.read", "files.write", "files.save_result", "pairing.start", "devices.list", "devices.revoke"}
local MAX_CLIENTS, MAX_REQUEST_JSON, MAX_FILE, HELLO_TIMEOUT = 32, 64 * 1024, 16 * 1024 * 1024, 10
local MAX_SAVES, PAIRING_TIME, PAIRING_ATTEMPTS, MAX_NAME = 1024, 300, 5, 100
-- A View device only reads. These methods need Full control.
local FULL_CONTROL = {["files.write"] = true, ["pairing.start"] = true, ["devices.list"] = true, ["devices.revoke"] = true}
-- Tailscale Serve and other forwarders need a port that stays the same across restarts.
local DEFAULT_PORT, OWNER_CHECK_SECONDS = 7690, 1
local server, test_root, lose_reply, fixed_port, owner, waiting

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

-- Paired devices stay in USERDIR. The file keeps the hash of each device's token, not the token.
local function load_devices(path)
  local file = io.open(path, "rb")
  if not file then return {} end
  local ok, found = pcall(json.decode, file:read("*a") or "")
  file:close()
  return ok and type(found) == "table" and type(found.devices) == "table" and found.devices or {}
end

local function save_devices()
  write_file(server.devices_path, json.encode {version = 1, devices = server.devices})
end

local function find_device(id)
  for i, device in ipairs(server.devices) do
    if device.id == id then return device, i end
  end
end

-- A pairing code works one time, for PAIRING_TIME seconds, with PAIRING_ATTEMPTS wrong attempts.
-- Returns the new device and its token, or nil and an error code.
local function pair_device(params)
  local pairing = server.pairing
  if not pairing or system.get_time() > pairing.expires then
    server.pairing = nil
    return nil, "pairing_ended"
  end
  if params.pair ~= pairing.code then
    pairing.attempts = pairing.attempts + 1
    if pairing.attempts >= PAIRING_ATTEMPTS then server.pairing = nil end
    log("Machine server refused a pairing code: attempt %d", pairing.attempts)
    return nil, "unauthorized"
  end
  server.pairing = nil
  local token = net.random_token()
  local device = {id = net.random_token():sub(1, 16), level = pairing.level, paired = os.time(),
    name = type(params.name) == "string" and params.name ~= "" and params.name:sub(1, MAX_NAME) or "Device",
    token = machine.content_version(token)}
  server.devices[#server.devices + 1] = device
  save_devices()
  log("Machine server paired device %s with %s access", device.id, device.level)
  return device, token
end

-- Returns the access level, the device and a new device's token. Returns nil and an error code
-- when the credentials are not valid.
local function log_in(params)
  if params.pair ~= nil then
    local device, token = pair_device(params)
    if not device then return nil, token end
    return device.level, device, token
  elseif params.device ~= nil then
    local device = find_device(params.device)
    if device and type(params.token) == "string" and machine.content_version(params.token) == device.token then
      return device.level, device
    end
  elseif params.token == server.token then
    return "full"
  end
end

local function open_listener(token)
  local address = assert(net.resolve_address("127.0.0.1"))
  assert(address:wait_until_resolved(5000) == "success", "Cannot resolve the loopback address")
  if fixed_port and fixed_port ~= 0 then
    local listener, err = net.create_server(address, fixed_port)
    if not listener then error("Cannot listen on port " .. fixed_port .. ": " .. tostring(err)) end
    return listener, fixed_port
  end
  local listener, port, err
  if not fixed_port then
    listener, err = net.create_server(address, DEFAULT_PORT)
    if listener then return listener, DEFAULT_PORT end
    log("Machine server cannot use port %d, so it uses another port: %s", DEFAULT_PORT, tostring(err))
  end
  for i = 1, 128 do
    -- Spread attempts across the range: Windows can exclude many adjacent ports.
    port = 49152 + (tonumber(token:sub(1, 4), 16) + i * 127) % 16384
    listener, err = net.create_server(address, port)
    if listener then return listener, port end
  end
  error("Cannot open the Machine server's listener: " .. tostring(err))
end

local function reply(client, id, value, bytes)
  -- `--test-lose-reply <method>` does the first such request, then closes the connection without its reply.
  if lose_reply and lose_reply == client.method then
    lose_reply, client.dead = nil, true
    log("Machine server lost the reply to %s for a test", client.method)
    return
  end
  client.socket:write(machine.frame("reply", id, json.encode(value), bytes))
end

local function fail(client, id, code, message, details, bytes)
  local err = {code = code, message = message}
  for key, value in pairs(details or {}) do err[key] = value end
  reply(client, id, {error = err}, bytes)
end

-- `--test-root <folder>` keeps the files under a private folder: Machine path C:\a\b is <folder>\C\a\b.
-- Only tests use it, so one PC can hold a Client copy and a different Machine copy at the same path.
local function disk_path(path)
  if not test_root then return path end
  return test_root .. PATHSEP .. path:gsub("^(%a):", "%1"):gsub("^[/\\]+", "")
end

-- The Sidebar lists the recent Projects of the user folder's app state, and Scratch first.
-- The server reads the list again when the app state file changes.
local function sidebar_projects()
  local state_path = USERDIR .. PATHSEP .. "appstate.lua"
  local info = system.get_file_info(state_path)
  local stamp = info and info.modified .. ":" .. info.size or false
  if server.sidebar and server.sidebar_stamp == stamp then return server.sidebar end
  local recents = {}
  local chunk = info and loadfile(state_path, "t", {})
  local ok, state = pcall(chunk or function() end)
  if ok and type(state) == "table" and type(state.recents) == "table" then recents = state.recents end
  local projects, seen = {}, {}
  local function add(path, scratch)
    path = type(path) == "string" and common.is_absolute_path(path) and common.normalize_volume(path)
    local key = path and common.path_compare_key(path)
    local found = path and system.get_file_info(disk_path(path))
    if key and not seen[key] and found and found.type == "dir" then
      seen[key] = true
      projects[#projects + 1] = {path = path, scratch = scratch or nil}
    end
  end
  add(USERDIR .. PATHSEP .. "scratch", true)
  for _, path in ipairs(recents) do add(path) end
  server.sidebar, server.sidebar_stamp = projects, stamp
  log("Machine server read the Sidebar list: %d Projects", #projects)
  return projects
end

local function projects()
  return server.projects or sidebar_projects()
end

-- Returns the absolute Machine path of a request, or nothing after it sends the error.
local function request_path(client, id, params)
  local path = params.path
  if type(path) ~= "string" or not common.is_absolute_path(path) then
    return fail(client, id, "invalid_path", "The path must be absolute")
  end
  path = system.absolute_path(path) or path
  for _, project in ipairs(projects()) do
    local root = project.path
    if common.path_equals(path, root) or common.path_belongs_to(path, root) then return path end
  end
  fail(client, id, "outside_project", "The path is not in a Project of this Machine")
end

-- Returns the file's bytes, or nil, an error code and a message.
local function load_file(path)
  local info = system.get_file_info(path)
  if not info then return nil, "not_found", "The file does not exist" end
  if info.type ~= "file" then return nil, "not_a_file", "The path is not a file" end
  if info.size > MAX_FILE then return nil, "too_large", "The file is too large" end
  local file, err = io.open(path, "rb")
  if not file then return nil, "read_failed", tostring(err) end
  local bytes = file:read("*a") or ""
  file:close()
  return bytes
end

local function read_file(client, id, params)
  local path = request_path(client, id, params)
  if not path then return end
  local bytes, code, message = load_file(disk_path(path))
  if not bytes then return fail(client, id, code, message, code == "too_large" and {limit = MAX_FILE} or nil) end
  reply(client, id, {result = {size = #bytes, version = machine.content_version(bytes)}}, bytes)
end

-- The server keeps the result of each recent save ID, so a Client that lost a reply can ask for it.
local function remember_save(save, version)
  if server.saves[save] == nil then
    server.save_order[#server.save_order + 1] = save
    if #server.save_order > MAX_SAVES then server.saves[table.remove(server.save_order, 1)] = nil end
  end
  server.saves[save] = version
end

-- `files.write {path, base, save}` replaces the whole file, but only while it has the version `base`.
-- Without `base`, it only creates a file. A conflict sends the current version and bytes.
local function write_file_request(client, id, params, bytes)
  local path = request_path(client, id, params)
  if not path then return end
  if params.base ~= nil and type(params.base) ~= "string" or params.save ~= nil and type(params.save) ~= "string" then
    return fail(client, id, "invalid_request", "The base and the save ID must be strings")
  end
  local disk = disk_path(path)
  local current, code, message = load_file(disk)
  if not current and code ~= "not_found" then return fail(client, id, code, message) end
  local version = current and machine.content_version(current)
  if version ~= params.base then
    log("Machine server refused a write: the file changed")
    return fail(client, id, "conflict", "The file changed on the Machine", {version = version}, current)
  end
  common.mkdirp(common.dirname(disk))
  local temporary = disk .. ".anvil-tmp" .. system.get_process_id()
  local file, err = io.open(temporary, "wb")
  local ok = file and file:write(bytes) and system.sync_file(file)
  if file then file:close() end
  if ok then ok, err = system.replace_file(temporary, disk) end
  if not ok then
    os.remove(temporary)
    return fail(client, id, "write_failed", tostring(err or "The file was not written"))
  end
  local written = machine.content_version(bytes)
  if params.save then remember_save(params.save, written) end
  reply(client, id, {result = {version = written}})
end

-- `files.save_result {save}` gives the version that a save wrote. A restarted server knows no saves.
local function save_result(client, id, params)
  local version = type(params.save) == "string" and server.saves[params.save]
  if not version then return fail(client, id, "unknown_save", "This Machine has no result for the save") end
  reply(client, id, {result = {version = version}})
end

-- `pairing.start {level}` makes a new pairing code. It replaces an earlier code.
local function start_pairing(client, id, params)
  if params.level ~= "view" and params.level ~= "full" then
    return fail(client, id, "invalid_request", "The level must be view or full")
  end
  local code = string.format("%06d", tonumber(net.random_token():sub(1, 8), 16) % 1000000)
  server.pairing = {code = code, level = params.level, attempts = 0, expires = system.get_time() + PAIRING_TIME}
  log("Machine server started pairing for %s access", params.level)
  reply(client, id, {result = {code = code, expires_in = PAIRING_TIME}})
end

local function list_projects(client, id)
  reply(client, id, {result = {projects = projects()}})
end

local function list_devices(client, id)
  local devices = {}
  for _, device in ipairs(server.devices) do
    devices[#devices + 1] = {id = device.id, name = device.name, level = device.level, paired = device.paired}
  end
  reply(client, id, {result = {devices = devices}})
end

-- `devices.revoke {device}` removes the device and closes its connections at once.
local function revoke_device(client, id, params)
  local _, index = find_device(params.device)
  if not index then return fail(client, id, "unknown_device", "This Machine has no such device") end
  table.remove(server.devices, index)
  save_devices()
  for _, other in ipairs(server.clients) do
    if other.device == params.device and other ~= client then other.dead = true end
  end
  if client.device == params.device then client.closing = true end
  log("Machine server revoked device %s", params.device)
  reply(client, id, {result = true})
end

local function handle(client, id, body, bytes)
  local ok, request = pcall(json.decode, body)
  local params = ok and type(request) == "table" and (request.params or {})
  client.method = type(params) == "table" and request.method or nil
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
    local level, device, token = log_in(params)
    if not level then
      client.closing = true
      if device == "pairing_ended" then
        log("Machine server refused a pairing code: no code is active")
        return fail(client, id, "pairing_ended",
          "The pairing code has ended. Make a new code on the Machine with: anvil machine code full")
      end
      log("Machine server refused a Client: credentials not valid")
      return fail(client, id, "unauthorized", "The credentials are not valid")
    end
    client.authorized, client.level, client.device = true, level, device and device.id
    client.decoder:limits(MAX_REQUEST_JSON, MAX_FILE)
    return reply(client, id, {result = {protocol = PROTOCOL, machine = server.machine, epoch = server.epoch,
      os = PLATFORM, features = FEATURES, level = level, device = token and {id = device.id, token = token}}})
  end
  if not client.authorized then
    client.closing = true
    return fail(client, id, "unauthorized", "Send hello first")
  end
  if FULL_CONTROL[request.method] and client.level ~= "full" then
    return fail(client, id, "forbidden", "This device has View access")
  end
  if request.method == "projects.list" then return list_projects(client, id) end
  if request.method == "files.read" then return read_file(client, id, params) end
  if request.method == "files.write" then return write_file_request(client, id, params, bytes) end
  if request.method == "files.save_result" then return save_result(client, id, params) end
  if request.method == "pairing.start" then return start_pairing(client, id, params) end
  if request.method == "devices.list" then return list_devices(client, id) end
  if request.method == "devices.revoke" then return revoke_device(client, id, params) end
  fail(client, id, "unknown_method", "This Machine has no method " .. request.method)
end

local function poll_client(client)
  while not client.closing do
    local chunk = client.socket:read(65536)
    if not chunk then client.dead = true; return end
    if chunk == "" then break end
    client.decoder:feed(chunk)
    while not client.closing and not client.dead do
      local kind, id, body, bytes = client.decoder:next()
      if not kind then
        if id then client.dead = true end
        break
      end
      if kind ~= "request" then client.dead = true; break end
      handle(client, id, body, bytes)
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

local function start(listed)
  local directory = USERDIR .. PATHSEP .. "machine"
  local token = net.random_token()
  local listener, port = open_listener(token)
  server = {listener = listener, port = port, token = token, projects = listed, clients = {},
    saves = {}, save_order = {}, devices_path = directory .. PATHSEP .. "devices.json",
    machine = machine_id(directory), epoch = net.random_token():sub(1, 16),
    discovery = directory .. PATHSEP .. "server.json", owner_check = system.get_time()}
  server.devices = load_devices(server.devices_path)
  write_file(server.discovery, json.encode {version = 1, port = port, token = token,
    pid = system.get_process_id(), machine = server.machine, epoch = server.epoch})
  log("Machine server started: port=%d machine=%s epoch=%s projects=%s owner=%s", port, server.machine,
    server.epoch, listed and #listed or "Sidebar", tostring(owner))
  io.stdout:write("Anvil Machine server on 127.0.0.1:" .. port .. "\n")
  io.stdout:flush()
end

function core.init()
  common.mkdirp(USERDIR)
  core.session_log = require("core.session_log").start(USERDIR .. PATHSEP .. "logs")
  local first = 3
  while true do
    if ARGS[first] == "--test-root" then
      test_root = system.absolute_path(ARGS[first + 1] or ".")
    elseif ARGS[first] == "--test-lose-reply" then
      lose_reply = ARGS[first + 1]
    elseif ARGS[first] == "--port" or ARGS[first] == "--owner" then
      local value = tonumber(ARGS[first + 1])
      if not value then
        io.stderr:write(ARGS[first] .. " needs a number\n")
        os.exit(1)
      end
      -- `--port 0` takes any free port. `--owner <pid>` ends the server with that process.
      if ARGS[first] == "--port" then fixed_port = value else owner = value end
    else
      break
    end
    first = first + 2
  end
  local listed
  for i = first, #ARGS do
    local path = system.absolute_path(ARGS[i])
    local info = path and system.get_file_info(disk_path(path))
    if not info or info.type ~= "dir" then
      io.stderr:write("Not a folder: " .. ARGS[i] .. "\n")
      os.exit(1)
    end
    listed = listed or {}
    listed[#listed + 1] = {path = path}
  end
  local directory = USERDIR .. PATHSEP .. "machine"
  net.private_directory(directory)
  if machine.claim(directory .. PATHSEP .. "server.lock") then return start(listed) end
  if not owner then
    io.stderr:write("A Machine server already runs for this user folder\n")
    os.exit(1)
  end
  -- Anvil starts a server with `--owner`. It waits while another server runs, such as an older Anvil's
  -- server during an update, and takes over when that server ends.
  log("Machine server waits: another server runs for this user folder")
  waiting = {listed = listed, lock = directory .. PATHSEP .. "server.lock"}
end

function core.run() end

local function shutdown()
  if not server then return end
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
  if owner and (not server or system.get_time() >= server.owner_check) then
    if not machine.process_alive(owner) then
      log("Machine server ends: its Anvil ended")
      shutdown()
      return false
    end
    if server then server.owner_check = system.get_time() + OWNER_CHECK_SECONDS end
  end
  if waiting then
    if machine.claim(waiting.lock) then
      local listed = waiting.listed
      waiting = nil
      start(listed)
    else
      system.wait_event(OWNER_CHECK_SECONDS)
      return true
    end
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
