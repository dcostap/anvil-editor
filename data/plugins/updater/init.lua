-- mod-version:3
-- The user accepts each release update. Development executables never update from GitHub.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local json = require "core.json"
local storage = require "core.storage"
local worker_pool = require "core.worker_pool"
local release = require "plugins.updater.release"

config.plugins.updater.config_spec = {
  name = "Updates",
  { label = "Check Automatically", path = "check_automatically", type = "toggle", default = true },
}

local M = { state = "idle", message = "Anvil " .. VERSION }
local busy = { checking = true, starting = true, downloading = true, closing = true }
local directory = USERDIR .. PATHSEP .. "updates"
local check_lock = directory .. PATHSEP .. "check-lock"
local active_attempt

local function ensure_directory()
  local info = system.get_file_info(directory)
  return (info and info.type == "dir") or common.mkdirp(directory)
end

function M.supported()
  if PLATFORM ~= "Windows" then return false, "Release updates are available on Windows." end
  if not rawget(_G, "EMBEDDED_DATADIR") then
    return false, "This is a development build. Use the development build script."
  end
  if not system.is_hosted_surface() then return false, "Restart Anvil without --direct to install updates." end
  return true
end

function M.busy() return busy[M.state] == true end

local function set_state(state, message)
  message = message:gsub("%s+", " "):sub(1, 400)
  if state ~= M.state or message ~= M.message then
    M.state, M.message = state, message
    core.log_quiet("Release update: %s: %s", state, message)
    core.redraw = true
  end
end

local function capture(args, callback)
  local handle, err = worker_pool.named("updater", { worker_count = 1 }):submit {
    kind = "process_capture",
    payload = { command = args, max_output = 1024 * 1024, max_stderr = 8192 },
    on_result = function(message)
      local result = message.payload
      if result.error then callback(nil, result.error.message or result.error.kind)
      elseif result.code ~= 0 then callback(nil, result.stderr ~= "" and result.stderr or "The update command failed.")
      else callback(result.stdout) end
    end,
    on_error = function(message) callback(nil, tostring(message.error or "The update worker failed.")) end,
    on_cancelled = function() callback(nil, "The update check stopped.") end,
  }
  if not handle then callback(nil, tostring(err)) end
end

local function accept(body, err)
  local found
  if body then found, err = release.parse(body, VERSION) end
  M.release = found or nil
  if found then set_state("available", "Anvil " .. found.version .. " is available.")
  elseif found == false then set_state("current", "Anvil " .. VERSION .. " is up to date.")
  else set_state("error", err or "Could not check for updates.") end
end

-- Manual checks always reach GitHub. Background checks share a daily cache across Projects and Windows.
function M.check(automatic)
  if M.busy() then return false end
  local supported, reason = M.supported()
  if not supported then M.release = nil; set_state("unavailable", reason); return false end
  if not ensure_directory() then set_state("error", "Cannot create the update folder."); return false end
  if automatic then
    local cached = storage.load("updater", "check")
    if cached and os.time() - cached.time >= 0 and os.time() - cached.time < 86400 then
      accept(cached.body, cached.error)
      return true
    end
  end
  local info = system.get_file_info(check_lock)
  if info and os.time() - info.modified > 180 then system.rmdir(check_lock) end
  if not system.mkdir(check_lock) then
    if not automatic then set_state("idle", "Another Anvil Window is checking. Try again shortly.") end
    return false
  end
  set_state("checking", "Checking GitHub…")
  capture({ (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\curl.exe", "-q",
    "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
    "--connect-timeout", "10", "--max-time", "30", "--max-filesize", "1048576",
    "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28",
    "-A", "Anvil/" .. VERSION, release.endpoint }, function(body, err)
    storage.save("updater", "check", { time = os.time(), body = body, error = err })
    system.rmdir(check_lock)
    accept(body, err)
  end)
  return true
end

local function read_status(path)
  local file = io.open(path, "rb")
  if not file then return end
  local text = file:read(16384)
  file:close()
  local ok, value = pcall(json.decode, text)
  if ok and type(value) == "table" and type(value.message) == "string" then return value end
end

-- Only the independent helper can close Anvil. The Project keeps reporting its progress until shutdown.
function M.install()
  if not M.supported() or M.busy() or not M.release then return false end
  local found = M.release
  local id = string.format("%d-%.0f", system.get_process_id(), system.get_time() * 1000000)
  local request_file = directory .. PATHSEP .. id .. ".json"
  local update_status = directory .. PATHSEP .. id .. "-status.json"
  local request = {
    executable = EXEFILE:gsub("/", "\\"), userdir = USERDIR, cwd = EXEDIR,
    shell_pid = system.get_window_process_id(), version = found.version, created_at = os.time(),
    url = found.url, sha256 = found.sha256, size = found.size, status = update_status,
  }
  if not ensure_directory() then set_state("error", "Cannot create the update folder."); return false end
  -- The helper also takes a per-executable lock before it downloads or closes anything.
  local file, err = io.open(request_file, "wb")
  if not file then set_state("error", tostring(err)); return false end
  local ok = file:write(json.encode(request))
  local closed = file:close()
  if not ok or not closed then set_state("error", "Cannot save the update request."); return false end
  local attempt, started = {}, system.get_time()
  active_attempt = attempt
  set_state("starting", "Starting update…")
  capture({ (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", DATADIR .. "/tools/updater.ps1",
    "-Mode", "Launch", "-RequestFile", request_file }, function(_, error)
    if error and active_attempt == attempt then
      local status = read_status(update_status)
      active_attempt = nil
      set_state("error", status and status.message or error)
    end
  end)
  core.add_thread(function()
    while active_attempt == attempt do
      local status = read_status(update_status)
      if status then
        set_state(status.state, status.message)
        if status.state == "error" or status.state == "done" then active_attempt = nil end
      elseif system.get_time() - started > 120 then
        active_attempt = nil
        set_state("error", "The update helper did not start. Try again.")
      end
      if active_attempt == attempt and system.get_time() - started > 900 then
        active_attempt = nil
        set_state("error", "The update did not finish. See " .. update_status .. ".log")
      end
      coroutine.yield(0.25)
    end
  end)
  return true
end

function M.open()
  return require("plugins.updater.dialog").open()
end

command.add(function() return PLATFORM == "Windows" end, {
  ["updater:check"] = command.palette(function()
    M.check()
    M.open()
  end, { keywords = { "update", "upgrade", "version", "release", "GitHub" } }),
})

if PLATFORM == "Windows" and not rawget(_G, "RUNNING_LUA_TESTS") then
  core.add_thread(function()
    coroutine.yield(20)
    while true do
      if M.supported() and not M.busy() and system.window_has_focus(core.window)
        and not core.root_panel:modal_input_owner() then
        local error_path = directory .. PATHSEP .. "last-error.json"
        local file = io.open(error_path, "rb")
        if file then
          local text = file:read(16384)
          file:close()
          os.remove(error_path)
          local ok, result = pcall(json.decode, text)
          if ok and type(result) == "table" and type(result.message) == "string" then
            set_state("error", "The update failed. " .. result.message)
            M.open()
          end
        elseif config.plugins.updater.check_automatically then
          M.check(true)
          if M.release and storage.load("updater", "offered") ~= M.release.version then
            storage.save("updater", "offered", M.release.version)
            M.open()
          end
        end
      end
      coroutine.yield(60)
    end
  end)
end

return M
