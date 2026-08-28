local core = require "core"
local common = require "core.common"
local DirWatch = require "core.dirwatch"
local process = require "core.process"

local project_files = {}
local cache = {}

local WORK_SLICE_SECONDS = 0.002
local WATCH_POLL_SECONDS = 0.02
local WATCH_BATCH_SECONDS = 0.05

local function cooperative_state()
  return { deadline = system.get_time() + WORK_SLICE_SECONDS, checks = 0 }
end

local function yield_if_due(state)
  state.checks = state.checks + 1
  if state.checks < 64 then return end
  state.checks = 0
  if system.get_time() < state.deadline then return end
  local yieldable = coroutine.isyieldable and coroutine.isyieldable()
    or not coroutine.isyieldable and coroutine.running() ~= nil
  if not yieldable then
    state.deadline = system.get_time() + WORK_SLICE_SECONDS
    return
  end
  coroutine.yield(0)
  state.deadline = system.get_time() + WORK_SLICE_SECONDS
end

local function cooperative_sort(values, less)
  local count = #values
  if count < 2 then return values end
  local source, target = values, {}
  local width = 1
  local state = cooperative_state()
  while width < count do
    local start = 1
    while start <= count do
      local left = start
      local left_end = math.min(start + width - 1, count)
      local right = left_end + 1
      local right_end = math.min(start + width * 2 - 1, count)
      local output = start
      while left <= left_end or right <= right_end do
        if right > right_end or (left <= left_end and not less(source[right], source[left])) then
          target[output], left = source[left], left + 1
        else
          target[output], right = source[right], right + 1
        end
        output = output + 1
        yield_if_due(state)
      end
      start = start + width * 2
    end
    source, target = target, source
    width = width * 2
  end
  if source ~= values then
    for i = 1, count do
      values[i] = source[i]
      yield_if_due(state)
    end
  end
  return values
end

local function ripgrep_path()
  if PLATFORM ~= "Windows" then return "rg" end
  local bundled = DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "fuzzy_searcher" .. PATHSEP .. "rg.exe"
  if system.get_file_info(bundled) then return bundled end
  return "rg"
end

function project_files.add_filter_arguments(args, include_ignored)
  if include_ignored then args[#args + 1] = "-u" end
  return args
end

function project_files.scan_command(include_ignored)
  local args = { ripgrep_path(), "--files", "--null", "--debug" }
  project_files.add_filter_arguments(args, include_ignored)
  args[#args + 1] = "."
  return args
end

local function consume_ignore_debug(state, chunk, root)
  local text = state.pending .. tostring(chunk or "")
  local start = 1
  while true do
    local stop = text:find("\n", start, true)
    if not stop then break end
    local line = text:sub(start, stop - 1):gsub("\r$", "")
    local ignored = line:match("ignoring (.-): Ignore%(")
    if ignored then
      ignored = ignored:gsub("^%.[/\\]", "")
      local path = common.is_absolute_path(ignored)
        and common.normalize_path(ignored)
        or common.normalize_path(root .. PATHSEP .. ignored)
      local key = path and common.path_compare_key(path)
      if key then
        if line:find("IgnoreMatch(Hidden)", 1, true) then
          state.hidden_paths[key] = true
        else
          state.paths[key] = true
        end
      end
    end
    start = stop + 1
  end
  state.pending = text:sub(start)
end

local function scan_directories(root, ignored_paths, hidden_paths)
  local directories = { root }
  local pending = { root }
  local searchable = { [common.path_compare_key(root)] = root }
  local pruned_ignored = 0
  local state = cooperative_state()
  while #pending > 0 do
    local directory = table.remove(pending)
    local entries = system.list_dir_info
      and system.list_dir_info(directory, 2147483647, "dir") or nil
    for _, entry in ipairs(entries or {}) do
      local name = entry.name
      if name and name ~= "" and name:sub(1, 1) ~= "." then
        local path = common.normalize_path(directory .. PATHSEP .. name)
        local info = path and system.get_file_info(path)
        local key = path and common.path_compare_key(path)
        if info and info.type == "dir" and not hidden_paths[key] then
          directories[#directories + 1] = path
          if not info.symlink and not ignored_paths[key] then
            searchable[key] = path
            pending[#pending + 1] = path
          elseif ignored_paths[key] then
            pruned_ignored = pruned_ignored + 1
          end
        end
      end
      yield_if_due(state)
    end
  end
  cooperative_sort(directories, function(a, b) return a < b end)
  return directories, searchable, pruned_ignored
end

local function scan(root, include_ignored)
  local proc, start_error = process.start(project_files.scan_command(include_ignored), {
    cwd = root,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    stdin = process.REDIRECT_DISCARD,
  })
  if not proc then return nil, start_error or "could not start ripgrep" end

  local ignore_debug = { pending = "", paths = {}, hidden_paths = {} }
  local debug_done = false
  core.add_thread(function()
    while proc:running() do
      local ok, chunk = pcall(
        proc.stderr.read, proc.stderr, 64 * 1024,
        { scan = 0.001, timeout = WORK_SLICE_SECONDS }
      )
      if ok and chunk then consume_ignore_debug(ignore_debug, chunk, root) end
    end
    local ok, tail = pcall(proc.stderr.read, proc.stderr, "all")
    if ok and tail then consume_ignore_debug(ignore_debug, tail .. "\n", root) end
    debug_done = true
  end)

  local files, pending = {}, ""
  local invalid_windows_paths = 0
  local function add_file(relative)
    if PLATFORM == "Windows" and common.path_has_windows_reserved_filename(relative) then
      invalid_windows_paths = invalid_windows_paths + 1
      return
    end
    files[#files + 1] = {
      relative = relative,
      path = common.normalize_path(root .. PATHSEP .. relative),
    }
  end
  local progress_deadline = system.get_time() + 30
  local state = cooperative_state()
  while true do
    if system.get_time() >= progress_deadline then
      if proc:running() then pcall(function() proc:kill() end) end
      proc:wait(process.WAIT_DEADLINE)
      return nil, "ripgrep file scan timed out"
    end
    local ok, chunk_or_error = pcall(
      proc.stdout.read, proc.stdout, 256 * 1024,
      { scan = 0.001, timeout = WORK_SLICE_SECONDS }
    )
    if ok and chunk_or_error then
      progress_deadline = system.get_time() + 30
      local text = pending .. chunk_or_error
      local start = 1
      while true do
        local stop = text:find("\0", start, true)
        if not stop then break end
        local relative = text:sub(start, stop - 1):gsub("^%.[/\\]", "")
        if relative ~= "" then add_file(relative) end
        start = stop + 1
        yield_if_due(state)
      end
      pending = text:sub(start)
    elseif not ok and not tostring(chunk_or_error):find("timeout expired", 1, true) then
      if proc:running() then pcall(function() proc:kill() end) end
      proc:wait(process.WAIT_DEADLINE)
      return nil, tostring(chunk_or_error)
    elseif not proc:running() then
      break
    end
    coroutine.yield(0.001)
    state.deadline = system.get_time() + WORK_SLICE_SECONDS
  end

  local exit_code = proc:wait(process.WAIT_DEADLINE)
  while not debug_done do coroutine.yield(0) end
  if exit_code ~= 0 and exit_code ~= 1 then
    return nil, "ripgrep exited with code " .. tostring(exit_code)
  end
  if pending ~= "" then
    pending = pending:gsub("^%.[/\\]", "")
    add_file(pending)
  end
  if invalid_windows_paths > 0 then
    core.log_quiet("Project files: skipped %d path(s) with reserved Windows device names",
      invalid_windows_paths)
  end
  cooperative_sort(files, function(a, b) return a.relative < b.relative end)
  local directories, searchable_directories, pruned_ignored = scan_directories(
    root, ignore_debug.paths, ignore_debug.hidden_paths
  )
  core.log_quiet("Project files: indexed %d folders and stopped at %d ignored folder roots",
    #directories, pruned_ignored)
  return files, nil, directories, searchable_directories
end

local function cache_key(root, include_ignored)
  return common.path_compare_key(common.normalize_path(root)) .. (include_ignored and "\1" or "\0")
end

local function get_entry(root, include_ignored)
  root = common.normalize_path(root)
  local key = cache_key(root, include_ignored)
  local entry = cache[key]
  if not entry then
    entry = {
      root = root,
      include_ignored = include_ignored == true,
      subscribers = {},
      watch_generation = 0,
    }
    cache[key] = entry
  end
  return entry
end

local function index_paths(entry, scanned_directories, scanned_searchable_directories)
  local root = entry.root
  entry.paths, entry.directories = {}, {}
  entry.searchable_directories = scanned_searchable_directories or {}
  local root_key = common.path_compare_key(root)
  entry.directories[root_key] = root
  entry.searchable_directories[root_key] = root
  local state = cooperative_state()
  for _, directory in ipairs(scanned_directories or {}) do
    entry.directories[common.path_compare_key(directory)] = directory
    yield_if_due(state)
  end
  for _, file in ipairs(entry.files or {}) do
    entry.paths[common.path_compare_key(file.path)] = true
    local directory = common.dirname(file.path)
    while directory and common.path_belongs_to(directory, root) do
      local key = common.path_compare_key(directory)
      if entry.directories[key] then break end
      entry.directories[key] = directory
      entry.searchable_directories[key] = directory
      if common.path_equals(directory, root) then break end
      directory = common.dirname(directory)
      yield_if_due(state)
    end
    yield_if_due(state)
  end
  entry.directory_list = {}
  for _, directory in pairs(entry.directories) do
    entry.directory_list[#entry.directory_list + 1] = directory
    yield_if_due(state)
  end
  cooperative_sort(entry.directory_list, function(a, b) return a < b end)
end

local function sync_watches(entry)
  local watcher = entry.watcher
  if not watcher then return end
  local mode = watcher.monitor and watcher.monitor.mode and watcher.monitor:mode()
  if mode == "single" then return end
  entry.watched_dirs = entry.watched_dirs or {}
  local wanted = entry.searchable_directories or {}
  local git_info = common.normalize_path(entry.root .. PATHSEP .. ".git" .. PATHSEP .. "info")
  local git_info_stat = system.get_file_info(git_info)
  local git_info_key = git_info_stat and git_info_stat.type == "dir"
    and common.path_compare_key(git_info) or nil
  local state = cooperative_state()
  for key, dir in pairs(wanted) do
    if entry.watcher ~= watcher then return end
    if not entry.watched_dirs[key] then
      watcher:watch(dir)
      entry.watched_dirs[key] = dir
    end
    yield_if_due(state)
  end
  if git_info_key and not entry.watched_dirs[git_info_key] then
    watcher:watch(git_info)
    entry.watched_dirs[git_info_key] = git_info
  end
  for key, dir in pairs(entry.watched_dirs) do
    if entry.watcher ~= watcher then return end
    if not wanted[key] and key ~= git_info_key then
      watcher:unwatch(dir)
      entry.watched_dirs[key] = nil
    end
    yield_if_due(state)
  end
end

function project_files.list(root, opts)
  opts = opts or {}
  root = common.normalize_path(root)
  local entry = get_entry(root, opts.include_ignored == true)
  if entry.files and not opts.refresh then return entry.files, nil, entry.directory_list end
  if entry.scanning then
    while entry.scanning do coroutine.yield(0.005) end
    return entry.files, entry.error, entry.directory_list
  end

  entry.scanning = true
  entry.phase = "scanning"
  local files, err, directories, searchable_directories = scan(root, opts.include_ignored == true)
  if files then
    entry.files = files
    entry.error = nil
    entry.phase = "indexing"
    index_paths(entry, directories, searchable_directories)
    entry.generation = (entry.generation or 0) + 1
    entry.phase = "watching"
    sync_watches(entry)
  else
    entry.error = err
  end
  entry.phase = nil
  entry.scanning = false
  return files, err, entry.directory_list
end

function project_files.contains(root, path, kind)
  root = common.normalize_path(root)
  path = common.normalize_path(path)
  local entry = cache[cache_key(root, false)]
  if not entry or not entry.files then return nil end
  local key = common.path_compare_key(path)
  if kind == "dir" then return entry.searchable_directories[key] ~= nil end
  return entry.paths[key] == true
end

function project_files.directories(root, opts)
  opts = opts or {}
  local entry = cache[cache_key(root, opts.include_ignored == true)]
  return entry and entry.directory_list or nil
end

local function is_ignore_rule(root, path)
  local name = common.basename(path)
  if name == ".gitignore" or name == ".ignore" or name == ".rgignore" then return true end
  local parent = common.dirname(path)
  return name == "exclude" and common.basename(parent) == "info"
    and common.basename(common.dirname(parent)) == ".git"
    and common.path_belongs_to(path, root)
end

function project_files.reconcile(root, paths, opts)
  opts = opts or {}
  root = common.normalize_path(root)
  local entry = get_entry(root, false)
  if not entry.files then
    local files, err = project_files.list(root, { refresh = true })
    return files ~= nil, err, true
  end

  local refresh = opts.force == true
  local state = cooperative_state()
  for key, value in pairs(paths or {}) do
    local path = type(key) == "number" and value or key
    path = path and common.normalize_path(path)
    if path and (common.path_equals(path, root) or common.path_belongs_to(path, root)) then
      local precise = type(value) ~= "table" or value.precise ~= false
      local info = system.get_file_info(path)
      local old_file = entry.paths[common.path_compare_key(path)] == true
      local old_dir = entry.directories[common.path_compare_key(path)] ~= nil
      if is_ignore_rule(root, path) or not precise then
        refresh = true
      elseif old_file then
        if not info or info.type ~= "file" then refresh = true end
      elseif old_dir then
        if not info or info.type ~= "dir" then refresh = true end
      elseif info then
        local parent = common.dirname(path)
        if entry.searchable_directories[common.path_compare_key(parent)] then refresh = true end
      end
    end
    yield_if_due(state)
  end
  if not refresh then return true, nil, false end
  local files, err = project_files.list(root, { refresh = true })
  return files ~= nil, err, true
end

local function notify_subscribers(entry, paths, refreshed, err, previous_membership)
  for id, callback in pairs(entry.subscribers or {}) do
    local event = {
      root = entry.root,
      refreshed = refreshed,
      error = err,
      generation = entry.generation or 0,
      previous_membership = previous_membership,
    }
    core.add_thread(function()
      if entry.subscribers[id] == callback then callback(paths, event) end
    end)
  end
end

local function process_watch_batches(entry, generation)
  while entry.watcher and entry.watch_generation == generation do
    coroutine.yield(WATCH_BATCH_SECONDS)
    if entry.watch_generation ~= generation then return end
    local paths = entry.pending_watch_paths
    entry.pending_watch_paths = {}
    if next(paths) then
      local previous_membership = {}
      local state = cooperative_state()
      for key, value in pairs(paths) do
        local path = type(key) == "number" and value or key
        if path then
          previous_membership[common.normalize_path(path)] =
            project_files.contains(entry.root, path, "file") == true
            or project_files.contains(entry.root, path, "dir") == true
        end
        yield_if_due(state)
      end
      local ok, err, refreshed = project_files.reconcile(entry.root, paths)
      if entry.watch_generation ~= generation then return end
      notify_subscribers(entry, paths, refreshed == true, ok and nil or err,
        previous_membership)
    end
    if not next(entry.pending_watch_paths) then
      entry.watch_processor_running = false
      return
    end
  end
  entry.watch_processor_running = false
end

local function start_watch_processor(entry)
  if entry.watch_processor_running then return end
  entry.watch_processor_running = true
  local generation = entry.watch_generation
  core.add_thread(function() process_watch_batches(entry, generation) end)
end

local function start_watcher(entry)
  if entry.watcher or entry.include_ignored then return end
  local ok, watcher = pcall(DirWatch)
  if not ok then
    core.log_quiet("Project file watcher unavailable for %s: %s", tostring(entry.root), tostring(watcher))
    return
  end
  entry.watcher = watcher
  entry.watched_dirs = {}
  entry.pending_watch_paths = {}
  entry.watch_generation = entry.watch_generation + 1
  local generation = entry.watch_generation
  watcher:watch(entry.root)
  entry.watched_dirs[common.path_compare_key(entry.root)] = entry.root
  core.add_thread(function()
    while entry.watcher == watcher and entry.watch_generation == generation do
      watcher:check(function(_, changed_path, precise)
        changed_path = changed_path and common.normalize_path(changed_path)
        if changed_path and (common.path_equals(changed_path, entry.root)
          or common.path_belongs_to(changed_path, entry.root))
        then
          local existing = entry.pending_watch_paths[changed_path]
          entry.pending_watch_paths[changed_path] = {
            precise = (not existing or existing.precise ~= false) and precise ~= false,
          }
        end
      end, WORK_SLICE_SECONDS, 0)
      if next(entry.pending_watch_paths) then
        start_watch_processor(entry)
      end
      coroutine.yield(WATCH_POLL_SECONDS)
    end
  end)
  if entry.files then core.add_thread(function() sync_watches(entry) end) end
  core.log_quiet("Project file watcher started for %s", tostring(entry.root))
end

local function stop_watcher(entry)
  local watcher = entry.watcher
  if not watcher then return end
  entry.watcher = nil
  entry.watch_generation = entry.watch_generation + 1
  entry.watch_processor_running = false
  entry.pending_watch_paths = {}
  local watched_dirs = entry.watched_dirs or {}
  entry.watched_dirs = {}
  core.add_thread(function()
    local state = cooperative_state()
    for _, dir in pairs(watched_dirs) do
      pcall(watcher.unwatch, watcher, dir)
      yield_if_due(state)
    end
  end)
  core.log_quiet("Project file watcher stopped for %s", tostring(entry.root))
end

function project_files.subscribe(root, id, callback)
  assert(id ~= nil, "Project file subscriber id is required")
  assert(type(callback) == "function", "Project file subscriber callback is required")
  local entry = get_entry(root, false)
  entry.subscribers[id] = callback
  start_watcher(entry)
  return true
end

function project_files.unsubscribe(root, id)
  local entry = cache[cache_key(root, false)]
  if not entry or not entry.subscribers[id] then return false end
  entry.subscribers[id] = nil
  if not next(entry.subscribers) then stop_watcher(entry) end
  return true
end

function project_files.invalidate(root)
  if not root then
    for _, entry in pairs(cache) do stop_watcher(entry) end
    cache = {}
    return
  end
  root = common.normalize_path(root)
  for _, include_ignored in ipairs { false, true } do
    local key = cache_key(root, include_ignored)
    local entry = cache[key]
    if entry and (entry.watcher or next(entry.subscribers or {})) then
      entry.files, entry.paths, entry.directories, entry.searchable_directories,
        entry.directory_list = nil, nil, nil, nil, nil
      entry.error = nil
    else
      cache[key] = nil
    end
  end
end

function project_files.cached(root, opts)
  opts = opts or {}
  local entry = cache[cache_key(root, opts.include_ignored == true)]
  return entry and entry.files or nil
end

function project_files.watch_status(root)
  local entry = cache[cache_key(root, false)]
  if not entry then return { running = false, subscribers = 0, pending = 0 } end
  local subscribers, pending = 0, 0
  for _ in pairs(entry.subscribers or {}) do subscribers = subscribers + 1 end
  for _ in pairs(entry.pending_watch_paths or {}) do pending = pending + 1 end
  return {
    running = entry.watcher ~= nil,
    subscribers = subscribers,
    pending = pending,
    generation = entry.generation or 0,
    phase = entry.phase,
  }
end

return project_files
