local core = require "core"
local lsp_json = require "core.lsp.json"

local jsonrpc = {}

jsonrpc.ERROR_PARSE_ERROR = -32700
jsonrpc.ERROR_INVALID_REQUEST = -32600
jsonrpc.ERROR_METHOD_NOT_FOUND = -32601
jsonrpc.ERROR_INVALID_PARAMS = -32602
jsonrpc.ERROR_INTERNAL_ERROR = -32603
jsonrpc.ERROR_REQUEST_CANCELLED = -32800

local function quiet_log(...)
  if core and core.log_quiet then
    core.log_quiet(...)
  end
end

local function has_key(tbl, key)
  return type(tbl) == "table" and rawget(tbl, key) ~= nil
end

function jsonrpc.request(id, method, params)
  assert(type(method) == "string", "jsonrpc.request expects a method")
  local message = {
    jsonrpc = "2.0",
    id = id,
    method = method,
  }
  if params ~= nil then message.params = params end
  return message
end

function jsonrpc.notification(method, params)
  assert(type(method) == "string", "jsonrpc.notification expects a method")
  local message = {
    jsonrpc = "2.0",
    method = method,
  }
  if params ~= nil then message.params = params end
  return message
end

function jsonrpc.response(id, result, error_obj)
  local message = {
    jsonrpc = "2.0",
    id = id,
  }
  if error_obj ~= nil then
    message.error = error_obj
  else
    message.result = result == nil and lsp_json.null or result
  end
  return message
end

function jsonrpc.error_response(id, code, message, data)
  local err = { code = code, message = message }
  if data ~= nil then err.data = data end
  return jsonrpc.response(id, nil, err)
end

function jsonrpc.normalize(raw)
  if type(raw) ~= "table" then
    return nil, "message must be an object"
  end
  if raw.jsonrpc ~= "2.0" then
    return nil, "message missing jsonrpc=2.0"
  end

  local id = raw.id
  local id_type = type(id)
  if id ~= nil and id_type ~= "number" and id_type ~= "string" then
    return nil, "message id must be a number or string"
  end

  local method = raw.method
  if method ~= nil and type(method) ~= "string" then
    return nil, "message method must be a string"
  end

  if method ~= nil and id ~= nil then
    return {
      kind = "request",
      id = id,
      method = method,
      params = raw.params,
      raw = raw,
    }
  elseif method ~= nil then
    return {
      kind = "notification",
      method = method,
      params = raw.params,
      raw = raw,
    }
  elseif id ~= nil then
    if has_key(raw, "error") then
      if type(raw.error) ~= "table" then
        return nil, "response error must be an object"
      end
      return {
        kind = "response",
        id = id,
        error = raw.error,
        raw = raw,
      }
    end
    if not has_key(raw, "result") then
      return nil, "response missing result or error"
    end
    return {
      kind = "response",
      id = id,
      result = raw.result,
      raw = raw,
    }
  end

  return nil, "message must be a request, response, or notification"
end

function jsonrpc.encode_json(message)
  return lsp_json.encode(message)
end

function jsonrpc.frame_json(body)
  assert(type(body) == "string", "jsonrpc.frame_json expects a string")
  return "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
end

function jsonrpc.encode(message)
  return jsonrpc.frame_json(jsonrpc.encode_json(message))
end

local parser = {}
parser.__index = parser

function jsonrpc.new_parser(options)
  options = options or {}
  return setmetatable({
    buffer = "",
    failed = false,
    max_header_bytes = options.max_header_bytes or 8192,
    max_body_bytes = options.max_body_bytes or 16 * 1024 * 1024,
  }, parser)
end

local function fail(self, message)
  self.failed = true
  quiet_log("LSP JSON-RPC framing failed: %s", message)
  return nil, message
end

local function parse_headers(header)
  local content_length
  for line in (header .. "\r\n"):gmatch("(.-)\r\n") do
    if line ~= "" then
      local name, value = line:match("^([^:]+):%s*(.-)%s*$")
      if not name then
        return nil, "malformed header line"
      end
      if name:lower() == "content-length" then
        if content_length ~= nil then
          return nil, "duplicate Content-Length header"
        end
        if not value:match("^%d+$") then
          return nil, "invalid Content-Length header"
        end
        content_length = tonumber(value)
      end
    end
  end
  if content_length == nil then
    return nil, "missing Content-Length header"
  end
  return content_length
end

function parser:feed(chunk)
  if self.failed then
    return nil, "parser is failed"
  end
  if type(chunk) ~= "string" then
    return fail(self, "chunk must be a string")
  end
  self.buffer = self.buffer .. chunk
  local messages = {}

  while true do
    local header_end = self.buffer:find("\r\n\r\n", 1, true)
    if not header_end then
      if #self.buffer > self.max_header_bytes then
        return fail(self, "header exceeds maximum size")
      end
      return messages
    end

    local header = self.buffer:sub(1, header_end - 1)
    if #header > self.max_header_bytes then
      return fail(self, "header exceeds maximum size")
    end

    local content_length, header_err = parse_headers(header)
    if not content_length then
      return fail(self, header_err)
    end
    if content_length > self.max_body_bytes then
      return fail(self, "body exceeds maximum size")
    end

    local body_start = header_end + 4
    local body_end = body_start + content_length - 1
    if #self.buffer < body_end then
      return messages
    end

    local body = self.buffer:sub(body_start, body_end)
    self.buffer = self.buffer:sub(body_end + 1)

    local decoded, decode_err = lsp_json.decode(body)
    if decoded == nil then
      return fail(self, "invalid JSON body: " .. tostring(decode_err))
    end
    local normalized, normalize_err = jsonrpc.normalize(decoded)
    if not normalized then
      return fail(self, "invalid JSON-RPC message: " .. tostring(normalize_err))
    end
    messages[#messages + 1] = normalized
  end
end

function parser:is_failed()
  return self.failed
end

local tracker = {}
tracker.__index = tracker

function jsonrpc.new_request_tracker(options)
  options = options or {}
  return setmetatable({
    next_id_value = options.next_id or 1,
    pending = {},
    generation = options.generation or 1,
  }, tracker)
end

function tracker:next_id()
  local id = self.next_id_value
  self.next_id_value = self.next_id_value + 1
  return id
end

function tracker:register(method, callback, options)
  assert(type(method) == "string", "request method must be a string")
  options = options or {}
  local id = options.id or self:next_id()
  self.pending[id] = {
    id = id,
    method = method,
    callback = callback,
    generation = options.generation or self.generation,
    created_at = options.created_at,
    timeout = options.timeout,
  }
  return id
end

function tracker:pending_count()
  local count = 0
  for _ in pairs(self.pending) do count = count + 1 end
  return count
end

function tracker:get(id)
  return self.pending[id]
end

function tracker:take(id)
  local entry = self.pending[id]
  self.pending[id] = nil
  return entry
end

function tracker:cancel(id, reason)
  local entry = self:take(id)
  if entry and entry.callback then
    entry.callback(nil, { code = jsonrpc.ERROR_REQUEST_CANCELLED, message = reason or "cancelled" }, entry)
  end
  return entry ~= nil
end

function tracker:dispatch_response(message, generation)
  if not message or message.kind ~= "response" then
    return nil, "not a response"
  end
  local entry = self:take(message.id)
  if not entry then
    quiet_log("LSP JSON-RPC dropped response for unknown id %s", tostring(message.id))
    return false, "unknown request id"
  end
  if generation ~= nil and entry.generation ~= generation then
    quiet_log("LSP JSON-RPC dropped stale response for id %s", tostring(message.id))
    return false, "stale generation"
  end
  if entry.callback then
    entry.callback(message.result, message.error, entry, message)
  end
  return true, entry
end

return jsonrpc
