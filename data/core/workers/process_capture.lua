-- Runs one child process to completion and returns its captured output.
-- Process creation can block for hundreds of milliseconds on Windows, so
-- callers submit this job instead of spawning on the UI thread.

local worker = {}

local READ_CHUNK = 65536
local POLL_SECONDS = 0.002

local function env_key(str)
  if PLATFORM == "Windows" then return str:upper() end
  return str
end

local function env_block(user_env)
  return function(system_env)
    local final_env, envlist = {}, {}
    for k, v in pairs(system_env) do final_env[env_key(k)] = k .. "=" .. v end
    for k, v in pairs(user_env) do final_env[env_key(k)] = k .. "=" .. v end
    for _, v in pairs(final_env) do envlist[#envlist + 1] = v end
    if PLATFORM == "Windows" then
      table.sort(envlist, function(a, b)
        return env_key(a:match("([^=]*)=")) < env_key(b:match("([^=]*)="))
      end)
    end
    return table.concat(envlist, "\0") .. "\0\0"
  end
end

local function reader(proc, stream, max)
  local chunks, total = {}, 0
  local r = { chunks = chunks }
  function r.pump()
    local got = false
    while true do
      local chunk, _, errcode = proc:read(stream, READ_CHUNK)
      if chunk and #chunk > 0 then
        chunks[#chunks + 1] = chunk
        total = total + #chunk
        got = true
        if total > max then return false, got end
      elseif chunk == "" or errcode == process.ERROR_WOULDBLOCK or not chunk then
        return true, got
      end
    end
  end
  return r
end

function worker.run(payload, ctx)
  local function finish(result)
    ctx.send { type = "final", payload = result }
  end

  local stdin_data = payload.stdin_data
  local proc, start_err, start_code = process.start(payload.command, {
    stdin = stdin_data and process.REDIRECT_PIPE or process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    env = payload.env and env_block(payload.env) or nil,
  })
  if not proc then
    finish { error = { kind = "start_failed", message = start_err or "process start failed", code = start_code } }
    return
  end

  local out = reader(proc, process.STREAM_STDOUT, payload.max_output)
  local err = reader(proc, process.STREAM_STDERR, payload.max_stderr)

  local function abort(kind, message, code)
    proc:terminate()
    if kind == "cancelled" then
      ctx.send { type = "cancelled", payload = {} }
    else
      finish { error = { kind = kind, message = message, code = code } }
    end
  end

  local function pump_all()
    local ok, got_out = out.pump()
    if not ok then return "output_too_large" end
    local err_ok, got_err = err.pump()
    if not err_ok then return "stderr_too_large" end
    return nil, got_out or got_err
  end

  if stdin_data then
    local offset = 1
    while offset <= #stdin_data do
      if ctx.cancelled() then return abort("cancelled") end
      local written, write_err, write_code = proc:write(stdin_data:sub(offset, offset + 16383))
      if not written then return abort("write_failed", write_err or "process input write failed", write_code) end
      offset = offset + written
      local too_large = pump_all()
      if too_large then return abort(too_large, "output too large") end
      if written == 0 then system.sleep(POLL_SECONDS) end
    end
    proc:close_stream(process.STREAM_STDIN)
  end

  while proc:running() do
    if ctx.cancelled() then return abort("cancelled") end
    local too_large, progressed = pump_all()
    if too_large then return abort(too_large, "output too large") end
    if not progressed then system.sleep(POLL_SECONDS) end
  end
  local too_large = pump_all()
  if too_large then return abort(too_large, "output too large") end

  finish {
    code = proc:returncode() or 0,
    stdout = table.concat(out.chunks),
    stderr = table.concat(err.chunks),
  }
end

return worker
