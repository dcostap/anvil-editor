local core = require "core"
local lsp_json = require "core.lsp.json"
local jsonrpc = require "core.lsp.jsonrpc"
local lsp_transport = require "core.lsp.transport"

local client = {}
local client_mt = {}
client_mt.__index = client_mt

local function quiet_log(...)
  if core and core.log_quiet then
    core.log_quiet(...)
  end
end

local function truncate_text(value, limit)
  value = tostring(value or "")
  limit = limit or 1000
  if #value > limit then
    return value:sub(1, limit) .. "..."
  end
  return value
end

local function normalize_encoding(value)
  value = tostring(value or "utf-16"):lower():gsub("_", "-")
  if value == "utf8" then value = "utf-8" end
  if value == "utf16" then value = "utf-16" end
  return value
end

local function negotiate_position_encoding(result)
  local capabilities = type(result) == "table" and result.capabilities or nil
  if type(capabilities) == "table" then
    local encoding = capabilities.positionEncoding
    if type(encoding) == "string" then
      encoding = normalize_encoding(encoding)
      if encoding == "utf-8" or encoding == "utf-16" then
        return encoding
      end
    end

    local offset_encoding = capabilities.offsetEncoding
    if type(offset_encoding) == "string" then
      offset_encoding = normalize_encoding(offset_encoding)
      if offset_encoding == "utf-8" or offset_encoding == "utf-16" then
        return offset_encoding
      end
    elseif type(offset_encoding) == "table" then
      for _, item in ipairs(offset_encoding) do
        item = normalize_encoding(item)
        if item == "utf-16" then return "utf-16" end
      end
      for _, item in ipairs(offset_encoding) do
        item = normalize_encoding(item)
        if item == "utf-8" then return "utf-8" end
      end
    end
  end
  return "utf-16"
end

local function install_default_handlers(self)
  self:on_request("workspace/applyEdit", function()
    return {
      applied = false,
      failureReason = "Anvil LSP workspace/applyEdit is not implemented",
    }
  end)
  self:on_request("workspace/configuration", function()
    return lsp_json.array({})
  end)
  self:on_request("client/registerCapability", function()
    return lsp_json.null
  end)
  self:on_request("client/unregisterCapability", function()
    return lsp_json.null
  end)
  self:on_request("window/workDoneProgress/create", function()
    return lsp_json.null
  end)

  self:on_notification("window/logMessage", function(params)
    self:_quiet_server_log("window/logMessage", params)
  end)
  self:on_notification("window/showMessage", function(params)
    self:_quiet_server_log("window/showMessage", params)
  end)
  self:on_notification("$/progress", function(params)
    self:_quiet_server_log("$/progress", params)
  end)
end

function client.new(driver, options)
  options = options or {}
  local wrapped = driver
  if type(driver) == "table" and not driver.driver then
    wrapped = lsp_transport.wrap(driver)
  end
  local generation = options.generation or 1
  local self = setmetatable({
    transport = wrapped,
    parser = jsonrpc.new_parser(options.parser),
    incoming = lsp_transport.new_incoming_queue(options.incoming_queue),
    requests = jsonrpc.new_request_tracker({ generation = generation }),
    request_handlers = {},
    notification_handlers = {},
    generation = generation,
    state = "new",
    failed = false,
    exited = false,
    error = nil,
    capabilities = nil,
    server_info = nil,
    position_encoding = "utf-16",
    initialize_result = nil,
    initialize_id = nil,
    shutdown_id = nil,
    log_count = 0,
    max_log_messages = options.max_log_messages or 50,
    max_log_message_bytes = options.max_log_message_bytes or 1000,
  }, client_mt)
  install_default_handlers(self)
  return self
end

function client_mt:on_request(method, handler)
  self.request_handlers[method] = handler
end

function client_mt:on_notification(method, handler)
  self.notification_handlers[method] = handler
end

function client_mt:_set_state(state)
  if self.state ~= state then
    quiet_log("LSP client state %s -> %s", tostring(self.state), state)
  end
  self.state = state
end

local function clear_diagnostics_for_client(self)
  local ok, lsp_diagnostics = pcall(require, "core.lsp.diagnostics")
  if ok and lsp_diagnostics and lsp_diagnostics.clear_client then
    lsp_diagnostics.clear_client(self)
  end
end

function client_mt:_fail(err)
  self.failed = true
  self.error = err
  self:_set_state("failed")
  if self.requests and self.requests.fail_all then
    self.requests:fail_all(jsonrpc.ERROR_INTERNAL_ERROR, tostring(err or "client failed"))
  end
  clear_diagnostics_for_client(self)
  self.incoming:close(err)
  return nil, err
end

function client_mt:_quiet_server_log(kind, params)
  self.log_count = self.log_count + 1
  if self.log_count > self.max_log_messages then return end
  local message = type(params) == "table" and (params.message or params.token or params.value) or params
  quiet_log("LSP server %s: %s", kind, truncate_text(message, self.max_log_message_bytes))
end

function client_mt:send_raw(message)
  if self.failed then return nil, self.error or "client failed" end
  return self.transport:write(jsonrpc.encode(message))
end

function client_mt:send_request(method, params, callback, options)
  local id = self.requests:register(method, callback, options)
  local ok, err = self:send_raw(jsonrpc.request(id, method, params))
  if not ok then
    self.requests:take(id)
    return nil, err
  end
  return id
end

function client_mt:send_notification(method, params)
  return self:send_raw(jsonrpc.notification(method, params))
end

function client_mt:send_response(id, result, error_obj)
  return self:send_raw(jsonrpc.response(id, result, error_obj))
end

function client_mt:send_error_response(id, code, message, data)
  return self:send_raw(jsonrpc.error_response(id, code, message, data))
end

function client_mt:read_once(max_bytes)
  if self.failed then return nil, self.error or "client failed" end
  local chunk, err = self.transport:read(max_bytes or 8192)
  if not chunk then
    return nil, err
  end
  if chunk == "" then
    return 0
  end
  local messages, parse_err = self.parser:feed(chunk)
  if not messages then
    return self:_fail(parse_err)
  end
  for _, message in ipairs(messages) do
    local ok, queue_err = self.incoming:push(message)
    if ok == nil then
      return self:_fail(queue_err)
    end
  end
  return #messages
end

function client_mt:process_next()
  if self.failed then return nil, self.error or "client failed" end
  local message = self.incoming:pop()
  if not message then return nil end

  if message.kind == "response" then
    return self.requests:dispatch_response(message, self.generation)
  elseif message.kind == "notification" then
    local handler = self.notification_handlers[message.method]
    if handler then
      handler(message.params, message)
      return true, message
    end
    quiet_log("LSP ignored notification %s", tostring(message.method))
    return false, "unhandled notification"
  elseif message.kind == "request" then
    local handler = self.request_handlers[message.method]
    if not handler then
      self:send_error_response(message.id, jsonrpc.ERROR_METHOD_NOT_FOUND,
        "Method not found: " .. tostring(message.method))
      return false, "unhandled request"
    end

    local ok, result, error_obj = pcall(handler, message.params, message)
    if not ok then
      self:send_error_response(message.id, jsonrpc.ERROR_INTERNAL_ERROR, tostring(result))
      return false, result
    end
    self:send_response(message.id, result, error_obj)
    return true, message
  end

  return false, "unknown message kind"
end

function client_mt:process_all(limit)
  local count = 0
  limit = limit or 1000
  while count < limit do
    local ok, err = self:process_next()
    if ok == nil then
      return count
    end
    if ok == false and err and self.failed then
      return nil, err
    end
    count = count + 1
  end
  return count
end

function client_mt:pending_count()
  return self.requests:pending_count()
end

function client_mt:_drain_stderr()
  if self.transport and self.transport.drain_stderr then
    self.transport:drain_stderr(8192, 16)
  end
end

function client_mt:_check_process_exit()
  if not self.transport or not self.transport.running then return false end
  if self.transport:running() then return false end
  self.exit_code = self.transport:returncode()
  self.exited = true
  if self.state ~= "exited" and self.state ~= "failed" then
    return self:_fail("LSP server process exited")
  end
  return true
end

function client_mt:pump_once(max_bytes)
  self:_drain_stderr()
  if self.transport then
    local read_count, read_err = self:read_once(max_bytes or 8192)
    if read_count == nil then return nil, read_err end
  end
  local processed, process_err = self:process_all()
  if processed == nil then return nil, process_err end
  self:_drain_stderr()
  self:_check_process_exit()
  return processed or 0
end

function client_mt:initialize_params(options)
  options = options or {}
  return {
    processId = system.get_process_id and system.get_process_id() or lsp_json.null,
    rootUri = options.root_uri or lsp_json.null,
    rootPath = options.root_path or lsp_json.null,
    capabilities = {
      general = {
        positionEncodings = lsp_json.array({ "utf-16", "utf-8" }),
      },
      workspace = {},
      textDocument = {},
      window = {},
    },
    trace = "off",
    initializationOptions = options.initialization_options or nil,
  }
end

function client_mt:_on_initialize_response(result, err_obj, entry)
  if entry.generation ~= self.generation or self.state ~= "initializing" then
    quiet_log("LSP dropped stale initialize response for generation %s", tostring(entry.generation))
    return
  end
  if err_obj then
    self:_fail("initialize failed: " .. tostring(err_obj.message or err_obj.code))
    return
  end
  result = type(result) == "table" and result or {}
  self.initialize_result = result
  self.capabilities = type(result.capabilities) == "table" and result.capabilities or {}
  self.server_info = result.serverInfo or result.server_info
  self.position_encoding = negotiate_position_encoding(result)
  self:send_notification("initialized", {})
  self:_set_state("ready")
end

function client_mt:begin_initialize(options)
  options = options or {}
  self:_set_state("initializing")
  self.requests.generation = self.generation
  local id, err = self:send_request("initialize", self:initialize_params(options), function(result, err_obj, entry)
    self:_on_initialize_response(result, err_obj, entry)
  end, { generation = self.generation, timeout = options.initialize_timeout })
  if not id then return self:_fail(err) end
  self.initialize_id = id
  return true
end

function client_mt:wait_until_ready(timeout, scan)
  timeout = timeout or 5
  scan = scan or 0.01
  local start = system.get_time()
  while system.get_time() - start < timeout do
    if self.state == "ready" then return true end
    if self.failed then return nil, self.error end
    self:pump_once()
    if self.state == "ready" then return true end
    if self.failed then return nil, self.error end
    system.sleep(scan)
  end
  return self:_fail("initialize timeout")
end

function client_mt:spawn(command, options)
  options = options or {}
  local lsp_process = require "core.lsp.process"
  self.command = command
  self:_set_state("starting")
  local transport, err = lsp_process.start(command, options.process_options or options)
  if not transport then return self:_fail(err) end
  self.transport = transport
  return self:begin_initialize(options)
end

function client.start(command, options)
  options = options or {}
  local self = client.new(nil, options)
  local ok, err = self:spawn(command, options)
  if not ok then return nil, err, self end
  if options.wait == false then return self end
  ok, err = self:wait_until_ready(options.initialize_timeout or options.timeout or 5, options.scan)
  if not ok then return nil, err, self end
  return self
end

function client_mt:shutdown(timeout, scan)
  timeout = timeout or 2
  scan = scan or 0.01
  if self.state == "exited" then return true end
  self:_set_state("shutting_down")
  self.generation = self.generation + 1
  self.requests.generation = self.generation

  local shutdown_done = false
  if self.transport and not self.failed then
    self.shutdown_id = self.requests:register("shutdown", function(_result, _err_obj)
      shutdown_done = true
    end, { generation = self.generation })
    local ok = self:send_raw(jsonrpc.request(self.shutdown_id, "shutdown", nil))
    if not ok then shutdown_done = true end
  end

  local start = system.get_time()
  while not shutdown_done and system.get_time() - start < timeout do
    self:_drain_stderr()
    if self.transport and self.transport.read then
      local count = self:read_once(8192)
      if count == nil then break end
      self:process_all()
    end
    if self.transport and self.transport.running and not self.transport:running() then break end
    system.sleep(scan)
  end

  if self.transport and not self.failed then
    self:send_notification("exit")
  end
  if self.transport and self.transport.close_stdin then
    self.transport:close_stdin()
  elseif self.transport and self.transport.close then
    self.transport:close()
  end

  start = system.get_time()
  while self.transport and self.transport.running and self.transport:running()
    and system.get_time() - start < timeout
  do
    self:_drain_stderr()
    system.sleep(scan)
  end
  if self.transport and self.transport.running and self.transport:running() then
    if self.transport.kill then self.transport:kill() end
  end
  if self.transport and self.transport.wait then
    self.transport:wait(1000, scan)
  end
  self:_drain_stderr()
  self.exit_code = self.transport and self.transport.returncode and self.transport:returncode() or self.exit_code
  self.exited = true
  if self.requests and self.requests.fail_all then
    self.requests:fail_all(jsonrpc.ERROR_REQUEST_CANCELLED, "client exited")
  end
  clear_diagnostics_for_client(self)
  self:_set_state("exited")
  self.incoming:close("client exited")
  return true
end

return client
