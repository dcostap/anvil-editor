-- Runs one child process and streams its output to the UI as it arrives.
-- Process creation can block for hundreds of milliseconds on Windows, so
-- long-running streaming tools such as ripgrep start here instead of on the
-- UI thread.
--
-- The consumer acknowledges stdout bytes on `payload.ack_channel`. The worker
-- stops reading stdout while more than `payload.window_bytes` are unacknowledged,
-- so a fast producer blocks on its pipe instead of filling UI memory.

local worker = {}

local READ_CHUNK = 65536
local POLL_SECONDS = 0.002
local DEFAULT_WINDOW = 1024 * 1024

local function read_available(proc, stream, max)
  local chunks, total = {}, 0
  while total < max do
    local chunk = proc:read(stream, math.min(READ_CHUNK, max - total))
    if not chunk or chunk == "" then break end
    chunks[#chunks + 1] = chunk
    total = total + #chunk
  end
  if total == 0 then return nil end
  return table.concat(chunks)
end

function worker.run(payload, ctx)
  local pipe_stderr = payload.stderr == "pipe"
  local proc, start_err, start_code = process.start(payload.command, {
    cwd = payload.cwd,
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = pipe_stderr and process.REDIRECT_PIPE or process.REDIRECT_DISCARD,
  })
  if not proc then
    ctx.send { type = "final", payload = {
      error = { kind = "start_failed", message = start_err or "process start failed", code = start_code },
    } }
    return
  end

  local ack = payload.ack_channel and thread.get_channel(payload.ack_channel)
  local window = payload.window_bytes or DEFAULT_WINDOW
  local outstanding = 0

  local function abort()
    proc:kill()
    ctx.send { type = "cancelled", payload = {} }
  end

  local exited = false
  while true do
    if ctx.cancelled() then return abort() end
    if ack then
      local acked = ack:first()
      while acked ~= nil do
        ack:pop()
        outstanding = outstanding - acked
        acked = ack:first()
      end
    end
    local open = not ack or outstanding < window
    local out = open and read_available(proc, process.STREAM_STDOUT, window) or nil
    local err = pipe_stderr and read_available(proc, process.STREAM_STDERR, READ_CHUNK) or nil
    if out or err then
      if out and ack then outstanding = outstanding + #out end
      if not ctx.send { type = "chunk", payload = { stdout = out, stderr = err } } then
        return abort()
      end
    elseif exited and open then
      break
    elseif not exited and not proc:running() then
      -- Read once more after exit: output written just before exit is still
      -- in the pipe.
      exited = true
    else
      system.sleep(POLL_SECONDS)
    end
  end

  ctx.send { type = "final", payload = { code = proc:returncode() or 0 } }
end

return worker
