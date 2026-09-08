-- mod-version:3
-- Shared Git status controller. Repository-scale parsing and aggregation
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
  if not handle then log_quiet("Shared Git snapshot release fell back to the current thread") end
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

local function empty_head_diff_error(err)
  local text = type(err) == "table"
    and (err.stderr or err.message or err.kind)
    or err
  text = tostring(text or ""):lower()
  return text:find("bad revision", 1, true)
    or text:find("unknown revision", 1, true)
    or text:find("ambiguous argument 'head'", 1, true)
    or text:find("invalid object name 'head'", 1, true)
    or text:find("does not have any commits", 1, true)
end

function git_status.new(options)
  options = options or {}
  assert(options.repository and options.repository.root, "Git status controller requires a repository")
  return setmetatable({
    backend = options.backend or git_backend,
    repository = options.repository,
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
    active = false,
    pending_reason = nil,
    last_start = -math.huge,
    coalesced_requests = 0,
    last_error = nil,
    last_error_generation = nil,
    active_reason = nil,
  }, Controller)
end

function Controller:request(reason)
  local was_dirty = self.dirty
  self.generation = self.generation + 1
  self.dirty = true
  self.pending_reason = reason or self.pending_reason or "refresh"
  if self.active then
    self.coalesced_requests = self.coalesced_requests + 1
    self:cancel_active("superseded")
  elseif was_dirty then
    self.coalesced_requests = self.coalesced_requests + 1
  end
  log_quiet("Shared Git request generation=%d root=%s reason=%s",
    self.generation, self.repository.root, tostring(reason))
end

function Controller:cancel_active(reason)
  if not self.active then return false end
  cancel_job(self.status_job)
  cancel_job(self.numstat_job)
  cancel_job(self.native_job)
  self.status_job, self.numstat_job, self.native_job = nil, nil, nil
  self.active = false
  self.stage = nil
  log_quiet("Shared Git cancelled generation=%d reason=%s", self.active_generation or 0, tostring(reason))
  return true
end

function Controller:is_current(generation, root)
  return self.active and self.active_generation == generation
    and common.path_equals(self.repository.root, root)
end

function Controller:finish_failure(generation, root, phase, err)
  if not self:is_current(generation, root) then return end
  self:cancel_active(phase .. "-failed")
  self.last_error = err or { kind = phase .. "_failed", message = "Git status refresh failed" }
  self.last_error_generation = generation
  log_quiet("Shared Git %s failed generation=%d root=%s: %s",
    phase, generation, tostring(root), tostring(err and (err.message or err.kind) or err))
  if self.publish then
    self.publish(nil, {
      generation = generation,
      root = root,
      reason = self.active_reason or "refresh",
      phase = phase,
      err = self.last_error,
      changed = false,
    })
  end
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
  self.last_error = nil
  self.last_error_generation = nil
  self.active = false
  self.stage = nil
  self.status_job, self.numstat_job, self.native_job = nil, nil, nil
  if previous and previous ~= snapshot then release_snapshot(previous) end
  local summary = snapshot and snapshot.summary and snapshot:summary() or {}
  log_quiet("Shared Git published generation=%d root=%s status_records=%s numstat_records=%s parent_edges=%s build_ms=%s",
    generation, tostring(root), tostring(summary.status_records), tostring(summary.numstat_records),
    tostring(summary.parent_edges), tostring(summary.build_ms))
  if self.publish then
    self.publish(snapshot, { generation = generation, root = root, reason = reason, changed = true })
  end
end

function Controller:build(generation, root, repo, status_text, numstat_text, reason)
  if not self:is_current(generation, root) then return end
  if self.snapshot and self.snapshot_repository_root == repo.root
      and self.status_text == status_text and self.numstat_text == numstat_text then
    self.published_generation = generation
    self.last_error = nil
    self.last_error_generation = nil
    self.active, self.stage = false, nil
    self.status_job, self.numstat_job, self.native_job = nil, nil, nil
    if self.publish then
      self.publish(self.snapshot, { generation = generation, root = root, reason = reason, changed = false })
    end
    return
  end
  self.stage = "native-build"
  local payload = {
    repository_root = repo.root,
    status_text = status_text or "",
    numstat_text = numstat_text or "",
    case_insensitive_paths = self.case_insensitive_paths,
  }
  local returned = self.build_snapshot(payload, generation, function(snapshot, err)
    if not snapshot then return self:finish_failure(generation, root, "snapshot-build", err) end
    if self:is_current(generation, root) then
      self.status_text, self.numstat_text = status_text, numstat_text
    end
    self:adopt(snapshot, generation, root, repo.root, reason)
  end)
  if self.active and self.stage == "native-build" then self.native_job = returned end
end

function Controller:start_git(generation, root, repo, reason)
  if not self:is_current(generation, root) then return end
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
    { generation = generation, max_output = self.max_output, optional_locks = false },
    function(result, err)
      if not self:is_current(generation, root) then return end
      if not result then return self:finish_failure(generation, root, "status", err) end
      status_text, status_done = result.stdout or "", true
      complete_if_ready()
    end)
  if self.active and self.stage == "git" then self.status_job = status_job end

  local function start_numstat(revision, unborn_fallback)
    local done = false
    local job = self.backend.run_git(repo,
      { "diff", "--numstat", "--no-renames", "-z", revision, "--" },
      { generation = generation, max_output = self.max_output, optional_locks = false },
      function(result, err)
        done = true
        if not self:is_current(generation, root) then return end
        if result then
          numstat_text = result.stdout or ""
        elseif not unborn_fallback and empty_head_diff_error(err) then
          -- An unborn HEAD has no diff base. Reuse the normal empty-tree
          -- diff so staged new files still receive line counts.
          return start_numstat(self.backend.EMPTY_TREE or git_backend.EMPTY_TREE, true)
        else
          return self:finish_failure(generation, root, "numstat", err)
        end
        numstat_done = true
        complete_if_ready()
      end)
    if not done and self.active and self.stage == "git" then self.numstat_job = job end
  end
  start_numstat("HEAD", false)
end

function Controller:publish_empty(generation, root, reason)
  self:build(generation, root, { root = root }, "", "", reason)
end

function Controller:start()
  local root = self.repository.root
  local generation, reason = self.generation, self.pending_reason or "refresh"
  self.pending_reason, self.dirty = nil, false
  self.active, self.active_generation = true, generation
  self.active_reason = reason
  self.last_start = self.clock()

  if self.backend.is_enabled and not self.backend.is_enabled() then
    return self:publish_empty(generation, root, "git-disabled")
  end

  self:start_git(generation, root, self.repository, reason)
end

function Controller:update()
  if self.active or not self.dirty then return false end
  if self.clock() - self.last_start < self.refresh_interval then return false end
  self:start()
  return true
end

function Controller:lookup(path, is_directory)
  if not self.snapshot then return nil end
  local relative = path
  if self.snapshot_repository_root and common.path_equals(path, self.snapshot_repository_root) then
    relative = ""
  elseif self.snapshot_repository_root and common.path_belongs_to(path, self.snapshot_repository_root) then
    relative = common.relative_path(common.normalize_path(self.snapshot_repository_root), common.normalize_path(path))
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
    error = self.last_error,
    stale = self.snapshot ~= nil and self.last_error ~= nil,
    has_snapshot = self.snapshot ~= nil,
  }
end

function Controller:close()
  self:cancel_active("close")
  release_snapshot(self.snapshot)
  self.snapshot = nil
end

git_status.Controller = Controller
return git_status
