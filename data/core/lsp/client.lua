local jsonrpc = require "core.lsp.jsonrpc"
local lsp_transport = require "core.lsp.transport"

local client = {}
local client_mt = {}
client_mt.__index = client_mt

function client.new(driver, options)
  options = options or {}
  local wrapped = driver
  if type(driver) == "table" and not driver.driver then
    wrapped = lsp_transport.wrap(driver)
  end
  return setmetatable({
    transport = wrapped,
    parser = jsonrpc.new_parser(options.parser),
    incoming = lsp_transport.new_incoming_queue(options.incoming_queue),
    requests = jsonrpc.new_request_tracker({ generation = options.generation or 1 }),
    request_handlers = {},
    notification_handlers = {},
    generation = options.generation or 1,
    failed = false,
    error = nil,
  }, client_mt)
end

function client_mt:on_request(method, handler)
  self.request_handlers[method] = handler
end

function client_mt:on_notification(method, handler)
  self.notification_handlers[method] = handler
end

function client_mt:_fail(err)
  self.failed = true
  self.error = err
  self.incoming:close(err)
  return nil, err
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

return client
