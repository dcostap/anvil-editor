-- Shared shell launch policy and capture-mode process service.

local core = require "core"
local process = require "core.process"

local M = core.shell or {}
core.shell = M

local READ_BYTES = 64 * 1024
local POLL_SECONDS = 0.01

local function shell_name(shell)
  return tostring(shell or ""):gsub("\\", "/"):match("([^/]+)$"):lower()
end

function M.kind(shell)
  local name = shell_name(shell)
  if name == "pwsh" or name == "pwsh.exe" or name == "powershell" or name == "powershell.exe" then
    return "powershell"
  end
  if name == "cmd" or name == "cmd.exe" then return "cmd" end
  return "posix"
end

function M.capture_args(command, shell)
  local kind = M.kind(shell)
  if kind == "powershell" then
    return { shell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command }
  end
  if kind == "cmd" then return { shell, "/d", "/s", "/c", command } end
  return { shell, "-lc", command }
end

function M.capture_shells(shell)
  if shell and shell ~= "" then return { shell } end
  if PLATFORM == "Windows" then return { "pwsh.exe", "powershell.exe" } end
  return { os.getenv("SHELL") or "sh" }
end

local function callback(fn, value)
  if not fn then return end
  local ok, err = pcall(fn, value)
  if not ok then core.log_quiet("Shell capture callback failed: %s", tostring(err)) end
end

function M.capture(command, opts)
  assert(type(command) == "string", "shell capture command must be a string")
  opts = opts or {}

  local run = {
    command = command,
    cwd = opts.cwd,
    started_at = system.get_time(),
    active = true,
    cancelled = false,
    delivered_bytes = 0,
    truncated = false,
  }

  local function finish(result)
    if run.finished then return end
    run.finished = true
    run.active = false
    result = result or {}
    result.elapsed = math.max(0, system.get_time() - run.started_at)
    result.cancelled = run.cancelled
    result.truncated = run.truncated
    run.result = result
    callback(opts.on_exit, result)
  end

  function run:cancel()
    if self.finished or self.cancelled then return false end
    self.cancelled = true
    self.active = false
    if self.process then pcall(self.process.kill, self.process) end
    if not self.process then finish { code = nil } end
    core.log_quiet("Shell capture cancelled: command_len=%d", #tostring(command or ""))
    return true
  end

  local function deliver(chunk)
    if run.cancelled or not run.active or not chunk or chunk == "" then return end
    local cap = tonumber(opts.max_output_bytes)
    local remaining = cap and math.max(0, cap - run.delivered_bytes) or #chunk
    if #chunk > remaining then run.truncated = true end
    if remaining > 0 then
      local accepted = chunk:sub(1, remaining)
      run.delivered_bytes = run.delivered_bytes + #accepted
      callback(opts.on_output, accepted)
    end
  end

  core.add_thread(function()
    if run.finished then return end
    local proc, start_error
    for _, shell in ipairs(M.capture_shells(opts.shell)) do
      local env = {
        NO_COLOR = "1",
        CLICOLOR = "0",
        TERM = "dumb",
      }
      for key, value in pairs(opts.env or {}) do env[key] = value end
      proc, start_error = process.start(M.capture_args(command, shell), {
        cwd = opts.cwd,
        stdout = process.REDIRECT_PIPE,
        stderr = process.REDIRECT_STDOUT,
        env = env,
      })
      if proc then
        run.shell = shell
        break
      end
      core.log_quiet("Shell capture failed to start %s: %s", tostring(shell), tostring(start_error))
    end

    if run.finished then
      if proc then pcall(proc.kill, proc) end
      return
    end
    if not proc then
      run.active = false
      run.finished = true
      callback(opts.on_error, {
        kind = "start",
        message = tostring(start_error or "could not start shell"),
      })
      return
    end

    run.process = proc
    if run.cancelled then pcall(proc.kill, proc) end
    while proc:running() do
      local chunk = proc:read_stdout(READ_BYTES)
      if chunk and #chunk > 0 then deliver(chunk) else coroutine.yield(POLL_SECONDS) end
    end
    while true do
      local chunk = proc:read_stdout(READ_BYTES)
      if not chunk or chunk == "" then break end
      deliver(chunk)
    end
    local code = proc:returncode()
    if code == nil then code = proc:wait(process.WAIT_DEADLINE) end
    run.process = nil
    finish { code = code }
    core.log_quiet(
      "Shell capture finished shell=%s code=%s elapsed=%.3fs truncated=%s",
      tostring(run.shell), tostring(code), run.result.elapsed, tostring(run.truncated)
    )
  end, run)

  return run
end

return M
