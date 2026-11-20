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
  local eof = false
  while total < max do
    local chunk, err = proc:read(stream, math.min(READ_CHUNK, max - total))
    if err then error(err) end
    if chunk == nil then eof = true break end
    if chunk == "" then break end
    chunks[#chunks + 1] = chunk
    total = total + #chunk
  end
  return total > 0 and table.concat(chunks) or nil, eof
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

  local stdout_done, stderr_done = false, not pipe_stderr
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
    local out, err
    if open and not stdout_done then
      out, stdout_done = read_available(proc, process.STREAM_STDOUT, window)
    end
    if not stderr_done then
      err, stderr_done = read_available(proc, process.STREAM_STDERR, READ_CHUNK)
    end
    if out or err then
      if out and ack then outstanding = outstanding + #out end
      if not ctx.send { type = "chunk", payload = { stdout = out, stderr = err } } then
        return abort()
      end
    elseif stdout_done and stderr_done then
      break
    else
      -- Process exit can precede the output collector. Only nil means EOF;
      -- an empty read means that the pipe has no bytes available yet.
      system.sleep(POLL_SECONDS)
    end
  end

  ctx.send { type = "final", payload = { code = proc:returncode() or 0 } }
end

return worker
