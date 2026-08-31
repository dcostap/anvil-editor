local config


---An abstraction over the standard input and outputs of a process
---that allows you to read and write data easily.
---@class process.stream
---@field private fd process.streamtype
---@field private process process
---@field private buf string[]
---@field private len number
process.stream = {}
process.stream.__index = process.stream

---Creates a stream from a process.
---@param proc process The process to wrap.
---@param fd process.streamtype The standard stream of the process to wrap.
function process.stream.new(proc, fd)
  return setmetatable({
    fd = fd,
    process = proc,
    buf = {},
    head = 1,
    head_offset = 1,
    tail = 0,
    len = 0,
  }, process.stream)
end

local function take_buffer(stream, amount)
  local chunks = {}
  local remaining = math.min(amount, stream.len)
  while remaining > 0 and stream.head <= stream.tail do
    local chunk = stream.buf[stream.head]
    local available = #chunk - stream.head_offset + 1
    local take = math.min(remaining, available)
    chunks[#chunks + 1] = chunk:sub(stream.head_offset, stream.head_offset + take - 1)
    stream.head_offset = stream.head_offset + take
    stream.len = stream.len - take
    remaining = remaining - take
    if stream.head_offset > #chunk then
      stream.buf[stream.head] = nil
      stream.head = stream.head + 1
      stream.head_offset = 1
    end
  end
  if stream.len == 0 then
    stream.buf = {}
    stream.head = 1
    stream.head_offset = 1
    stream.tail = 0
  end
  return table.concat(chunks)
end

---@alias process.stream.readtype
---| `"line"` # Reads a single line
---| `"all"`  # Reads the entire stream
---| `"L"`    # Reads a single line, keeping the trailing newline character.

---Options that can be passed to stream.read().
---@class process.stream.readoption
---@field public timeout number The number of seconds to wait before the function throws an error. Reads do not time out by default.
---@field public scan number The number of seconds to yield in a coroutine. Defaults to `1/config.fps`.

---Reads data from the stream.
---
---When called inside a coroutine such as `core.add_thread()`,
---the function yields to the main thread occasionally to avoid blocking the editor.
---If the function is not called inside the coroutine, the function returns immediately
---without waiting for more data.
---@param bytes process.stream.readtype|integer The format or number of bytes to read.
---@param options? process.stream.readoption Options for reading from the stream.
---@return string|nil data The string read from the stream, nil if no data could be read or an error occurred.
---@return string? errmsg The error message when reading fails.
---@return process.errortype|integer? errcode The error code when reading fails.
function process.stream:read(bytes, options)
  if type(bytes) == 'string' then bytes = bytes:gsub("^%*", "") end
  options = options or {}
  local start = system.get_time()
  local target = 0
  if bytes == "line" or bytes == "l" or bytes == "L" then
    if self.len > 0 then
      for i = self.head, self.tail do
        local v = self.buf[i]
        local first = i == self.head and self.head_offset or 1
        local s = v:find("\n", first, true)
        if s then
          target = target + s - first + 1
          break
        elseif i < self.tail then
          target = target + #v - first + 1
        else
          target = 1024*1024*1024*1024
        end
      end
    else
      target = 1024*1024*1024*1024
    end
  elseif bytes == "all" or bytes == "a" then
    target = 1024*1024*1024*1024
  elseif type(bytes) == "number" then
    target = bytes
  else
    error("'" .. bytes .. "' is an unsupported read option for this stream")
  end

  while self.len < target do
    local chunk, err, errcode = self.process.process:read(self.fd, math.max(target - self.len, 0))
    if not chunk then
      if err then return nil, err, errcode end
      break
    end
    if #chunk > 0 then
      self.tail = self.tail + 1
      self.buf[self.tail] = chunk
      self.len = self.len + #chunk
      if bytes == "line" or bytes == "l" or bytes == "L" then
        local s = chunk:find("\n", 1, true)
        if s then target = self.len - #chunk + s end
      end
    elseif coroutine.isyieldable() then
      if options.timeout and system.get_time() - start > options.timeout then
        error("timeout expired")
      end
      coroutine.yield(options.scan or (1 / config.fps))
    else
      break
    end
  end
  if self.len == 0 then return nil end
  local str = take_buffer(self, target)
  if (bytes == "line" or bytes == "l") and str:byte(-1) == 10 then
    return str:sub(1, -2)
  end
  return str
end


---Options that can be passed into stream.write().
---@class process.stream.writeoption
---@field public scan number The number of seconds to yield in a coroutine. Defaults to `1/config.fps`.

---Writes data into the stream.
---
---When called inside a coroutine such as `core.add_thread()`,
---the function yields to the main thread occasionally to avoid blocking the editor.
---If the function is not called inside the coroutine,
---the function writes as much data as possible before returning.
---@param bytes string The bytes to write into the stream.
---@param options? process.stream.writeoption Options for writing to the stream.
---@return integer|nil num_bytes The number of bytes written to the stream, or nil on error.
---@return string? errmsg The error message when writing fails.
---@return process.errortype|integer? errcode The error code when writing fails.
function process.stream:write(bytes, options)
  options = options or {}
  local buf = bytes
  while #buf > 0 do
    local len, err, errcode = self.process.process:write(buf)
    if not len then return nil, err, errcode end
    if not coroutine.isyieldable() then return len end
    buf = buf:sub(len + 1)
    coroutine.yield(options.scan or (1 / config.fps))
  end
  return #bytes - #buf
end


---Closes the stream and its underlying resources.
---@return boolean|nil success True when closed, or nil on error.
---@return string? errmsg The error message when closing fails.
---@return process.errortype|integer? errcode The error code when closing fails.
function process.stream:close()
  return self.process.process:close_stream(self.fd)
end


---Waits for the process to exit.
---When called inside a coroutine such as `core.add_thread()`,
---the function yields to the main thread occasionally to avoid blocking the editor.
---Otherwise, the function blocks the editor until the process exited or the timeout has expired.
---@param timeout? number The amount of milliseconds to wait. If omitted, the function will wait indefinitely.
---@param scan? number The amount of seconds to yield while scanning. If omitted, the scan rate will be the FPS.
---@return integer|nil exit_code The exit code for this process, or nil if the wait timed out or an error occurred.
---@return string? errmsg The error message when the native wait fails.
---@return process.errortype|integer? errcode The error code when the native wait fails.
function process:wait(timeout, scan)
  if not coroutine.isyieldable() then
    return self.process:wait(timeout)
  end
  if timeout == nil or timeout == process.WAIT_INFINITE then
    timeout = math.huge
  elseif timeout == process.WAIT_DEADLINE then
    return self.process:wait(timeout)
  end
  local start = system.get_time()
  while self.process:running() and (system.get_time() - start) * 1000 < timeout do
    coroutine.yield(scan or (1 / config.fps))
  end
  return self.process:returncode()
end


function process:__index(k)
  if process[k] then return process[k] end
  if type(self.process[k]) == 'function' then return function(newself, ...) return self.process[k](self.process, ...) end end
  return self.process[k]
end

local function env_key(str)
  if PLATFORM == "Windows" then return str:upper() else return str end
end

---Sorts the environment variable by its key, converted to uppercase.
---This is only needed on Windows.
local function compare_env(a, b)
  return env_key(a:match("([^=]*)=")) < env_key(b:match("([^=]*)="))
end

local old_start = process.start

---@class process.options
---@field detach? boolean Keep the child alive independently of this process object.
---@field background? boolean Launch without foreground-window activation on Windows. Defaults to true on Windows.
---@field timeout? number Process operation timeout in seconds.
---@field stdin? integer
---@field stdout? integer
---@field stderr? integer
---@field cwd? string
---@field env? table<string, string>

---Create and start a new process, wrapping the native process with stream helpers.
---
---When `options.env` is a table, values are merged over the system environment.
---On Windows, environment keys are compared case-insensitively and sorted for
---the environment block passed to the native process API.
---@param command string|table First index is the command to execute and subsequent elements are parameters.
---@param options? process.options
---@return process|nil proc The wrapped process, or nil on error.
---@return string? errmsg The error message when process creation fails.
---@return process.errortype|integer? errcode The error code when process creation fails.
function process.start(command, options)
  -- delay config load since some values depend on system scale
  if not config then config = require "core.config" end
  assert(type(command) == "table" or type(command) == "string", "invalid argument #1 to process.start(), expected string or table, got "..type(command))
  assert(type(options) == "table" or type(options) == "nil", "invalid argument #2 to process.start(), expected table or nil, got "..type(options))
  if PLATFORM ~= "Windows" then
    command = type(command) == "table" and command or { command }
  end
  if options then
    local copied_options = {}
    for k, v in pairs(options) do
      copied_options[k] = v
    end
    options = copied_options
  end
  if type(options) == "table" and type(options.env) == "table" then
    local user_env = options.env
    options.env = function(system_env)
      local final_env, envlist = {}, {}
      for k, v in pairs(system_env) do final_env[env_key(k)] = k.."="..v end
      for k, v in pairs(user_env)   do final_env[env_key(k)] = k.."="..v end
      for _, v in pairs(final_env)  do envlist[#envlist+1] = v end
      if PLATFORM == "Windows" then table.sort(envlist, compare_env) end
      return table.concat(envlist, "\0").."\0\0"
    end
  end
  local native, err, errcode = old_start(command, options)
  if not native then return nil, err, errcode end
  local self = setmetatable({ process = native }, process)
  self.stdout = process.stream.new(self, process.STREAM_STDOUT)
  self.stderr = process.stream.new(self, process.STREAM_STDERR)
  self.stdin  = process.stream.new(self, process.STREAM_STDIN)
  return self
end

return process
