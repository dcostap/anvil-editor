-- A connection from this process to a Machine server. It never blocks the UI thread:
-- a scheduler thread connects, sends `hello` and reads the replies.
local core = require "core"
local json = require "core.json"
local machine = require "machine"
local net = require "net"

local PROTOCOL, CONNECT_TIMEOUT = 1, 10

---@class core.machine_client
local MachineClient = {}
MachineClient.__index = MachineClient

-- `discovery` is the path of the server's `server.json`.
function MachineClient.new(discovery)
  local self = setmetatable({discovery = discovery, state = "connecting", next_id = 1, pending = {}, held = {}},
    MachineClient)
  self.thread = core.add_thread(function() self:run() end)
  return self
end

local function read_discovery(path)
  local file = io.open(path, "rb")
  if not file then return nil, "The Machine server is not running" end
  local ok, found = pcall(json.decode, file:read("*a") or "")
  file:close()
  if not ok or type(found) ~= "table" or type(found.port) ~= "number" or type(found.token) ~= "string" then
    return nil, "The Machine server's discovery file is not valid"
  end
  return found
end

-- Sends one request. `on_reply(err, result, bytes)` runs once: with the result, or with an error
-- from the Machine (`err.code`) or from the connection (`disconnected`). A conflict also sends bytes.
function MachineClient:request(method, params, bytes, on_reply)
  if self.state == "closed" or self.state == "failed" then
    return on_reply({code = "disconnected", message = self.error or "The Machine connection is closed"})
  end
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = on_reply
  local frame = machine.frame("request", id, json.encode({method = method, params = params or {}}), bytes)
  if self.state == "ready" or method == "hello" then
    self.socket:write(frame)
  else
    self.held[#self.held + 1] = frame
  end
  if self.thread then core.wake_thread(self.thread) end
end

function MachineClient:fail(message)
  if self.state == "closed" then return end
  core.log_quiet("Machine connection failed: %s", message)
  self.state, self.error = "failed", message
  self:drop()
end

function MachineClient:close()
  self.state = "closed"
  self:drop()
end

function MachineClient:drop()
  if self.socket then self.socket:close() end
  self.socket, self.held = nil, {}
  local pending = self.pending
  self.pending = {}
  for _, on_reply in pairs(pending) do
    on_reply({code = "disconnected", message = self.error or "The Machine connection is closed"})
  end
end

function MachineClient:dispatch(id, body, bytes)
  local on_reply = self.pending[id]
  if not on_reply then return end
  self.pending[id] = nil
  local ok, value = pcall(json.decode, body)
  if not ok or type(value) ~= "table" then
    return on_reply({code = "invalid_reply", message = "The Machine sent an invalid reply"})
  end
  if value.error then return on_reply(value.error, nil, bytes) end
  on_reply(nil, value.result, bytes)
end

function MachineClient:connect()
  local found, err = read_discovery(self.discovery)
  if not found then return self:fail(err) end
  local address = net.resolve_address("127.0.0.1")
  local deadline = system.get_time() + CONNECT_TIMEOUT
  while address and address:get_status() == "waiting" and system.get_time() < deadline do coroutine.yield(0.01) end
  if not address or address:get_status() ~= "success" then return self:fail("Cannot resolve the loopback address") end
  local socket
  socket, err = net.open_tcp(address, found.port)
  if not socket then return self:fail(tostring(err)) end
  self.socket, self.decoder = socket, machine.decoder()
  local status
  repeat
    status, err = socket:get_status()
    if status == "waiting" then coroutine.yield(0.01) end
  until status ~= "waiting" or system.get_time() >= deadline or self.state == "closed"
  if self.state == "closed" then return end
  if status ~= "success" then return self:fail(err or "Cannot connect to the Machine server") end
  self:request("hello", {protocol = PROTOCOL, token = found.token}, nil, function(hello_err, hello)
    if hello_err then return self:fail(hello_err.message or hello_err.code) end
    self.state, self.machine, self.epoch, self.features = "ready", hello.machine, hello.epoch, hello.features
    core.log_quiet("Machine connection ready: machine=%s epoch=%s", tostring(hello.machine), tostring(hello.epoch))
    for _, frame in ipairs(self.held) do self.socket:write(frame) end
    self.held = {}
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
    else
      -- The transport polls its socket. Poll often only while a reply is due.
      coroutine.yield(next(self.pending) and 0.005 or 0.05)
    end
  end
end

function MachineClient:run()
  self:connect()
  self:receive()
  self.thread = nil
end

return MachineClient
