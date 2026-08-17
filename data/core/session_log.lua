local common = require "core.common"

local SessionLog = {}
SessionLog.__index = SessionLog

local DEFAULT_MAX_FILE_BYTES = 10 * 1024 * 1024
local DEFAULT_MAX_SESSIONS = 20
local DEFAULT_MAX_TOTAL_BYTES = 100 * 1024 * 1024
local FLUSH_INTERVAL_SECONDS = 1
local FLUSH_PENDING_BYTES = 64 * 1024

local function join(path, name)
  return path .. PATHSEP .. name
end

local function session_id_for_name(name)
  if not name:match("^anvil%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-p%d+.*%.log$") then return nil end
  return name:gsub("%-part%d+%.log$", ""):gsub("%.log$", "")
end

local function remove_session(session)
  for _, path in ipairs(session.paths) do os.remove(path) end
end

local function discover_sessions(root)
  local by_id = {}
  for _, name in ipairs(system.list_dir(root) or {}) do
    local id = session_id_for_name(name)
    if id then
      local path = join(root, name)
      local info = system.get_file_info(path)
      if info and info.type == "file" then
        local session = by_id[id]
        if not session then
          session = { id = id, paths = {}, size = 0 }
          by_id[id] = session
        end
        session.paths[#session.paths + 1] = path
        session.size = session.size + (tonumber(info.size) or 0)
      end
    end
  end
  local sessions = {}
  for _, session in pairs(by_id) do sessions[#sessions + 1] = session end
  table.sort(sessions, function(a, b) return a.id > b.id end)
  return sessions
end

local function prune(root, protected_id, max_sessions, max_total_bytes)
  local sessions = discover_sessions(root)
  local kept = {}
  local protected_found = false
  for _, session in ipairs(sessions) do
    if session.id == protected_id then protected_found = true break end
  end
  local other_limit = math.max(0, max_sessions - (protected_found and 1 or 0))
  local other_count = 0
  for _, session in ipairs(sessions) do
    local protected = session.id == protected_id
    local keep = protected or other_count < other_limit
    if keep then
      kept[#kept + 1] = session
      if not protected then other_count = other_count + 1 end
    else
      remove_session(session)
    end
  end

  local total = 0
  for _, session in ipairs(kept) do total = total + session.size end
  for index = #kept, 1, -1 do
    local session = kept[index]
    if total <= max_total_bytes then break end
    if session.id ~= protected_id then
      remove_session(session)
      total = total - session.size
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
  prune(self.root, self.session_id, self.max_sessions, self.max_total_bytes)
  return true
end

function SessionLog:write(level, text, source)
  if not self.file then return false end
  local line = string.format(
    "%s [%s] %s at %s\n",
    os.date("%Y-%m-%d %H:%M:%S"), tostring(level), tostring(text), tostring(source or "unknown")
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
  prune(self.root, self.session_id, self.max_sessions, self.max_total_bytes)
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
    max_sessions = options.max_sessions or DEFAULT_MAX_SESSIONS,
    max_total_bytes = options.max_total_bytes or DEFAULT_MAX_TOTAL_BYTES,
    part = 0,
  }, SessionLog)
  local opened, err = self:_open_part(1)
  if not opened then return nil, err end
  prune(root, session_id, self.max_sessions, self.max_total_bytes)
  return self
end

return SessionLog
