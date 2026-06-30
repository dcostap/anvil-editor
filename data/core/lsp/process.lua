local core_process = require "core.process"

local lsp_process = {}
local transport = {}
transport.__index = transport

local DEFAULT_READ_BYTES = 8192
-- Keep individual stdin writes comfortably below common Windows anonymous
-- pipe buffers. Larger LSP messages are still streamed in pieces; this avoids
-- spurious pipe errors from nonblocking process IO when a server has not
-- drained the previous frame yet.
local DEFAULT_WRITE_BYTES = 2048
local DEFAULT_WRITE_SCAN = 0.005
local DEFAULT_WRITE_STALL_TIMEOUT = 5

local function native_process(proc)
  return proc and (proc.process or proc)
end

function lsp_process.start(command, options)
  options = options or {}
  local start_options = {}
  for key, value in pairs(options) do
    start_options[key] = value
  end
  start_options.stdin = start_options.stdin or core_process.REDIRECT_PIPE
  start_options.stdout = start_options.stdout or core_process.REDIRECT_PIPE
  start_options.stderr = start_options.stderr or core_process.REDIRECT_PIPE

  local proc, err, errcode = core_process.start(command, start_options)
  if not proc then return nil, err, errcode end
  return lsp_process.new(proc, options)
end

function lsp_process.new(proc, options)
  assert(proc, "lsp_process.new expects a process")
  return setmetatable({
    proc = proc,
    native = native_process(proc),
    closed = false,
    stdin_closed = false,
    stderr_tail = "",
    stderr_tail_limit = (options and options.stderr_tail_limit) or 8192,
    write_scan = (options and options.write_scan) or DEFAULT_WRITE_SCAN,
    write_stall_timeout = (options and options.write_stall_timeout) or DEFAULT_WRITE_STALL_TIMEOUT,
  }, transport)
end

local function read_available(self, fd, max_bytes)
  if self.closed then return nil, "transport closed" end
  max_bytes = max_bytes or DEFAULT_READ_BYTES
  local chunk, err, errcode = self.native:read(fd, max_bytes)
  if chunk == nil then
    if err then return nil, err, errcode end
    return ""
  end
  return chunk
end

function transport:read(max_bytes)
  return read_available(self, core_process.STREAM_STDOUT, max_bytes)
end

function transport:read_stderr(max_bytes)
  local chunk, err, errcode = read_available(self, core_process.STREAM_STDERR, max_bytes)
  if chunk and #chunk > 0 and self.stderr_tail_limit > 0 then
    self.stderr_tail = self.stderr_tail .. chunk
    if #self.stderr_tail > self.stderr_tail_limit then
      self.stderr_tail = self.stderr_tail:sub(#self.stderr_tail - self.stderr_tail_limit + 1)
    end
  end
  return chunk, err, errcode
end

function transport:drain_stderr(max_bytes, max_iterations)
  max_bytes = max_bytes or DEFAULT_READ_BYTES
  max_iterations = max_iterations or 1024
  local chunks = {}
  for _ = 1, max_iterations do
    local chunk, err, errcode = self:read_stderr(max_bytes)
    if not chunk then return nil, err, errcode end
    if chunk == "" then break end
    chunks[#chunks + 1] = chunk
  end
  return table.concat(chunks)
end

function transport:write(bytes)
  if self.closed then return nil, "transport closed" end
  if self.stdin_closed then return nil, "stdin closed" end
  assert(type(bytes) == "string", "stdio transport write expects a string")

  local remaining = bytes
  local total = 0
  local last_progress = system.get_time()
  while #remaining > 0 do
    local chunk = remaining:sub(1, DEFAULT_WRITE_BYTES)
    local written, err, errcode = self.native:write(chunk)
    if not written then return nil, err, errcode end
    if written == 0 then
      if system.get_time() - last_progress > self.write_stall_timeout then
        return nil, total > 0 and "write stalled after partial write" or "write stalled"
      end
      if coroutine.isyieldable() then
        coroutine.yield(self.write_scan)
      else
        system.sleep(self.write_scan)
      end
    else
      total = total + written
      last_progress = system.get_time()
      if written < #chunk then
        remaining = chunk:sub(written + 1) .. remaining:sub(#chunk + 1)
      else
        remaining = remaining:sub(#chunk + 1)
      end
    end
  end
  return total
end

function transport:close_stdin()
  if self.stdin_closed then return true end
  self.stdin_closed = true
  return self.native:close_stream(core_process.STREAM_STDIN)
end

function transport:close()
  self.closed = true
  if not self.stdin_closed then
    self.stdin_closed = true
    self.native:close_stream(core_process.STREAM_STDIN)
  end
  return true
end

function transport:running()
  return self.native:running()
end

function transport:returncode()
  return self.native:returncode()
end

function transport:wait(timeout, scan)
  if self.proc.wait then
    return self.proc:wait(timeout, scan)
  end
  return self.native:wait(timeout)
end

function transport:kill()
  if self.native.kill then return self.native:kill() end
end

function transport:terminate()
  if self.native.terminate then return self.native:terminate() end
end

return lsp_process
