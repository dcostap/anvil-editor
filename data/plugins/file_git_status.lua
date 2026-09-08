-- mod-version:3
-- One Git snapshot per repository for file labels and File Tree views.
local common = require "core.common"
local core = require "core"
local Buffer = require "core.buffer"
local DirWatch = require "core.dirwatch"
local backend = require "plugins.git.backend"
local git_status = require "plugins.git.status_controller"

local Service = {}
Service.__index = Service
local NEGATIVE_MARKER_RETRY = 2

local function root_for_path(path, is_directory)
  path = common.normalize_path(path) or path
  return is_directory and path or common.dirname(path)
end

local function error_key(err)
  if type(err) ~= "table" then return tostring(err or "") end
  return table.concat({
    tostring(err.kind or ""), tostring(err.message or ""), tostring(err.stderr or ""),
  }, "\0")
end

local function is_not_repository_error(err)
  local kind = type(err) == "table" and err.kind or nil
  return kind == "not_in_repository" or kind == "not-repository" or kind == "not_repository"
end

local function marker_probe(path)
  local info = system.get_file_info(path .. PATHSEP .. ".git")
  return info and info.type ~= nil
end

local function parent_directory(path)
  local parent = common.dirname(path)
  if not parent or parent == "" or common.path_equals(parent, path) then return nil end
  return parent
end

local function path_is_under(path, root)
  return common.path_equals(path, root) or common.path_belongs_to(path, root)
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
    marker_probe = options.marker_probe or marker_probe,
    use_marker_scan = options.use_marker_scan == nil and true or options.use_marker_scan,
    is_active = options.is_active or is_active,
    watcher_factory = options.watcher_factory or function() return DirWatch() end,
    publish = options.publish or function() core.redraw = true end,
    build_snapshot = options.build_snapshot,
    aliases = {}, repositories = {}, generation = 0,
    file_lookups = {}, directory_lookups = {}, lookup_count = 0,
    subscribers = setmetatable({}, { __mode = "kv" }),
    subscription_callback_key = {},
    marker_cache = {},
  }, Service)
end

function Service:invalidate_lookups()
  self.file_lookups, self.directory_lookups, self.lookup_count = {}, {}, 0
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

function Service:subscribe(owner, callback)
  -- Owners are weak keys. The callback receives (repository_root, reason, error).
  -- A callback must filter events against its own repository or path.
  assert(type(owner) == "table", "Git status subscription requires a table owner")
  assert(type(callback) == "function", "Git status subscription requires a callback")
  -- Keep the callback alive while a table owner is alive, without making the
  -- service a strong path to an owner captured by that callback.
  rawset(owner, self.subscription_callback_key, callback)
  self.subscribers[owner] = callback
  return callback
end

function Service:unsubscribe(owner)
  if owner ~= nil then
    self.subscribers[owner] = nil
    if type(owner) == "table" then rawset(owner, self.subscription_callback_key, nil) end
  end
end

function Service:notify(root, reason, err)
  for owner, callback in pairs(self.subscribers) do
    local ok, callback_err = pcall(callback, root, reason, err)
    if not ok then
      core.log_quiet("Shared Git subscriber failed for %s: %s", tostring(root), tostring(callback_err))
    end
  end
end

function Service:nearest_marker_root(directory)
  local current = directory
  local visited = {}
  local root
  local now = self.clock()
  while current do
    local key = common.path_compare_key(current)
    if not key then break end
    local cached = self.marker_cache[key]
    visited[#visited + 1] = { key = key, path = current }
    if cached then
      root = cached.root or nil
      if root then break end
      if cached.retry_at and now >= cached.retry_at then
        self.marker_cache[key] = nil
        cached = nil
      end
    end
    if not cached then
      local ok, exists = pcall(self.marker_probe, current)
      if ok and exists then root = current end
      self.marker_cache[key] = {
        path = current,
        root = root,
        retry_at = not root and now + NEGATIVE_MARKER_RETRY or nil,
      }
      if root then break end
    end
    current = parent_directory(current)
  end
  for _, item in ipairs(visited) do
    if root then
      self.marker_cache[item.key] = { path = item.path, root = root }
    else
      local cached = self.marker_cache[item.key]
      if not cached or not cached.retry_at or now >= cached.retry_at then
        self.marker_cache[item.key] = {
          path = item.path, retry_at = now + NEGATIVE_MARKER_RETRY,
        }
      end
    end
  end
  return root
end

function Service:marker_directory(path)
  if not path then return nil end
  path = common.normalize_path(path) or path
  if common.basename(path) == ".git" then return common.dirname(path) end
  return nil
end

function Service:marker_change_directory(path)
  if not path then return nil end
  path = common.normalize_path(path) or path
  local direct = self:marker_directory(path)
  if direct then return direct end
  local marker_token = PATHSEP .. ".git" .. PATHSEP
  local marker_start = path and path:find(marker_token, 1, true)
  if not marker_start then return nil end
  local directory = path:sub(1, marker_start - 1)
  local key = common.path_compare_key(directory)
  local cached = key and self.marker_cache[key]
  if not cached then return nil end
  local ok, exists = pcall(self.marker_probe, directory)
  if not ok then return nil end
  if exists and (not cached.root or not common.path_equals(cached.root, directory)) then
    return directory
  end
  if not exists and cached.root and common.path_equals(cached.root, directory) then
    return directory
  end
  return nil
end

function Service:invalidate_discovery(path, whole_subtree)
  if not path then
    for key, alias in pairs(self.aliases) do
      if alias.job and alias.job.cancel then pcall(alias.job.cancel, alias.job) end
      self.aliases[key] = nil
    end
    self.marker_cache = {}
    return
  end
  path = common.normalize_path(path) or path
  local marker_root = self:marker_change_directory(path)
  local affected = marker_root or path
  if not marker_root and not whole_subtree then
    local info = system.get_file_info(affected)
    if not (info and info.type == "dir") then affected = common.dirname(affected) end
  end
  local affected_key = common.path_compare_key(affected)
  if not affected_key then return end
  for key, cached in pairs(self.marker_cache) do
    if path_is_under(cached.path, affected)
        or (cached.root and path_is_under(cached.root, affected)) then
      self.marker_cache[key] = nil
    end
  end
  for key, alias in pairs(self.aliases) do
    if alias.hint and path_is_under(alias.hint, affected) then
      if alias.job and alias.job.cancel then pcall(alias.job.cancel, alias.job) end
      self.aliases[key] = nil
    end
  end
end

function Service:retry_failed_discovery(path)
  local directory = path and self.root_for_path(path, false)
  local cached = directory and self.marker_cache[common.path_compare_key(directory)]
  local hint = cached and cached.root
  if not hint and directory and not self.use_marker_scan then hint = directory end
  local key = hint and common.path_compare_key(hint)
  local alias = key and self.aliases[key]
  if alias and alias.retry_at then
    self.aliases[key] = nil
  end
end

function Service:invalidate_negative_markers(path)
  local directory = path and self.root_for_path(path, false)
  for key, cached in pairs(self.marker_cache) do
    if not cached.root and (not directory or path_is_under(directory, cached.path)) then
      self.marker_cache[key] = nil
    end
  end
end

function Service:state_for(path, is_directory)
  if self.closed or not path or not common.is_absolute_path(path) then return nil end
  local directory = self.root_for_path(path, is_directory)
  if not directory then return nil end
  local directory_key = common.path_compare_key(directory)
  if not directory_key then return nil end
  local hint
  if self.use_marker_scan then
    local cached = self.marker_cache[directory_key]
    hint = cached and cached.root
    if not hint then hint = self:nearest_marker_root(directory) end
    if not hint then return nil end
  else
    hint = directory
  end
  local key = common.path_compare_key(hint)
  if not key then return nil end
  local alias = self.aliases[key]
  if alias and alias.retry_at and self.clock() >= alias.retry_at then
    self.aliases[key], alias = nil, nil
  end
  if not alias then
    alias = { hint = hint }
    self.aliases[key] = alias
    alias.job = self.backend.repo_for_path_async(hint, function(repo, err)
      if self.closed or self.aliases[key] ~= alias then return end
      alias.job = nil
      if not repo then
        alias.retry_at = self.clock() + 60
        alias.error = err
        alias.not_repository = is_not_repository_error(err)
        if not alias.not_repository and not alias.error_notified then
          alias.error_notified = true
          self:invalidate_lookups()
          self.generation = self.generation + 1
          self.publish(hint)
          self:notify(hint, "discovery", err)
        end
        core.log_quiet("Shared Git discovery failed: root=%s reason=%s", hint, tostring(err and err.kind))
        return
      end
      alias.error, alias.not_repository, alias.error_notified = nil, nil, nil
      repo.root = common.normalize_path(repo.root)
      local repo_key = common.path_compare_key(repo.root)
      local state = self.repositories[repo_key]
      if not state then
        state = {
          repo = repo, last_used = self.clock(), last_refresh = self.clock(),
          has_published = false, error_key = nil,
        }
        state.controller = git_status.new {
          backend = self.backend, repository = repo,
          clock = self.clock, refresh_interval = 0.5,
          build_snapshot = self.build_snapshot,
          publish = function(_, event)
            event = event or {}
            local err_key = event.err and error_key(event.err) or nil
            local transition
            if event.err then
              transition = state.error_key ~= err_key
              state.error_key = err_key
            else
              transition = state.error_key ~= nil or not state.has_published or event.changed == true
              state.error_key = nil
              state.has_published = true
            end
            if transition then
              self:invalidate_lookups()
              self.generation = self.generation + 1
              self.publish(repo.root)
            end
            self:notify(repo.root, event.reason or "refresh", event.err)
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
  local cache = is_directory and self.directory_lookups or self.file_lookups
  local cache_key = common.path_compare_key(path) or path
  local entry = cache[cache_key]
  if not entry then
    local state = self:state_for(path, is_directory)
    -- Do not retain discovery failures or pending discovery. Their retries stay active.
    if not state then
      local hint = self.root_for_path(path, is_directory)
      if self.use_marker_scan then
        local cached = hint and self.marker_cache[common.path_compare_key(hint)]
        hint = cached and cached.root
      end
      local hint_key = hint and common.path_compare_key(hint)
      local alias = hint_key and self.aliases[hint_key]
      if alias and alias.error and not alias.not_repository then
        return { error = alias.error }
      end
      return nil
    end
    local info = state.controller:lookup(path, is_directory)
    local controller_status = state.controller:status()
    if info then
      info = {
        kind = info.kind,
        stat = info.additions ~= nil
          and { additions = info.additions, deletions = info.deletions } or nil,
      }
    elseif controller_status.error then
      info = {}
    end
    if info and controller_status.error then
      info.error = controller_status.error
      info.stale = controller_status.stale
    end
    entry = { state = state, info = info or false }
    if self.lookup_count >= 4096 then self:invalidate_lookups() end
    -- Synchronous discovery can publish status and replace the cache tables.
    cache = is_directory and self.directory_lookups or self.file_lookups
    cache[cache_key] = entry
    self.lookup_count = self.lookup_count + 1
  end
  entry.state.last_used = self.clock()
  local info = entry.info
  if not info then return nil end
  return {
    kind = info.kind,
    stat = info.stat and {
      additions = info.stat.additions,
      deletions = info.stat.deletions,
    } or nil,
    error = info.error,
    stale = info.stale,
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
  local marker_root = self:marker_change_directory(path)
  if marker_root then
    self:invalidate_discovery(path)
  elseif reason == "manual" or reason == "manual-refresh" or reason == "refresh" then
    self:invalidate_discovery(path, true)
  elseif path then
    self:retry_failed_discovery(path)
    if reason == "save" then self:invalidate_negative_markers(path) end
  else
    -- Focus can retry failed discovery, but must not discard positive routes.
    self:invalidate_negative_markers()
    for key, alias in pairs(self.aliases) do
      if alias.retry_at then self.aliases[key] = nil end
    end
  end
end

function Service:filesystem_changed(state, path)
  if path then
    path = common.normalize_path(path)
    if self:marker_change_directory(path) then
      self:invalidate_discovery(path)
      self:mark_dirty(state, "git-marker")
      return
    end
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
  self.marker_cache = {}
  for owner in pairs(self.subscribers) do
    if type(owner) == "table" then rawset(owner, self.subscription_callback_key, nil) end
  end
  self.subscribers = setmetatable({}, { __mode = "kv" })
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
