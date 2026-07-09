local common = require "core.common"

local ArtifactSession = {}
ArtifactSession.__index = ArtifactSession

local function normalize(path)
  return path and common.normalize_path(path)
end

function ArtifactSession.new(opts)
  opts = opts or {}
  local base = normalize(assert(opts.base_dir, "artifact session requires base_dir"))
  local pid = tostring(opts.pid or (system and system.get_process_id and system.get_process_id()) or 0)
  local nonce = tostring(opts.nonce or math.floor(((system and system.get_time and system.get_time()) or os.clock()) * 1000000))
  local root = normalize(base .. PATHSEP .. "session-" .. pid .. "-" .. nonce)
  return setmetatable({
    base_dir = base,
    root = root,
    legacy_dirs = opts.legacy_dirs or {},
    initialized = false,
  }, ArtifactSession)
end

function ArtifactSession:initialize()
  if self.initialized then
    common.mkdirp(self.root)
    return { removed_sessions = 0, removed_legacy = 0 }
  end
  local result = { removed_sessions = 0, removed_legacy = 0, failures = 0 }
  common.mkdirp(self.base_dir)
  for _, name in ipairs(system.list_dir(self.base_dir) or {}) do
    local path = normalize(self.base_dir .. PATHSEP .. name)
    if not common.path_equals(path, self.root) then
      local info = system.get_file_info(path)
      if info and info.type == "dir" and tostring(name):match("^session%-") == nil then
        -- Keep non-session directories owned by other features.
      elseif info then
        local ok = common.rm(path, true)
        if ok then result.removed_sessions = result.removed_sessions + 1 else result.failures = result.failures + 1 end
      end
    end
  end
  for _, path in ipairs(self.legacy_dirs) do
    path = normalize(path)
    if path and not common.path_equals(path, self.root) and system.get_file_info(path) then
      local ok = common.rm(path, true)
      if ok then result.removed_legacy = result.removed_legacy + 1 else result.failures = result.failures + 1 end
    end
  end
  common.mkdirp(self.root)
  self.initialized = true
  return result
end

function ArtifactSession:index_dir()
  self:initialize()
  local path = normalize(self.root .. PATHSEP .. "index")
  common.mkdirp(path)
  return path
end

function ArtifactSession:query_dir()
  self:initialize()
  local path = normalize(self.root .. PATHSEP .. "query")
  common.mkdirp(path)
  return path
end

function ArtifactSession:cleanup()
  if not system.get_file_info(self.root) then return true end
  local ok = common.rm(self.root, true)
  return ok and true or false
end

return ArtifactSession
