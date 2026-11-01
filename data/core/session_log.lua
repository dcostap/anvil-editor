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

-- Input traces can write many records within one second. Keep their format
-- without repeating the Windows calendar conversion for every record.
local function format_line(self, level, text, source)
  local second = os.time()
  if self.timestamp_second ~= second then
    self.timestamp_second = second
    self.timestamp_text = os.date("%Y-%m-%d %H:%M:%S", second)
  end
  return string.format(
    "%s [%s] %s at %s\n",
    self.timestamp_text, tostring(level), tostring(text), tostring(source or "unknown")
  )
end

local function urgent(level)
  return level == "ERROR" or level == "WARN"
end

function SessionLog:_write_line(line, flush)
  if not self.file then return false end
  if self.bytes > 0 and self.bytes + #line > self.max_file_bytes then
    local rolled = self:_roll()
    if not rolled then return false end
  end
  local written = self.file:write(line)
  if not written then return false end
  self.bytes = self.bytes + #line
  self.pending_bytes = self.pending_bytes + #line
  if flush or self.pending_bytes >= FLUSH_PENDING_BYTES then
    self:flush()
  else
    self:flush_if_due()
  end
  return true
end

function SessionLog:write(level, text, source)
  if not self.file then return false end
  return self:_write_line(format_line(self, level, text, source), urgent(level))
end

function SessionLog:flush()
  if not self.file then return false end
  self.file:flush()
  self.pending_bytes = 0
  self.last_flush = system.get_time()
  return true
end

---Flush lines that have waited for the flush interval.
function SessionLog:flush_if_due()
  if self.pending_bytes > 0 and system.get_time() - self.last_flush >= FLUSH_INTERVAL_SECONDS then
    return self:flush()
  end
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
  if not options.defer_prune then self:_prune() end
  return self
end

-- Background Session Log: a thread writes the file, so a slow disk cannot stop the UI.
-- The UI formats each line, so its timestamp is the time of the call.
-- A warning or an error reaches the disk at once. Other lines reach it within the flush interval.
-- `flush` and `close` wait until the thread has written every earlier line.

local Background = {}
Background.__index = Background

local REPLY_TIMEOUT_SECONDS = 5
local background_count = 0

-- The writer replies `failed` when it cannot write. The log stops, as a direct log stops.
local function stop_on_failure(self, reply)
  if not reply.failed then return false end
  self.input = nil
  self.failed = reply.err or "session log write failed"
  return true
end

local function wait_reply(self, id)
  local deadline = system.get_time() + REPLY_TIMEOUT_SECONDS
  while true do
    local reply = self.reply:first()
    if reply then
      self.reply:pop()
      if reply.path then self.path = reply.path end
      if stop_on_failure(self, reply) then return nil, self.failed end
      if reply.id == id then return reply end
    elseif system.get_time() > deadline then
      return nil, "session log thread did not reply"
    else
      system.sleep(0.001)
    end
  end
end

function Background:write(level, text, source)
  local reply = self.input and self.reply:first()
  if reply and stop_on_failure(self, reply) then self.reply:pop() end
  if not self.input then return false end
  local line = format_line(self, level, text, source)
  if urgent(level) then
    self.input:push({ type = "line", line = line, flush = true })
  else
    self.input:push(line)
  end
  return true
end

function Background:flush()
  if not self.input then return false end
  self.request_id = self.request_id + 1
  self.input:push({ type = "flush", id = self.request_id })
  local reply = wait_reply(self, self.request_id)
  return reply ~= nil and reply.ok
end

-- The thread flushes by itself.
function Background:flush_if_due()
  return true
end

function Background:close()
  if self.input then self.input:push({ type = "close" }) end
  self.input = nil
  local writer = self.thread
  self.thread = nil
  if writer then writer:wait() end
end

local function start_background(root, options)
  local pid = system.get_process_id and system.get_process_id() or 0
  background_count = background_count + 1
  local session_id = options.session_id or string.format(
    "anvil-%s-p%s", os.date("%Y%m%d-%H%M%S"), tostring(pid)
  )
  local channel = string.format("session-log-%s-%d", session_id, background_count)
  local input, reply = thread.get_channel(channel .. "-in"), thread.get_channel(channel .. "-reply")
  input:clear()
  reply:clear()
  local writer, err = thread.create("session-log", function(writer_options)
    return require("core.session_log").serve(writer_options)
  end, {
    root = root, input = channel .. "-in", reply = channel .. "-reply", session_id = session_id,
    max_file_bytes = options.max_file_bytes, max_total_bytes = options.max_total_bytes, now = options.now,
  })
  if not writer then return nil, err end
  local self = setmetatable({
    root = root, session_id = session_id, pid = pid, background = true,
    input = input, reply = reply, thread = writer, request_id = 0,
  }, Background)
  local started, wait_err = wait_reply(self, 0)
  if not started or not started.ok then
    self:close()
    return nil, started and started.err or wait_err
  end
  return self
end

---Run a background writer in its own thread until a `close` message.
function SessionLog.serve(options)
  local input, reply = thread.get_channel(options.input), thread.get_channel(options.reply)
  local logger, err = SessionLog.start(options.root, {
    session_id = options.session_id, max_file_bytes = options.max_file_bytes,
    max_total_bytes = options.max_total_bytes, now = options.now, defer_prune = true,
  })
  reply:push({ id = 0, ok = logger ~= nil, err = err, path = logger and logger.path })
  if not logger then return end
  logger:_prune()
  while true do
    local message = input:first()
    if message == nil then
      if logger.pending_bytes > 0 then
        logger:flush_if_due()
        system.sleep(0.05)
      else
        input:wait()
      end
    else
      input:pop()
      local plain = type(message) == "string"
      if plain or message.type == "line" then
        if not logger:_write_line(plain and message or message.line, not plain and message.flush) then
          reply:push({ failed = true, err = "cannot write " .. tostring(logger.path) })
          logger:close()
          return
        end
      elseif message.type == "flush" then
        reply:push({ id = message.id, ok = logger:flush(), path = logger.path })
      elseif message.type == "close" then
        logger:close()
        return
      end
    end
  end
end

local start = SessionLog.start

---Start a Session Log. `options.background` writes it on a thread.
function SessionLog.start(root, options)
  options = options or {}
  if options.background then return start_background(root, options) end
  return start(root, options)
end

return SessionLog
