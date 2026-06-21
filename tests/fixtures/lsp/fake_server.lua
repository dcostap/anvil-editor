local jsonrpc = require "core.lsp.jsonrpc"
local lsp_json = require "core.lsp.json"

local mode = os.getenv("ANVIL_LSP_FAKE_SERVER_MODE") or "framed"

local function write_stdout(text)
  io.stdout:write(text)
  io.stdout:flush()
end

local function write_stderr(text)
  io.stderr:write(text)
  io.stderr:flush()
end

local function sleep(seconds)
  system.sleep(seconds)
end

local function frame(message)
  local bytes = jsonrpc.encode(message)
  -- The fake server writes through Lua stdio. On Windows that stream is in text
  -- mode and expands \n to \r\n, so write bare LF here to produce real CRLF
  -- framing bytes on the pipe. Real LSP subprocess pipes are byte streams; this
  -- adjustment is only for the scripted Lua fixture.
  if PLATFORM == "Windows" then
    bytes = bytes:gsub("\r\n", "\n")
  end
  return bytes
end

local function send(message)
  write_stdout(frame(message))
end

local function read_message()
  local content_length
  while true do
    local line = io.stdin:read("*l")
    if not line then return nil, "eof" end
    line = line:gsub("\r$", "")
    if line == "" then break end
    local name, value = line:match("^([^:]+):%s*(.-)%s*$")
    if name and name:lower() == "content-length" then
      content_length = tonumber(value)
    end
  end
  if not content_length then return nil, "missing content-length" end
  local body = io.stdin:read(content_length)
  if not body or #body < content_length then return nil, "eof" end
  local decoded, decode_err = lsp_json.decode(body)
  if not decoded then return nil, decode_err end
  return jsonrpc.normalize(decoded)
end

local function read_until(predicate)
  while true do
    local message, err = read_message()
    if not message then return nil, err end
    if predicate(message) then return message end
  end
end

local function initialize_result(position_encoding, capabilities)
  capabilities = capabilities or { textDocumentSync = 0 }
  capabilities.positionEncoding = capabilities.positionEncoding or position_encoding or "utf-16"
  return {
    capabilities = capabilities,
    serverInfo = {
      name = "anvil-fake-lsp",
      version = "8.4",
    },
  }
end

local function serve_lifecycle(position_encoding, opts)
  opts = opts or {}
  if opts.stderr then write_stderr(opts.stderr) end
  local initialize = assert(read_until(function(message)
    return message.kind == "request" and message.method == "initialize"
  end))
  local capabilities = initialize.params and initialize.params.capabilities or {}
  local workspace = capabilities.workspace or {}
  local window = capabilities.window or {}
  local text_document = capabilities.textDocument or {}
  local completion = text_document.completion
  local allowed_completion = type(completion) == "table"
    and type(completion.completionItem) == "table"
    and completion.completionItem.labelDetailsSupport == true
    and next(completion.completionItem, "labelDetailsSupport") == nil
    and next(completion, "completionItem") == nil
  local bad_capabilities = {}
  if workspace.configuration then bad_capabilities[#bad_capabilities + 1] = "workspace.configuration" end
  if workspace.applyEdit then bad_capabilities[#bad_capabilities + 1] = "workspace.applyEdit" end
  if text_document.semanticTokens ~= nil then bad_capabilities[#bad_capabilities + 1] = "textDocument.semanticTokens" end
  if completion ~= nil and not allowed_completion then bad_capabilities[#bad_capabilities + 1] = "textDocument.completion" end
  if text_document.diagnostic ~= nil then bad_capabilities[#bad_capabilities + 1] = "textDocument.diagnostic" end
  if #bad_capabilities > 0 then
    write_stderr("truthful-capabilities=bad " .. table.concat(bad_capabilities, ",") .. "\n")
  else
    write_stderr("truthful-capabilities=ok\n")
  end
  if opts.delay_initialize then sleep(opts.delay_initialize) end
  send(jsonrpc.response(initialize.id, initialize_result(position_encoding)))
  assert(read_until(function(message)
    return message.kind == "notification" and message.method == "initialized"
  end))
  if opts.after_initialized then opts.after_initialized() end
  local shutdown = assert(read_until(function(message)
    return message.kind == "request" and message.method == "shutdown"
  end))
  send(jsonrpc.response(shutdown.id, lsp_json.null))
  read_until(function(message)
    return message.kind == "notification" and message.method == "exit"
  end)
end

if mode == "lifecycle_success" then
  serve_lifecycle("utf-16")
elseif mode == "lifecycle_utf8" then
  serve_lifecycle("utf-8")
elseif mode == "lifecycle_stderr" then
  serve_lifecycle("utf-16", { stderr = string.rep("stderr-tail-line\n", 32) })
elseif mode == "initialize_timeout" then
  for i = 1, 20 do
    send(jsonrpc.notification("window/logMessage", { type = 3, message = "waiting " .. i }))
    sleep(0.05)
  end
elseif mode == "initialize_error" then
  local initialize = assert(read_until(function(message)
    return message.kind == "request" and message.method == "initialize"
  end))
  send(jsonrpc.error_response(initialize.id, jsonrpc.ERROR_INTERNAL_ERROR, "fake initialize failure"))
  sleep(1)
elseif mode == "crash_before_initialize" then
  os.exit(42)
elseif mode == "delayed_initialize" then
  serve_lifecycle("utf-16", { delay_initialize = 0.6 })
elseif mode == "manager_integration" then
  local initialize = assert(read_until(function(message)
    return message.kind == "request" and message.method == "initialize"
  end))
  send(jsonrpc.response(initialize.id, initialize_result("utf-16", {
    textDocumentSync = 1,
    documentSymbolProvider = true,
    definitionProvider = true,
    referencesProvider = true,
  })))
  assert(read_until(function(message)
    return message.kind == "notification" and message.method == "initialized"
  end))
  while true do
    local message = assert(read_message())
    if message.kind == "notification" and message.method == "textDocument/didOpen" then
      local text_document = message.params and message.params.textDocument or {}
      local text = tostring(text_document.text or "")
      write_stderr("didOpen=" .. tostring(text_document.uri) .. "\n")
      write_stderr("didOpenTextLength=" .. tostring(#text) .. "\n")
      write_stderr("didOpenText=" .. text:gsub("\r", "\\r"):gsub("\n", "\\n") .. "\n")
      if os.getenv("ANVIL_LSP_FAKE_SERVER_PUBLISH_DIAGNOSTICS") == "1" then
        send(jsonrpc.notification("textDocument/publishDiagnostics", {
          textDocument = { uri = text_document.uri, version = text_document.version },
          diagnostics = {
            {
              range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 4 } },
              severity = 1,
              source = "fake-lsp",
              message = "fake diagnostic",
            },
          },
        }))
      end
    elseif message.kind == "notification" and message.method == "textDocument/didChange" then
      local text_document = message.params and message.params.textDocument or {}
      write_stderr("didChange=" .. tostring(text_document.version) .. "\n")
    elseif message.kind == "request" and message.method == "shutdown" then
      send(jsonrpc.response(message.id, lsp_json.null))
    elseif message.kind == "notification" and message.method == "exit" then
      return
    end
  end
elseif mode == "server_requests" then
  serve_lifecycle("utf-16", {
    after_initialized = function()
      send(jsonrpc.request("unknown-1", "server/unknown", {}))
      send(jsonrpc.request("apply-1", "workspace/applyEdit", { edit = {} }))
      send(jsonrpc.request("config-1", "workspace/configuration", { items = lsp_json.array({}) }))
      send(jsonrpc.request("register-1", "client/registerCapability", {}))
      send(jsonrpc.request("progress-create-1", "window/workDoneProgress/create", { token = "t" }))
      send(jsonrpc.notification("window/logMessage", { type = 3, message = "fake log" }))
      send(jsonrpc.notification("window/showMessage", { type = 2, message = "fake show" }))
      send(jsonrpc.notification("$/progress", { token = "t", value = { kind = "begin" } }))

      local seen = {}
      while not (seen["unknown-1"] and seen["apply-1"] and seen["config-1"]
        and seen["register-1"] and seen["progress-create-1"])
      do
        local message = assert(read_message())
        if message.kind == "response" then
          seen[message.id] = true
          if message.id == "unknown-1" then
            write_stderr("unknown-response-code=" .. tostring(message.error and message.error.code) .. "\n")
          elseif message.id == "apply-1" then
            write_stderr("apply-response-applied=" .. tostring(message.result and message.result.applied) .. "\n")
          elseif message.id == "config-1" then
            write_stderr("configuration-response=array\n")
          elseif message.id == "register-1" then
            write_stderr("register-response=ok\n")
          elseif message.id == "progress-create-1" then
            write_stderr("progress-create-response=ok\n")
          end
        end
      end
    end,
  })
elseif mode == "chunked_stdout" then
  write_stdout("lsp-chunk-one")
  sleep(2.0)
  write_stdout("lsp-chunk-two")
elseif mode == "stdout_stderr" then
  write_stdout("stdout-one\n")
  write_stderr("stderr-one\n")
  sleep(0.2)
  write_stderr("stderr-two\n")
  write_stdout("stdout-two\n")
elseif mode == "framed_partial_multiple" then
  local one = frame(jsonrpc.notification("fake/one", { value = 1 }))
  local two = frame(jsonrpc.notification("fake/two", lsp_json.array({})))
  write_stdout(one:sub(1, 7))
  sleep(0.05)
  write_stdout(one:sub(8) .. two)
elseif mode == "delayed_stdout" then
  sleep(0.6)
  write_stdout("delayed-data")
elseif mode == "exit_code" then
  os.exit(17)
elseif mode == "echo_stdin" then
  local input = io.stdin:read("*a") or ""
  write_stdout(input)
elseif mode == "exit_immediately" then
  os.exit(0)
else
  write_stdout(frame(jsonrpc.notification("fake/default")))
end
