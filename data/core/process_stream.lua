-- UI-side reader for a child process that runs in a worker.
--
-- The worker starts the process and forwards its output, so the UI thread never
-- blocks on process creation, reads, or termination. Callers poll records from
-- a coroutine and yield while `read_until` returns nil and `done` is false.

local worker_pool = require "core.worker_pool"

local process_stream = {}

local Stream = {}
Stream.__index = Stream

local channel_sequence = 0

local function log_quiet(fmt, ...)
  local core = package.loaded.core
  if core and core.log_quiet then core.log_quiet(fmt, ...) end
end

local function pool()
  return worker_pool.named("process-stream", { worker_count = 4 })
end

local function ack_channel_name()
  channel_sequence = channel_sequence + 1
  local pid = system.get_process_id and system.get_process_id() or 0
  return string.format("anvil-process-stream-ack-%s-%d-%d",
    tostring(pid), math.floor(system.get_time() * 1000000), channel_sequence)
end

---Start `command` in a worker.
---Options: `cwd`, `stderr = true` to capture stderr, `window_bytes`.
---Returns a stream, or nil and an error when the worker pool rejects the job.
function process_stream.start(command, options)
  options = options or {}
  local ack_name = ack_channel_name()
  local ack = thread.get_channel(ack_name)
  ack:clear()
  local self = setmetatable({
    done = false,
    cancelled = false,
    exit_code = nil,
    error = nil,
    last_output_time = system.get_time(),
    buffer = "",
    pos = 1,
    parts = {},
    stderr_parts = {},
    ack = ack,
  }, Stream)

  local function finish(code, err)
    if self.done then return end
    self.done, self.exit_code, self.error = true, code, err
    self.ack:clear()
    log_quiet("process stream finished job=%s code=%s error=%s",
      tostring(self.handle and self.handle.id), tostring(code), tostring(err))
  end

  local handle, err = pool():submit {
    kind = "process_stream",
    payload = {
      command = command,
      cwd = options.cwd,
      stderr = options.stderr and "pipe" or "discard",
      ack_channel = ack_name,
      window_bytes = options.window_bytes,
    },
    on_result = function(message)
      if self.cancelled then return end
      local payload = message.payload or {}
      if message.type == "chunk" then
        if payload.stdout then
          self.parts[#self.parts + 1] = payload.stdout
          self.last_output_time = system.get_time()
        end
        if payload.stderr then self.stderr_parts[#self.stderr_parts + 1] = payload.stderr end
      elseif message.type == "final" then
        local failure = payload.error
        finish(payload.code, failure and (failure.message or failure.kind))
      end
    end,
    on_error = function(message) finish(nil, tostring(message.error or "process stream failed")) end,
    on_cancelled = function() finish(nil, "cancelled") end,
  }
  if not handle then return nil, err end
  self.handle = handle
  log_quiet("process stream started job=%s command=%s cwd=%s",
    tostring(handle.id), tostring(command[1]), tostring(options.cwd))
  return self
end

---Return the next stdout record without its separator, or nil when no complete
---record has arrived yet. After the process ends, the unterminated tail is
---returned as the last record.
function Stream:read_until(separator)
  while true do
    local buffer, pos = self.buffer, self.pos
    local stop = buffer:find(separator, pos, true)
    if stop then
      self.pos = stop + #separator
      return buffer:sub(pos, stop - 1)
    end
    if #self.parts == 0 then break end
    local received = table.concat(self.parts)
    self.parts = {}
    -- Acknowledge bytes once they leave the received queue, so one record
    -- longer than the window cannot stall the worker.
    if not self.done then self.ack:push(#received) end
    self.buffer = buffer:sub(pos) .. received
    self.pos = 1
  end
  if self.done and self.pos <= #self.buffer then
    local tail = self.buffer:sub(self.pos)
    self.buffer, self.pos = "", 1
    return tail
  end
  return nil
end

function Stream:read_line()
  return self:read_until("\n")
end

---Return the stderr text received since the previous call.
function Stream:take_stderr()
  if #self.stderr_parts == 0 then return nil end
  local text = table.concat(self.stderr_parts)
  self.stderr_parts = {}
  return text
end

---Stop the process without waiting for it.
function Stream:cancel()
  if self.done then return end
  self.cancelled = true
  self.parts, self.buffer, self.pos = {}, "", 1
  if self.handle then pool():cancel(self.handle) end
  self.done, self.error = true, "cancelled"
  self.ack:clear()
end

return process_stream
