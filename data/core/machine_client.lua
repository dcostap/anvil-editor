-- A connection from this process to a Machine server. It never blocks the UI thread:
-- a scheduler thread connects, sends `hello` and reads the replies.
-- After a disconnect it connects again. It reads its Machine file each time, because a
-- restarted local server has a new port and token.
local core = require "core"
local json = require "core.json"
local machine = require "machine"
local net = require "net"

local PROTOCOL, CONNECT_TIMEOUT, MAX_RETRY_DELAY = 1, 10, 5

---@class core.machine_client
local MachineClient = {}
MachineClient.__index = MachineClient

-- `path` is a Machine file: the local server's `server.json`, or the record of a paired Machine.
-- `on_connect(reconnect)` runs after each `hello`.
function MachineClient.new(path, on_connect)
  local self = setmetatable({path = path, on_connect = on_connect, state = "connecting", next_id = 1,
    connections = 0, pending = {}, held = {}}, MachineClient)
  self.thread = core.add_thread(function() self:run() end)
  return self
end

local function to_hex(bytes)
  return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function from_hex(text)
  return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

-- Returns the host, the port and the `hello` credentials of a Machine file.
local function read_machine_file(path)
  local file = io.open(path, "rb")
  if not file then return nil, "The Machine server is not running" end
  local ok, found = pcall(json.decode, file:read("*a") or "")
  file:close()
  if not ok or type(found) ~= "table" or type(found.port) ~= "number" then
    return nil, "The Machine file is not valid"
  end
  if type(found.host) == "string" and type(found.device) == "string" and type(found.protected_token) == "string" then
    local token, err = machine.unprotect(from_hex(found.protected_token))
    if not token then return nil, "Cannot read the Machine's token: " .. err end
    return {host = found.host, port = found.port, hello = {device = found.device, token = token}}
  end
  if type(found.token) ~= "string" then return nil, "The Machine file is not valid" end
  return {host = "127.0.0.1", port = found.port, hello = {token = found.token}}
end

-- Connects without blocking the UI thread. Returns the socket, or nil and an error.
local function open_socket(host, port, deadline, stopped)
  local address = net.resolve_address(host)
  while address and address:get_status() == "waiting" and system.get_time() < deadline do coroutine.yield(0.01) end
  if not address or address:get_status() ~= "success" then return nil, "Cannot resolve " .. host end
  local socket, err = net.open_tcp(address, port)
  if not socket then return nil, tostring(err) end
  local status
  repeat
    status, err = socket:get_status()
    if status == "waiting" then coroutine.yield(0.01) end
  until status ~= "waiting" or system.get_time() >= deadline or stopped()
  if status ~= "success" then
    socket:close()
    return nil, err or "Cannot connect to the Machine"
  end
  return socket
end

local function write_file(path, text)
  local temporary = path .. ".tmp" .. system.get_process_id()
  local file, err = io.open(temporary, "wb")
  if not file then return nil, err end
  file:write(text)
  file:close()
  return system.replace_file(temporary, path)
end

-- Pairs with the Machine at `host` and `port` through a pairing code. Saves the Machine's record in
-- `USERDIR/machines` with its token protected for this user, then calls `on_done(err, path)`.
-- A failure does not try again, because each wrong code counts as an attempt.
function MachineClient.pair(host, port, code, name, on_done)
  core.add_thread(function()
    local function done(...) core.try(on_done, ...) end
    local deadline = system.get_time() + CONNECT_TIMEOUT
    local socket, err = open_socket(host, port, deadline, function() return false end)
    if not socket then return done({code = "offline", message = err}) end
    local decoder, reply = machine.decoder()
    socket:write(machine.frame("request", 1, json.encode({method = "hello",
      params = {protocol = PROTOCOL, pair = code, name = name}})))
    while not reply and system.get_time() < deadline do
      local chunk = socket:read(65536)
      if not chunk then break end
      if chunk == "" then
        coroutine.yield(0.01)
      else
        decoder:feed(chunk)
        local kind, _, body = decoder:next()
        if kind == "reply" then reply = body end
      end
    end
    socket:close()
    local ok, value = pcall(json.decode, reply or "")
    if not ok or type(value) ~= "table" then
      return done({code = "disconnected", message = "The Machine did not answer the pairing"})
    end
    if value.error then return done(value.error) end
    local hello = value.result
    -- The Machine ID names the record's file, so it must be a plain ID.
    if type(hello) ~= "table" or type(hello.device) ~= "table" or type(hello.machine) ~= "string"
        or not hello.machine:match("^%x+$") then
      return done({code = "invalid_reply", message = "The Machine sent an invalid pairing reply"})
    end
    local protected, protect_err = machine.protect(hello.device.token)
    if not protected then return done({code = "protect_failed", message = protect_err}) end
    local directory = USERDIR .. PATHSEP .. "machines"
    net.private_directory(directory)
    local path = directory .. PATHSEP .. hello.machine .. ".json"
    ok, err = write_file(path, json.encode {version = 1, machine = hello.machine, host = host, port = port,
      device = hello.device.id, level = hello.level, protected_token = to_hex(protected)})
    if not ok then return done({code = "write_failed", message = tostring(err)}) end
    core.log_quiet("Paired with Machine %s for %s access", hello.machine, tostring(hello.level))
    done(nil, path)
  end)
end

-- Sends one request. `on_reply(err, result, bytes)` runs once: with the result, or with an error
-- from the Machine (`err.code`). A conflict also sends bytes. Two errors come from the connection:
-- `offline` when the request was not sent, and `disconnected` when its reply did not arrive.
function MachineClient:request(method, params, bytes, on_reply)
  if self.state == "closed" or self.state == "waiting" then
    return core.try(on_reply, {code = "offline", message = self.error or "The Machine is not connected"})
  end
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = on_reply
  local frame = machine.frame("request", id, json.encode({method = method, params = params or {}}), bytes)
  if self.state == "ready" or method == "hello" then
    self.socket:write(frame)
  else
    self.held[#self.held + 1] = {id = id, frame = frame}
  end
  if self.thread then core.wake_thread(self.thread) end
end

function MachineClient:fail(message)
  if self.state == "closed" then return end
  core.log_quiet("Machine connection failed: %s", message)
  self.state, self.error = "waiting", message
  self:drop()
end

function MachineClient:close()
  self.state = "closed"
  self:drop()
end

function MachineClient:drop()
  if self.socket then self.socket:close() end
  local pending, held = self.pending, self.held
  self.socket, self.pending, self.held = nil, {}, {}
  local message = self.error or "The Machine connection is closed"
  for _, request in ipairs(held) do
    local on_reply = pending[request.id]
    pending[request.id] = nil
    core.try(on_reply, {code = "offline", message = message})
  end
  for _, on_reply in pairs(pending) do core.try(on_reply, {code = "disconnected", message = message}) end
end

function MachineClient:dispatch(id, body, bytes)
  local on_reply = self.pending[id]
  if not on_reply then return end
  self.pending[id] = nil
  local ok, value = pcall(json.decode, body)
  if not ok or type(value) ~= "table" then
    return core.try(on_reply, {code = "invalid_reply", message = "The Machine sent an invalid reply"})
  end
  -- An error in a callback must not end the connection's thread.
  if value.error then return core.try(on_reply, value.error, nil, bytes) end
  core.try(on_reply, nil, value.result, bytes)
end

function MachineClient:connect()
  local found, err = read_machine_file(self.path)
  if not found then return self:fail(err) end
  local socket
  -- One deadline covers the connect and the `hello` reply. A forwarder can accept a connection
  -- that no server answers.
  self.hello_deadline = system.get_time() + CONNECT_TIMEOUT
  socket, err = open_socket(found.host, found.port, self.hello_deadline,
    function() return self.state == "closed" end)
  if self.state == "closed" then
    if socket then socket:close() end
    return
  end
  if not socket then return self:fail(err) end
  self.socket, self.decoder = socket, machine.decoder()
  found.hello.protocol = PROTOCOL
  self:request("hello", found.hello, nil, function(hello_err, hello)
    if hello_err then return self:fail(hello_err.message or hello_err.code) end
    self.state, self.machine, self.epoch, self.features = "ready", hello.machine, hello.epoch, hello.features
    self.level = hello.level
    core.log_quiet("Machine connection ready: machine=%s epoch=%s", tostring(hello.machine), tostring(hello.epoch))
    for _, request in ipairs(self.held) do self.socket:write(request.frame) end
    self.held = {}
    self.connections = self.connections + 1
    if self.on_connect then core.try(self.on_connect, self.connections > 1) end
  end)
end

function MachineClient:receive()
  while self.socket do
    local chunk, err = self.socket:read(65536)
    if not chunk then return self:fail(err or "The Machine server closed the connection") end
    if chunk ~= "" then
      self.decoder:feed(chunk)
      while self.socket do
        local kind, id, body, bytes = self.decoder:next()
        if not kind then
          if id then return self:fail("The Machine sent an invalid frame") end
          break
        end
        if kind == "reply" then self:dispatch(id, body, bytes) end
      end
    elseif self.state == "connecting" and system.get_time() >= self.hello_deadline then
      return self:fail("The Machine did not answer")
    else
      -- The transport polls its socket. Poll often only while a reply is due.
      coroutine.yield(next(self.pending) and 0.005 or 0.05)
    end
  end
end

function MachineClient:run()
  local delay = 0.1
  while self.state ~= "closed" do
    self.state = "connecting"
    local connections = self.connections
    self:connect()
    self:receive()
    if self.state == "closed" then break end
    if self.connections > connections then delay = 0.1 end
    coroutine.yield(delay)
    delay = math.min(delay * 2, MAX_RETRY_DELAY)
  end
  self.thread = nil
end

return MachineClient
