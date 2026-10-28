local common = require "core.common"

local SessionLog = {}
SessionLog.__index = SessionLog

local DEFAULT_MAX_FILE_BYTES = 10 * 1024 * 1024
-- Each process writes its own logs, and one launch has several processes. Keep logs by age,
-- so a restart or a burst of failed processes cannot remove the logs of the previous run.
local MAX_AGE_SECONDS = 7 * 24 * 60 * 60
local DEFAULT_MAX_TOTAL_BYTES = 100 * 1024 * 1024
local FLUSH_INTERVAL_SECONDS = 1
local FLUSH_PENDING_BYTES = 64 * 1024

local function join(path, name)
  return path .. PATHSEP .. name
end

-- Matches session logs, their parts, shutdown logs, and native logs.
local function is_log_name(name)
  return name:match("^anvil%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-p%d+.*%.log$") ~= nil
end

local function discover_logs(root)
  local logs = {}
  for _, name in ipairs(system.list_dir(root) or {}) do
    if is_log_name(name) then
      local path = join(root, name)
      local info = system.get_file_info(path)
      if info and info.type == "file" then
        logs[#logs + 1] = {
          name = name,
          path = path,
          size = tonumber(info.size) or 0,
          modified = tonumber(info.modified) or 0,
        }
      end
    end
  end
  table.sort(logs, function(a, b)
    if a.modified ~= b.modified then return a.modified > b.modified end
    return a.name > b.name
  end)
  return logs
end

-- Removes logs older than the age limit, then the oldest logs above the size limit.
-- Windows refuses to remove a log that another running process has open.
local function prune(root, protected_id, max_total_bytes, now)
  local oldest = (now or os.time()) - MAX_AGE_SECONDS
  local function protected(log)
    return log.name == protected_id .. ".log" or log.name:sub(1, #protected_id + 1) == protected_id .. "-"
  end
  local kept, total = {}, 0
  for _, log in ipairs(discover_logs(root)) do
    if protected(log) or log.modified >= oldest then
      kept[#kept + 1] = log
      total = total + log.size
    else
      os.remove(log.path)
    end
  end
  for index = #kept, 1, -1 do
    if total <= max_total_bytes then break end
    local log = kept[index]
    if not protected(log) and os.remove(log.path) then
      total = total - log.size
    end
  end
end

local function part_name(session_id, part)
  if part == 1 then return session_id .. ".log" end
  return string.format("%s-part%02d.log", session_id, part)
end

function SessionLog:_open_part(part)
  self.part = part
  self.path = join(self.root, part_name(self.session_id, part))
  local file, err = io.open(self.path, "ab")
  if not file then return nil, err end
  self.file = file
  local info = system.get_file_info(self.path)
  self.bytes = tonumber(info and info.size) or 0
  self.pending_bytes = 0
  self.last_flush = system.get_time()
  local header = string.format(
    "\n==== Anvil session %s part %d started %s pid=%s ====\n",
    self.session_id, part, os.date("%Y-%m-%d %H:%M:%S"), tostring(self.pid)
  )
  file:write(header)
  file:flush()
  self.bytes = self.bytes + #header
  return true
end

function SessionLog:_roll()
  if self.file then
    self.file:flush()
    self.file:close()
    self.file = nil
  end
  local opened, err = self:_open_part(self.part + 1)
  if not opened then return nil, err end
  self:_prune()
  return true
end

function SessionLog:_prune()
  prune(self.root, self.session_id, self.max_total_bytes, self.now)
end

function SessionLog:write(level, text, source)
  if not self.file then return false end
  -- Input traces can write many records within one second. Keep their format
  -- without repeating the Windows calendar conversion for every record.
  local second = os.time()
  if self.timestamp_second ~= second then
    self.timestamp_second = second
    self.timestamp_text = os.date("%Y-%m-%d %H:%M:%S", second)
  end
  local line = string.format(
    "%s [%s] %s at %s\n",
    self.timestamp_text, tostring(level), tostring(text), tostring(source or "unknown")
  )
  if self.bytes > 0 and self.bytes + #line > self.max_file_bytes then
    local rolled = self:_roll()
    if not rolled then return false end
  end
  local written = self.file:write(line)
  if not written then return false end
  self.bytes = self.bytes + #line
  self.pending_bytes = self.pending_bytes + #line
  local now = system.get_time()
  if level == "ERROR" or level == "WARN"
      or self.pending_bytes >= FLUSH_PENDING_BYTES
      or now - self.last_flush >= FLUSH_INTERVAL_SECONDS then
    self.file:flush()
    self.pending_bytes = 0
    self.last_flush = now
  end
  return true
end

function SessionLog:flush()
  if not self.file then return false end
  self.file:flush()
  self.pending_bytes = 0
  self.last_flush = system.get_time()
  return true
end

function SessionLog:close()
  if not self.file then return end
  self.file:write(string.format(
    "==== Anvil session ended %s ====\n", os.date("%Y-%m-%d %H:%M:%S")
  ))
  self.file:flush()
  self.file:close()
  self.file = nil
  self:_prune()
end

function SessionLog.start(root, options)
  options = options or {}
  local info = system.get_file_info(root)
  if not info then
    local created, err, path = common.mkdirp(root)
    if not created then return nil, string.format("%s: %s", path or root, err or "cannot create log directory") end
  elseif info.type ~= "dir" then
    return nil, "session log path is not a directory"
  end

  local pid = system.get_process_id and system.get_process_id() or 0
  local session_id = options.session_id or string.format(
    "anvil-%s-p%s", os.date("%Y%m%d-%H%M%S"), tostring(pid)
  )
  local self = setmetatable({
    root = root,
    session_id = session_id,
    pid = pid,
    max_file_bytes = options.max_file_bytes or DEFAULT_MAX_FILE_BYTES,
    max_total_bytes = options.max_total_bytes or DEFAULT_MAX_TOTAL_BYTES,
    now = options.now,
    part = 0,
  }, SessionLog)
  local opened, err = self:_open_part(1)
  if not opened then return nil, err end
  self:_prune()
  return self
end

return SessionLog
