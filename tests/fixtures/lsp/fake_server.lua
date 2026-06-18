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

if mode == "chunked_stdout" then
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
