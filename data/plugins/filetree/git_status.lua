-- mod-version:3
-- File Tree Git status control plane. Repository-scale parsing and aggregation
-- are owned by the native worker-pool job and immutable snapshot handle.

local common = require "core.common"
local worker_pool = require "core.worker_pool"
local git_backend = require "plugins.git.backend"

local git_status = {}
local Controller = {}
Controller.__index = Controller

local REFRESH_INTERVAL = 2

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function log_quiet(fmt, ...)
  local core = package.loaded.core or rawget(_G, "core")
  if core and core.log_quiet then core.log_quiet(fmt, ...) end
end

local function release_snapshot(snapshot)
  if not (snapshot and snapshot.close) then return end
  local pool = worker_pool.current_system()
  if not pool then snapshot:close(); return end
  local handle = pool:submit {
    kind = "filetree-git-status-snapshot-release",
    priority = "background",
    native = true,
    native_kind = "filetree_git_status_snapshot_release",
    native_payload = { release_git_status_snapshot = snapshot },
  }
  snapshot:close()
  if not handle then log_quiet("File Tree Git snapshot release fell back to the current thread") end
end

local function native_builder(payload, generation, callback)
  local pool = worker_pool.system()
  local delivered = false
  local function deliver(snapshot, err)
    if delivered then
      release_snapshot(snapshot)
      return
    end
    delivered = true
    callback(snapshot, err)
  end
  local handle, err = pool:submit {
    kind = "filetree-git-status-index",
    generation = generation,
    phase = "snapshot-build",
    priority = "interactive",
    native = true,
    native_kind = "filetree_git_status_index",
    native_payload = payload,
    on_result = function(message)
      deliver(message.snapshot or (message.payload and message.payload.snapshot))
    end,
    on_error = function(message) deliver(nil, message.error or "native Git status build failed") end,
    on_cancelled = function() deliver(nil, "cancelled") end,
    on_stale = function(message)
      local snapshot = message.snapshot or (message.payload and message.payload.snapshot)
      release_snapshot(snapshot)
    end,
  }
  if not handle then
    deliver(nil, err or "native Git status worker unavailable")
    return nil
  end
  return {
    cancel = function() return pool:cancel(handle) end,
    handle = handle,
  }
end

local function cancel_job(job)
  if job and job.cancel then pcall(job.cancel, job) end
end

function git_status.new(options)
  options = options or {}
  assert(type(options.root) == "function", "File Tree Git status controller requires root()")
  assert(type(options.presented) == "function", "File Tree Git status controller requires presented()")
  return setmetatable({
    backend = options.backend or git_backend,
    root = options.root,
    presented = options.presented,
    clock = options.clock or now,
    publish = options.publish,
    build_snapshot = options.build_snapshot or native_builder,
    refresh_interval = options.refresh_interval or REFRESH_INTERVAL,
    max_output = options.max_output,
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
end

function Controller:request(reason, force)
  local was_dirty = self.dirty
  self.generation = self.generation + 1
  self.dirty = true
  self.forced = self.forced or not not force
  self.pending_reason = reason or self.pending_reason or "refresh"
  if self.active then
    self.coalesced_requests = self.coalesced_requests + 1
    self:cancel_active("superseded")
  elseif was_dirty then
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
  if phase == "status" then
    self.repository_cache[common.path_compare_key(root)] = nil
    log_quiet("File Tree Git invalidated cached repository after status failure: root=%s", tostring(root))
  end
  self:cancel_active(phase .. "-failed")
  log_quiet("File Tree Git %s failed generation=%d root=%s: %s",
    phase, generation, tostring(root), tostring(err and (err.message or err.kind) or err))
end

function Controller:adopt(snapshot, generation, root, repository_root, reason)
  if not self:is_current(generation, root) then
    release_snapshot(snapshot)
    return
  end
  local previous = self.snapshot
  self.snapshot = snapshot
  self.snapshot_repository_root = repository_root
  self.published_generation = generation
  self.active = false
  self.stage = nil
  self.discovery_job, self.status_job, self.numstat_job, self.native_job = nil, nil, nil, nil
  if previous and previous ~= snapshot then release_snapshot(previous) end
  local summary = snapshot and snapshot.summary and snapshot:summary() or {}
  log_quiet("File Tree Git published generation=%d root=%s status_records=%s numstat_records=%s parent_edges=%s build_ms=%s",
    generation, tostring(root), tostring(summary.status_records), tostring(summary.numstat_records),
    tostring(summary.parent_edges), tostring(summary.build_ms))
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
    self:adopt(snapshot, generation, root, repo.root, reason)
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
  local generation, reason, forced = self.generation, self.pending_reason or "refresh", self.forced
  self.pending_reason, self.dirty, self.forced = nil, false, false
  self.active, self.active_generation, self.active_root = true, generation, root
  self.last_start = self.clock()

  if self.backend.is_enabled and not self.backend.is_enabled() then
    return self:publish_empty(generation, root, "git-disabled")
  end

  local cache_key = common.path_compare_key(root)
  if forced then self.repository_cache[cache_key] = nil end
  local cached = self.repository_cache[cache_key]
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
  if not self.snapshot then return nil end
  local relative = path
  if self.snapshot_repository_root and common.path_belongs_to(path, self.snapshot_repository_root) then
    relative = common.relative_path(self.snapshot_repository_root, path)
  end
  return self.snapshot:lookup(relative:gsub("\\", "/"), is_directory)
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
  release_snapshot(self.snapshot)
  self.snapshot = nil
end

git_status.Controller = Controller
return git_status
