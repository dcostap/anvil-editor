-- mod-version:3
-- File Tree Git status control plane. Repository-scale parsing is temporarily
-- isolated behind build_lua_snapshot; the native worker replaces that builder.

local common = require "core.common"
local git_backend = require "plugins.git.backend"

local git_status = {}
local Controller = {}
Controller.__index = Controller

local REFRESH_INTERVAL = 2
local MAX_OUTPUT = 16 * 1024 * 1024
local KIND_RANK = {
  deleted = 7,
  added = 6,
  modified = 5,
  renamed = 5,
  copied = 5,
  typechange = 5,
  unmerged = 5,
  untracked = 2,
  ignored = 1,
}
local UNMERGED = { DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true }

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function log_quiet(fmt, ...)
  local core = package.loaded.core or rawget(_G, "core")
  if core and core.log_quiet then core.log_quiet(fmt, ...) end
end

local function stronger(a, b)
  if not a or (KIND_RANK[b] or 0) > (KIND_RANK[a] or 0) then return b end
  return a
end

local function status_kind(xy)
  if xy == "!!" then return "ignored" end
  if xy == "??" then return "untracked" end
  if UNMERGED[xy] or xy:find("U", 1, true) then return "unmerged" end
  if xy:find("R", 1, true) then return "renamed" end
  if xy:find("C", 1, true) then return "copied" end
  if xy:find("D", 1, true) then return "deleted" end
  if xy:find("A", 1, true) then return "added" end
  if xy:find("M", 1, true) then return "modified" end
  if xy:find("T", 1, true) then return "typechange" end
end

local function canonical_rel(path, case_insensitive)
  if type(path) ~= "string" then return nil end
  path = path:gsub("\\", "/"):gsub("^%./+", ""):gsub("/+$", "")
  if path == "" or path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then return nil end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." or part == "" then return nil end
    if part ~= "." then parts[#parts + 1] = part end
  end
  if #parts == 0 then return nil end
  path = table.concat(parts, "/")
  return case_insensitive and path:lower() or path
end

local function parents(rel)
  return function(_, current)
    current = current or rel
    local parent = current:match("^(.*)/[^/]+$")
    return parent, parent
  end, nil, rel
end

local function each_nul(text)
  local offset, length = 1, #(text or "")
  return function()
    if offset > length then return nil end
    local finish = text:find("\0", offset, true)
    local value
    if finish then
      value, offset = text:sub(offset, finish - 1), finish + 1
    else
      value, offset = text:sub(offset), length + 1
    end
    return value
  end
end

local Snapshot = {}
Snapshot.__index = Snapshot

function Snapshot:close()
  if self.closed then return false end
  self.closed = true
  self.exact, self.directories, self.subtrees = nil, nil, nil
  self.stats, self.directory_stats = nil, nil
  return true
end

function Snapshot:summary()
  return {
    repository_root = self.repository_root,
    status_bytes = self.status_bytes,
    numstat_bytes = self.numstat_bytes,
    status_records = self.status_records,
    numstat_records = self.numstat_records,
    parent_edges = self.parent_edges,
    subtree_summaries = self.subtree_summaries,
    rejected_records = self.rejected_records,
    build_ms = self.build_ms,
  }
end

local function stat_values(stat)
  if not stat then return nil, nil end
  return stat.additions, stat.deletions
end

function Snapshot:lookup(path, is_directory)
  if self.closed then return nil end
  local rel = path
  if self.repository_root and type(path) == "string" and common.path_belongs_to(path, self.repository_root) then
    rel = common.relative_path(self.repository_root, path)
  end
  rel = canonical_rel(rel, self.case_insensitive_paths)
  if not rel then return nil end

  local kind = self.exact[rel]
  if is_directory then kind = stronger(kind, self.directories[rel]) end
  local current = rel
  while current do
    kind = stronger(kind, self.subtrees[current])
    current = current:match("^(.*)/[^/]+$")
  end
  local stat = is_directory and self.directory_stats[rel] or self.stats[rel]
  local additions, deletions = stat_values(stat)
  if not kind and additions == nil then return nil end
  return { kind = kind, additions = additions, deletions = deletions }
end

function git_status.build_lua_snapshot(payload)
  payload = payload or {}
  local started = now()
  local exact, directories, subtrees = {}, {}, {}
  local stats, directory_stats = {}, {}
  local status_records, numstat_records, parent_edges = 0, 0, 0
  local subtree_summaries, rejected_records = 0, 0
  local insensitive = not not payload.case_insensitive_paths
  local fields = each_nul(payload.status_text or "")

  while true do
    local field = fields()
    if field == nil then break end
    if field ~= "" then
      local xy, raw_path = field:sub(1, 2), field:sub(4)
      local kind = status_kind(xy)
      local directory_summary = raw_path:match("[/\\]$") ~= nil
      local rel = canonical_rel(raw_path, insensitive)
      if (kind == "renamed" or kind == "copied") then fields() end -- porcelain v1 -z: destination then source
      if kind and rel then
        status_records = status_records + 1
        exact[rel] = stronger(exact[rel], kind)
        if directory_summary and (kind == "ignored" or kind == "untracked") then
          subtrees[rel] = stronger(subtrees[rel], kind)
          subtree_summaries = subtree_summaries + 1
        end
        for parent in parents(rel) do
          directories[parent] = stronger(directories[parent], kind)
          parent_edges = parent_edges + 1
        end
      else
        rejected_records = rejected_records + 1
      end
    end
  end

  fields = each_nul(payload.numstat_text or "")
  while true do
    local field = fields()
    if field == nil then break end
    if field ~= "" then
      local added_text, deleted_text, raw_path = field:match("^([^\t]*)\t([^\t]*)\t(.*)$")
      if raw_path == "" then
        fields() -- old path
        raw_path = fields() -- new path
      end
      local additions, deletions = tonumber(added_text), tonumber(deleted_text)
      local rel = canonical_rel(raw_path, insensitive)
      if additions and deletions and rel then
        numstat_records = numstat_records + 1
        stats[rel] = { additions = additions, deletions = deletions }
        for parent in parents(rel) do
          local total = directory_stats[parent]
          if not total then total = { additions = 0, deletions = 0 }; directory_stats[parent] = total end
          total.additions = total.additions + additions
          total.deletions = total.deletions + deletions
          parent_edges = parent_edges + 1
        end
      else
        rejected_records = rejected_records + 1
      end
    end
  end

  return setmetatable({
    repository_root = payload.repository_root and common.normalize_path(payload.repository_root),
    case_insensitive_paths = insensitive,
    exact = exact,
    directories = directories,
    subtrees = subtrees,
    stats = stats,
    directory_stats = directory_stats,
    status_bytes = #(payload.status_text or ""),
    numstat_bytes = #(payload.numstat_text or ""),
    status_records = status_records,
    numstat_records = numstat_records,
    parent_edges = parent_edges,
    subtree_summaries = subtree_summaries,
    rejected_records = rejected_records,
    build_ms = (now() - started) * 1000,
  }, Snapshot)
end

local function default_builder(payload, _, callback)
  local ok, snapshot = pcall(git_status.build_lua_snapshot, payload)
  if ok then callback(snapshot) else callback(nil, snapshot) end
end

local function cancel_job(job)
  if job and job.cancel then pcall(job.cancel, job) end
end

function git_status.new(options)
  options = options or {}
  assert(type(options.root) == "function", "File Tree Git status controller requires root()")
  assert(type(options.presented) == "function", "File Tree Git status controller requires presented()")
  local self = setmetatable({
    backend = options.backend or git_backend,
    root = options.root,
    presented = options.presented,
    clock = options.clock or now,
    publish = options.publish,
    build_snapshot = options.build_snapshot or default_builder,
    refresh_interval = options.refresh_interval or REFRESH_INTERVAL,
    max_output = options.max_output or MAX_OUTPUT,
    case_insensitive_paths = options.case_insensitive_paths ~= nil
      and options.case_insensitive_paths or PLATFORM == "Windows",
    generation = 0,
    published_generation = 0,
    dirty = false,
    forced = false,
    active = false,
    pending_reason = nil,
    last_start = -math.huge,
    repository_cache = {},
    coalesced_requests = 0,
    was_presented = false,
  }, Controller)
  return self
end

function Controller:request(reason, force)
  self.generation = self.generation + 1
  self.dirty = true
  self.forced = self.forced or not not force
  self.pending_reason = reason or self.pending_reason or "refresh"
  if self.active then
    self.coalesced_requests = self.coalesced_requests + 1
    self:cancel_active("superseded")
  elseif self.dirty and self.pending_reason ~= reason then
    self.coalesced_requests = self.coalesced_requests + 1
  end
  log_quiet("File Tree Git request generation=%d root=%s reason=%s forced=%s",
    self.generation, tostring(self.root()), tostring(reason), tostring(force == true))
end

function Controller:cancel_active(reason)
  if not self.active then return false end
  cancel_job(self.discovery_job)
  cancel_job(self.status_job)
  cancel_job(self.numstat_job)
  cancel_job(self.native_job)
  self.discovery_job, self.status_job, self.numstat_job, self.native_job = nil, nil, nil, nil
  self.active = false
  self.stage = nil
  log_quiet("File Tree Git cancelled generation=%d reason=%s", self.active_generation or 0, tostring(reason))
  return true
end

function Controller:is_current(generation, root)
  return self.active and self.active_generation == generation
    and common.path_equals(self.active_root, root)
    and common.path_equals(self.root(), root)
    and self.presented()
end

function Controller:finish_failure(generation, root, phase, err)
  if not self:is_current(generation, root) then return end
  self:cancel_active(phase .. "-failed")
  log_quiet("File Tree Git %s failed generation=%d root=%s: %s",
    phase, generation, tostring(root), tostring(err and (err.message or err.kind) or err))
end

function Controller:adopt(snapshot, generation, root, reason)
  if not self:is_current(generation, root) then
    if snapshot and snapshot.close then snapshot:close() end
    return
  end
  local previous = self.snapshot
  self.snapshot = snapshot
  self.published_generation = generation
  self.active = false
  self.stage = nil
  self.discovery_job, self.status_job, self.numstat_job, self.native_job = nil, nil, nil, nil
  if previous and previous ~= snapshot and previous.close then previous:close() end
  local summary = snapshot and snapshot.summary and snapshot:summary() or {}
  log_quiet("File Tree Git published generation=%d root=%s status_records=%s numstat_records=%s build_ms=%s",
    generation, tostring(root), tostring(summary.status_records), tostring(summary.numstat_records), tostring(summary.build_ms))
  if self.publish then self.publish(snapshot, { generation = generation, root = root, reason = reason }) end
end

function Controller:build(generation, root, repo, status_text, numstat_text, reason)
  if not self:is_current(generation, root) then return end
  self.stage = "native-build"
  local payload = {
    repository_root = repo.root,
    status_text = status_text or "",
    numstat_text = numstat_text or "",
    case_insensitive_paths = self.case_insensitive_paths,
  }
  local returned = self.build_snapshot(payload, generation, function(snapshot, err)
    if not snapshot then return self:finish_failure(generation, root, "snapshot-build", err) end
    self:adopt(snapshot, generation, root, reason)
  end)
  if self.active and self.stage == "native-build" then self.native_job = returned end
end

function Controller:start_git(generation, root, repo, reason)
  if not self:is_current(generation, root) then return end
  self.repository_cache[common.path_compare_key(root)] = repo
  self.stage = "git"
  local status_done, numstat_done = false, false
  local status_text, numstat_text = nil, ""
  local function complete_if_ready()
    if status_done and numstat_done and self:is_current(generation, root) then
      self:build(generation, root, repo, status_text, numstat_text, reason)
    end
  end
  local status_job = self.backend.run_git(repo,
    { "status", "--porcelain=v1", "--ignored", "--untracked-files=normal", "-z" },
    { generation = generation, max_output = self.max_output },
    function(result, err)
      if not self:is_current(generation, root) then return end
      if not result then return self:finish_failure(generation, root, "status", err) end
      status_text, status_done = result.stdout or "", true
      complete_if_ready()
    end)
  if self.active and self.stage == "git" then self.status_job = status_job end

  local numstat_job = self.backend.run_git(repo,
    { "diff", "--numstat", "--no-renames", "-z", "HEAD", "--" },
    { generation = generation, max_output = self.max_output },
    function(result, err)
      if not self:is_current(generation, root) then return end
      if result then
        numstat_text = result.stdout or ""
      else
        numstat_text = ""
        log_quiet("File Tree Git numstat failed generation=%d root=%s: %s",
          generation, tostring(root), tostring(err and (err.message or err.kind) or err))
      end
      numstat_done = true
      complete_if_ready()
    end)
  if self.active and self.stage == "git" then self.numstat_job = numstat_job end
end

function Controller:publish_empty(generation, root, reason)
  self:build(generation, root, { root = root }, "", "", reason)
end

function Controller:start()
  local root = self.root()
  if not root then return end
  root = common.normalize_path(root)
  local generation, reason = self.generation, self.pending_reason or "refresh"
  self.pending_reason, self.dirty, self.forced = nil, false, false
  self.active, self.active_generation, self.active_root = true, generation, root
  self.last_start = self.clock()

  if self.backend.is_enabled and not self.backend.is_enabled() then
    return self:publish_empty(generation, root, "git-disabled")
  end

  local cached = self.repository_cache[common.path_compare_key(root)]
  if cached then return self:start_git(generation, root, cached, reason) end

  self.stage = "repository-discovery"
  log_quiet("File Tree Git repository discovery generation=%d root=%s", generation, root)
  local returned = self.backend.repo_for_path_async(root, function(repo, err)
    if not self:is_current(generation, root) then return end
    if not repo then
      if err and (err.kind == "not_in_repository" or err.kind == "disabled") then
        return self:publish_empty(generation, root, err.kind)
      end
      return self:finish_failure(generation, root, "repository-discovery", err)
    end
    self:start_git(generation, root, repo, reason)
  end)
  if self.active and self.stage == "repository-discovery" then self.discovery_job = returned end
end

function Controller:update()
  local presented = not not self.presented()
  if not presented then
    if self.active then
      self.dirty = true
      self.generation = self.generation + 1
      self:cancel_active("hidden")
    end
    if self.dirty and self.was_presented then
      log_quiet("File Tree Git deferred while hidden root=%s", tostring(self.root()))
    end
    self.was_presented = false
    return false
  end
  self.was_presented = true
  if self.active or not self.dirty then return false end
  if not self.forced and self.clock() - self.last_start < self.refresh_interval then return false end
  self:start()
  return true
end

function Controller:lookup(path, is_directory)
  return self.snapshot and self.snapshot:lookup(path, is_directory) or nil
end

function Controller:status()
  return {
    generation = self.generation,
    published_generation = self.published_generation,
    dirty = self.dirty,
    active = self.active,
    stage = self.stage,
    coalesced_requests = self.coalesced_requests,
  }
end

function Controller:close()
  self:cancel_active("close")
  if self.snapshot and self.snapshot.close then self.snapshot:close() end
  self.snapshot = nil
end

git_status.Controller = Controller
return git_status
