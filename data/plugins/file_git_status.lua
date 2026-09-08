-- mod-version:3
-- One Git snapshot per repository for file labels and File Tree views.
local common = require "core.common"
local core = require "core"
local Buffer = require "core.buffer"
local DirWatch = require "core.dirwatch"
local project_paths = require "core.project_paths"
local backend = require "plugins.git.backend"
local git_status = require "plugins.git.status_controller"

local Service = {}
Service.__index = Service

local function root_for_path(path, is_directory)
  local resolved = project_paths.resolve(path)
  return resolved and resolved.entry.path or (is_directory and path or common.dirname(path))
end

local function is_active(root)
  for _, project in ipairs(core.projects or {}) do
    if common.path_equals(project.path, root) or common.path_belongs_to(project.path, root)
        or common.path_belongs_to(root, project.path) then
      return true
    end
  end
  for _, buffer in ipairs(core.buffers or {}) do
    if buffer.abs_filename and common.path_belongs_to(buffer.abs_filename, root) then return true end
  end
  return false
end

function Service.new(options)
  options = options or {}
  return setmetatable({
    backend = options.backend or backend,
    clock = options.clock or system.get_time,
    root_for_path = options.root_for_path or root_for_path,
    is_active = options.is_active or is_active,
    watcher_factory = options.watcher_factory or function() return DirWatch() end,
    publish = options.publish or function() core.redraw = true end,
    build_snapshot = options.build_snapshot,
    aliases = {}, repositories = {}, generation = 0,
    file_lookups = {}, directory_lookups = {}, lookup_count = 0,
  }, Service)
end

function Service:invalidate_lookups()
  self.file_lookups, self.directory_lookups, self.lookup_count = {}, {}, 0
end

local function check_lookup_routing(self)
  local generation = project_paths.generation()
  local projects = core.projects or {}
  local previous = self.lookup_project_paths
  local changed = self.lookup_project_generation ~= generation or not previous or #previous ~= #projects
  if not changed then
    for i, project in ipairs(projects) do
      if previous[i] ~= project.path then changed = true; break end
    end
  end
  if changed then
    self:invalidate_lookups()
    self.lookup_project_generation = generation
    self.lookup_project_paths = {}
    for i, project in ipairs(projects) do self.lookup_project_paths[i] = project.path end
  end
end

local function read_line(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local line = file:read("*l")
  file:close()
  return line
end

function Service:watch_repository(state)
  local root = state.repo.root
  state.watcher = self.watcher_factory()
  state.watch_paths = { root }
  -- Worktrees keep their index outside the working directory.
  local marker = read_line(root .. PATHSEP .. ".git")
  local git_dir = marker and marker:match("^gitdir: (.+)")
  if git_dir then
    if not common.is_absolute_path(git_dir) then git_dir = root .. PATHSEP .. git_dir end
    git_dir = common.normalize_path(git_dir)
    state.watch_paths[#state.watch_paths+1] = git_dir
    local shared = read_line(git_dir .. PATHSEP .. "commondir")
    if shared then
      if not common.is_absolute_path(shared) then shared = git_dir .. PATHSEP .. shared end
      state.watch_paths[#state.watch_paths+1] = common.normalize_path(shared)
    end
  end
  for _, path in ipairs(state.watch_paths) do state.watcher:watch(path) end
end

function Service:mark_dirty(state, reason)
  self:invalidate_lookups()
  if not state.dirty then state.due = self.clock() + 0.2 end
  state.dirty, state.reason = true, reason
end

function Service:state_for(path, is_directory)
  if self.closed or not path or not common.is_absolute_path(path) then return nil end
  local hint = self.root_for_path(path, is_directory)
  local key = common.path_compare_key(hint)
  local alias = self.aliases[key]
  if alias and alias.retry_at and self.clock() >= alias.retry_at then
    self.aliases[key], alias = nil, nil
  end
  if not alias then
    alias = {}
    self.aliases[key] = alias
    alias.job = self.backend.repo_for_path_async(hint, function(repo, err)
      if self.closed or self.aliases[key] ~= alias then return end
      alias.job = nil
      if not repo then
        alias.retry_at = self.clock() + 60
        core.log_quiet("Shared Git discovery failed: root=%s reason=%s", hint, tostring(err and err.kind))
        return
      end
      repo.root = common.normalize_path(repo.root)
      local repo_key = common.path_compare_key(repo.root)
      local state = self.repositories[repo_key]
      if not state then
        state = { repo = repo, last_used = self.clock(), last_refresh = self.clock() }
        state.controller = git_status.new {
          backend = self.backend, repository = repo,
          clock = self.clock, refresh_interval = 0.5,
          build_snapshot = self.build_snapshot,
          publish = function()
            self:invalidate_lookups()
            self.generation = self.generation + 1
            self.publish(repo.root)
          end,
        }
        self.repositories[repo_key] = state
        self:watch_repository(state)
        self:mark_dirty(state, "initial")
        core.log_quiet("Shared Git repository opened: root=%s", repo.root)
      end
      alias.state = state
    end)
  end
  local state = alias.state
  if state then state.last_used = self.clock() end
  return state
end

function Service:lookup(path, is_directory)
  if self.closed or not path then return nil end
  check_lookup_routing(self)
  local cache = is_directory and self.directory_lookups or self.file_lookups
  local entry = cache[path]
  if not entry then
    local state = self:state_for(path, is_directory)
    -- Do not retain discovery failures or pending discovery. Their retries stay active.
    if not state then return nil end
    entry = { state = state, info = state.controller:lookup(path, is_directory) or false }
    if self.lookup_count >= 4096 then self:invalidate_lookups() end
    -- Synchronous discovery can publish status and replace the cache tables.
    cache = is_directory and self.directory_lookups or self.file_lookups
    cache[path] = entry
    self.lookup_count = self.lookup_count + 1
  end
  entry.state.last_used = self.clock()
  local info = entry.info
  if not info then return nil end
  return {
    kind = info.kind,
    stat = info.additions ~= nil and { additions = info.additions, deletions = info.deletions } or nil,
  }
end

function Service:request(path, reason)
  if self.closed then return end
  self:invalidate_lookups()
  for _, state in pairs(self.repositories) do
    if not path or common.path_equals(path, state.repo.root) or common.path_belongs_to(path, state.repo.root)
        or common.path_belongs_to(state.repo.root, path) then
      self:mark_dirty(state, reason or "refresh")
    end
  end
  -- Retry failed discovery after a save, manual refresh, or focus change.
  for key, alias in pairs(self.aliases) do
    if alias.retry_at then self.aliases[key] = nil end
  end
end

function Service:filesystem_changed(state, path)
  if path then
    path = common.normalize_path(path)
    local relative = common.relative_path(state.repo.root, path):gsub("\\", "/")
    local git_path = relative:match("^%.git/(.*)")
    for i = 2, #state.watch_paths do
      if common.path_belongs_to(path, state.watch_paths[i]) then
        git_path = common.relative_path(state.watch_paths[i], path):gsub("\\", "/")
        break
      end
    end
    if git_path then
      if git_path ~= "HEAD" and git_path ~= "index" and git_path ~= "packed-refs"
          and git_path ~= "config" and not git_path:match("^refs/") then return end
    else
      local info = state.controller:lookup(path, false)
      if info and info.kind == "ignored" then return end
    end
  end
  self:mark_dirty(state, "filesystem")
end

function Service:release(key, state)
  self:invalidate_lookups()
  state.controller:close()
  for _, path in ipairs(state.watch_paths) do state.watcher:unwatch(path) end
  self.repositories[key] = nil
  for alias_key, alias in pairs(self.aliases) do
    if alias.state == state then self.aliases[alias_key] = nil end
  end
  core.log_quiet("Shared Git repository closed: root=%s", state.repo.root)
end

function Service:update()
  if self.closed then return end
  local now = self.clock()
  for key, state in pairs(self.repositories) do
    if now - state.last_used > 120 and not self.is_active(state.repo.root) then
      self:release(key, state)
    else
      local ok, err = pcall(function()
        state.watcher:check(function(dir, leaf) self:filesystem_changed(state, leaf or dir) end)
      end)
      if not ok and not state.watch_error then
        state.watch_error = true
        core.log_quiet("Shared Git watch failed; periodic checks remain active: %s", tostring(err))
      end
      local controller = state.controller
      if not controller.active and now - state.last_refresh >= 60 and not state.dirty then
        self:mark_dirty(state, "periodic")
      end
      if state.dirty and not controller.active and now >= state.due then
        state.dirty = false
        state.last_refresh = now
        controller:request(state.reason)
      end
      controller:update()
    end
  end
end

function Service:close()
  self.closed = true
  for _, alias in pairs(self.aliases) do
    if alias.job and alias.job.cancel then alias.job:cancel() end
  end
  for key, state in pairs(self.repositories) do self:release(key, state) end
  self.aliases = {}
end

local service = Service.new()
core.add_thread(function()
  while not service.closed do
    service:update()
    coroutine.yield(0.2)
  end
end)

local save = Buffer.save
function Buffer:save(...)
  local result = save(self, ...)
  if self.abs_filename then service:request(self.abs_filename, "save") end
  return result
end

local on_event = core.on_event
function core.on_event(event, ...)
  local result = on_event(event, ...)
  if event == "focusgained" then service:request(nil, "focus") end
  return result
end

return service
