local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local DirWatch = require "core.dirwatch"
local registry = require "core.treesitter.registry"
local outline = require "core.treesitter.outline"
local worker_pool = require "core.worker_pool"
local fuzzy_ok, native_fuzzy = pcall(require, "fuzzy")
if not fuzzy_ok then native_fuzzy = nil end
local project_native_ok, project_native = pcall(require, "worker_pool_native")
if not project_native_ok then project_native = nil end

local symbol_index = {}

local function project_paths_module()
  return package.loaded["core.project_paths"] or project_paths
end

local DEFAULT_PARSE_TIMEOUT_MS = 1000
local DEFAULT_SCAN_YIELD_FILES = 4
local DEFAULT_QUERY_LIMIT = 200
local DEFAULT_REFRESH_AFTER_SECONDS = 5
local DEFAULT_MATCH_LIMIT = 50000
local DEFAULT_MAX_CAPTURES = 50000
local DEFAULT_QUERY_TIMEOUT_MS = 20
local DEFAULT_PROJECT_USAGE_CAP = 750000
local DEFAULT_SYNC_QUERY_ITEM_LIMIT = 5000
local MAX_FILE_BYTES = 2 * 1024 * 1024

local indexes = {}
local open_documents = setmetatable({}, { __mode = "v" })

local function log_quiet(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function elapsed_ms(started)
  return (now() - started) * 1000
end

local function diagnostics_ui(index)
  index.diagnostics = index.diagnostics or {}
  index.diagnostics.ui = index.diagnostics.ui or {}
  return index.diagnostics.ui
end

local function add_ui_metric(index, key, value)
  local ui = diagnostics_ui(index)
  ui[key] = (ui[key] or 0) + (tonumber(value) or 0)
end

local function inc_ui_metric(index, key, amount)
  local ui = diagnostics_ui(index)
  ui[key] = (ui[key] or 0) + (amount or 1)
end

local function max_ui_metric(index, key, value)
  local ui = diagnostics_ui(index)
  value = tonumber(value) or 0
  if value > (ui[key] or 0) then ui[key] = value end
end

local function safe_yield(wait)
  if coroutine.isyieldable and coroutine.isyieldable() then
    coroutine.yield(wait)
    return true
  end
  return false
end

local function normalize_root(root)
  if type(root) == "table" and root.path then root = root.path end
  if not root or root == "" then
    local project = core.root_project and core.root_project()
    root = project and project.path or system.absolute_path(".")
  end
  return common.normalize_path(root)
end

local function new_index(root)
  return {
    root = root,
    generation = 0,
    status = "idle",
    symbol_status = "idle",
    usage_status = "idle",
    symbols = {},
    usages_by_name = {},
    usage_count = 0,
    usage_truncated = false,
    usage_truncated_reason = nil,
    by_path = {},
    open_docs = {},
    open_doc_jobs = {},
    pending_reindex_paths = {},
    pending_reindex_dirs = {},
    watcher = nil,
    watched_dirs = {},
    watch_generation = 0,
    watch_running = false,
    files_total = 0,
    files_scanned = 0,
    files_indexed = 0,
    reason = nil,
    started_at = nil,
    finished_at = nil,
    worker_handle = nil,
    worker_run = nil,
    worker_seen_paths = nil,
    project_paths_generation = nil,
    overlay_generation = 0,
    combined_symbols_cache = {},
    diagnostics = { ui = {} },
    completed_runs = {},
    project_path_metadata_cache = {},
    project_path_metadata_cache_generation = nil,
  }
end

local function index_for_root(root)
  root = normalize_root(root)
  local index = indexes[root]
  if not index then
    index = new_index(root)
    indexes[root] = index
  end
  return index
end

local function invalidate_combined_symbols_cache(index)
  if index then index.combined_symbols_cache = {} end
end

local function bump_overlay_generation(index)
  if not index then return end
  index.overlay_generation = (index.overlay_generation or 0) + 1
  invalidate_combined_symbols_cache(index)
end

local function usage_query_kind(language)
  local sources = language and language.query_sources or {}
  if sources.usages then return "usages" end
  if sources.locals then return "locals" end
end

local function effective_query_limit(language, prefix, name, default)
  local value = language and language[prefix .. "_" .. name]
  if value == nil and prefix == "usages" then value = language and language["locals_" .. name] end
  return value or default
end

local function copy_item(item)
  local copy = {}
  for key, value in pairs(item or {}) do copy[key] = value end
  return copy
end

local function project_path_allows(path, kind)
  return project_paths_module().rank_penalty(path, kind) ~= math.huge
end

local function cached_project_path_metadata(index, path, kind)
  if not (index and path) then return nil end
  local generation = project_paths_module().generation()
  if index.project_path_metadata_cache_generation ~= generation then
    index.project_path_metadata_cache = {}
    index.project_path_metadata_cache_generation = generation
  end
  local cache = index.project_path_metadata_cache
  local key = tostring(kind or "") .. "\0" .. path
  local metadata = cache[key]
  if metadata then
    inc_ui_metric(index, "project_path_metadata_cache_hits", 1)
    return metadata
  end

  metadata = {
    file = common.relative_path(index.root, path):gsub("\\", "/"),
  }
  metadata.relpath = metadata.file

  local paths = project_paths_module()
  if paths.resolve(path) then
    local display = paths.display_path(path, { kind = kind })
    if display then
      metadata.display_file = display.text
      metadata.file = display.text
      metadata.relpath = display.text
      metadata.root_label = display.root_label
      metadata.root_role = display.root_role
      metadata.root_id = display.root_id
      metadata.prefix_span = display.prefix_span
      metadata.rank_penalty = display.rank_penalty
    end
  end

  cache[key] = metadata
  inc_ui_metric(index, "project_path_metadata_cache_misses", 1)
  return metadata
end

local function refresh_project_path_metadata(index, item, kind)
  if not (index and item and item.path) then return item end
  local metadata = cached_project_path_metadata(index, item.path, kind)
  if not metadata then return item end
  item.file = metadata.file
  item.relpath = metadata.relpath
  item.display_file = metadata.display_file
  item.root_label = metadata.root_label
  item.root_role = metadata.root_role
  item.root_id = metadata.root_id
  item.prefix_span = metadata.prefix_span
  item.rank_penalty = metadata.rank_penalty
  return item
end


local function symbol_less(a, b)
  local af, bf = tostring(a.relpath or a.path or ""), tostring(b.relpath or b.path or "")
  if af ~= bf then return af < bf end
  if (a.start_line or 0) ~= (b.start_line or 0) then return (a.start_line or 0) < (b.start_line or 0) end
  return tostring(a.name or "") < tostring(b.name or "")
end

local function usage_less(a, b)
  local af, bf = tostring(a.relpath or a.path or ""), tostring(b.relpath or b.path or "")
  if af ~= bf then return af < bf end
  if (a.start_line or 0) ~= (b.start_line or 0) then return (a.start_line or 0) < (b.start_line or 0) end
  if (a.start_col or 0) ~= (b.start_col or 0) then return (a.start_col or 0) < (b.start_col or 0) end
  return tostring(a.capture or "") < tostring(b.capture or "")
end

local function sort_symbols(symbols)
  table.sort(symbols, symbol_less)
end

local function sort_usages(usages)
  table.sort(usages, usage_less)
end

local function drain_pending_reindexes(index)
  if not index or index.status == "indexing" then return false end
  local drained = false
  local pending_dirs = index.pending_reindex_dirs
  if pending_dirs and next(pending_dirs) ~= nil then
    index.pending_reindex_dirs = {}
    drained = true
    local dirs, force = {}, false
    for dir, pending in pairs(pending_dirs) do
      dirs[#dirs + 1] = dir
      if type(pending) == "table" and pending.force then force = true end
    end
    if symbol_index.mark_directories_dirty then
      symbol_index.mark_directories_dirty(dirs, "queued-during-indexing", { force = force })
    end
  end

  local pending = index.pending_reindex_paths
  if pending and next(pending) ~= nil then
    index.pending_reindex_paths = {}
    drained = true
    for path, reason in pairs(pending) do
      if symbol_index.reindex_file then
        symbol_index.reindex_file(path, { force = true, reason = reason or "queued-during-indexing" })
      end
    end
  end
  return drained
end

local function add_coalesced_scope(scopes, path, value)
  for existing in pairs(scopes) do
    if common.path_equals(existing, path) or common.path_belongs_to(path, existing) then
      return false
    end
  end
  for existing in pairs(scopes) do
    if common.path_belongs_to(existing, path) then scopes[existing] = nil end
  end
  scopes[path] = value
  return true
end

local function watch_dir(index, dir)
  if not index or not index.watcher or not dir then return false end
  dir = common.normalize_path(dir)
  if index.watched_dirs[dir] then return false end
  local info = system.get_file_info(dir)
  if not info or info.type ~= "dir" then return false end
  index.watcher:watch(dir)
  index.watched_dirs[dir] = true
  return true
end

local function prune_missing_watches(index, scope)
  if not index or not index.watcher then return false end
  scope = scope and common.normalize_path(scope)
  local changed = false
  for dir in pairs(index.watched_dirs or {}) do
    if not scope or common.path_equals(dir, scope) or common.path_belongs_to(dir, scope) then
      local info = system.get_file_info(dir)
      if not info or info.type ~= "dir" then
        index.watcher:unwatch(dir)
        index.watched_dirs[dir] = nil
        changed = true
      end
    end
  end
  return changed
end

local function refresh_watches_for_dir(index, dir)
  if not index or not index.watcher or not dir then return false end
  dir = common.normalize_path(dir)
  local info = system.get_file_info(dir)
  if not info or info.type ~= "dir" then return false end

  local project = Project(index.root)
  prune_missing_watches(index, dir)
  local changed = watch_dir(index, dir)
  local mode = index.watcher.monitor and index.watcher.monitor.mode and index.watcher.monitor:mode()
  if mode == "single" then
    log_quiet("Tree-sitter Project index: watching %s with single native watch; skipping recursive watch setup", tostring(dir))
    return changed
  end
  local stack = { dir }
  local yielded = 0
  while #stack > 0 do
    local current = table.remove(stack)
    local names = system.list_dir(current) or {}
    for _, name in ipairs(names) do
      local path = common.normalize_path(current .. PATHSEP .. name)
      local child = project:get_file_info(path)
      if child and child.type == "dir" then
        if watch_dir(index, path) then changed = true end
        stack[#stack + 1] = path
      end
    end
    yielded = yielded + 1
    if yielded >= DEFAULT_SCAN_YIELD_FILES * 16 then
      yielded = 0
      safe_yield(0)
    end
  end
  return changed
end

local function start_project_watcher(index)
  if not index or index.watch_running then return false end
  index.watcher = index.watcher or DirWatch()
  index.watched_dirs = index.watched_dirs or {}
  index.watch_generation = (index.watch_generation or 0) + 1
  local generation = index.watch_generation
  index.watch_running = true
  local root = index.root

  core.add_thread(function()
    log_quiet("Tree-sitter Project index: starting filesystem watcher for %s", tostring(root))
    local ok, err = pcall(refresh_watches_for_dir, index, root)
    if not ok then
      log_quiet("Tree-sitter Project index: initial filesystem watch setup failed for %s: %s", tostring(root), tostring(err))
    elseif index.status == "ready" and symbol_index.mark_directory_dirty then
      symbol_index.mark_directory_dirty(root, "watch-startup", { force = false })
    end

    while index.watch_generation == generation do
      local changed_dirs = {}
      ok, err = pcall(function()
        index.watcher:check(function(path)
          path = path and common.normalize_path(path)
          if path and (common.path_equals(path, root) or common.path_belongs_to(path, root)) then
            changed_dirs[path] = true
          end
        end, 0.02, 0.01)
      end)
      if not ok then
        log_quiet("Tree-sitter Project index: filesystem watcher failed for %s: %s", tostring(root), tostring(err))
        safe_yield(5)
      else
        if next(changed_dirs) and symbol_index.mark_directories_dirty then
          symbol_index.mark_directories_dirty(changed_dirs, "project-watch")
        end
        safe_yield(0.25)
      end
    end
    index.watch_running = false
    log_quiet("Tree-sitter Project index: stopped filesystem watcher for %s", tostring(root))
  end)
  return true
end

local function native_project_run_languages_payload()
  local out = {}
  for _, language in ipairs(registry.get_languages() or {}) do
    local sources = language.query_sources or {}
    if sources.outline then
      local usage_kind = usage_query_kind(language)
      out[#out + 1] = {
        id = language.id,
        grammar = language.grammar,
        files = language.files,
        outline_query = sources.outline,
        usage_query = usage_kind and sources[usage_kind] or nil,
        parse_timeout_ms = language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS,
        query_timeout_ms = effective_query_limit(language, "outline", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS),
        match_limit = effective_query_limit(language, "outline", "match_limit", DEFAULT_MATCH_LIMIT),
        max_captures = effective_query_limit(language, "outline", "max_captures", DEFAULT_MAX_CAPTURES),
        usage_query_timeout_ms = effective_query_limit(language, "usages", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS),
        usage_match_limit = effective_query_limit(language, "usages", "match_limit", DEFAULT_MATCH_LIMIT),
        usage_max_captures = effective_query_limit(language, "usages", "max_captures", DEFAULT_MAX_CAPTURES),
      }
    end
  end
  return out
end

local function project_index_exclusions_payload()
  local excluded = {}
  for _, entry in ipairs(project_paths_module().entries()) do
    if entry.path and entry.symbols == false and entry.usages == false then
      excluded[#excluded + 1] = { path = entry.path }
    end
  end
  return excluded
end

local function current_worker_message(index, message)
  return index
     and message
     and message.generation == index.generation
     and message.project_paths_generation == index.project_paths_generation
end

local function finish_worker_scan(index, message, status)
  if not current_worker_message(index, message) then return end
  if status == "ready" then
    index.status = "ready"
    index.symbol_status = "ready"
    index.usage_status = "ready"
    index.reason = nil
  else
    index.status = status
    if message.phase == "usages" and index.symbol_status == "ready" then
      index.usage_status = status
    else
      index.symbol_status = status
      index.usage_status = status
    end
    index.reason = message.error or (message.payload and message.payload.reason) or status
  end
  index.worker_handle = nil
  index.worker_seen_paths = nil
  index.finished_at = system.get_time()
  index.last_completed_run = {
    generation = message.generation,
    phase = message.phase,
    status = status,
    diagnostics = index.diagnostics,
    finished_at = index.finished_at,
  }
  index.completed_runs = index.completed_runs or {}
  index.completed_runs[message.generation] = index.last_completed_run
  index.completed_runs[message.generation - 32] = nil
  core.redraw = true
  if status == "ready" then
    local diagnostics = index.diagnostics or {}
    local worker = diagnostics.worker or {}
    local ui = diagnostics.ui or {}
    local native_summary = index.native_snapshot and index.native_snapshot:summary() or nil
    log_quiet("Tree-sitter Project index: worker indexed %d symbol(s), %d usage(s)%s under %s in %.1fms",
      native_summary and native_summary.symbols or #index.symbols,
      native_summary and native_summary.usages or index.usage_count or 0,
      index.usage_truncated and " (truncated)" or "",
      index.root, ((index.finished_at or system.get_time()) - (index.started_at or system.get_time())) * 1000)
    log_quiet("Tree-sitter native Project run: root=%s phase=%s files=%d parsed=%d reused=%d skipped=%d symbols=%d usages=%d run_ms=%.1f parse_ms=%.1f record_ms=%.1f",
      tostring(index.root), tostring(worker.phase or message.phase),
      tonumber(worker.files_scanned or index.files_scanned or 0) or 0,
      tonumber(worker.parse_calls or 0) or 0,
      tonumber(worker.files_reused or 0) or 0,
      tonumber(worker.files_skipped or 0) or 0,
      native_summary and native_summary.symbols or 0,
      native_summary and native_summary.usages or 0,
      tonumber(worker.native_batch_ms or worker.total_ms or 0) or 0,
      tonumber(worker.parse_ms or 0) or 0,
      tonumber(worker.native_project_record_ms or 0) or 0)
    core.add_thread(function()
      safe_yield(0)
      local pending_started = now()
      local drained = drain_pending_reindexes(index)
      local pending_ms = elapsed_ms(pending_started)
      add_ui_metric(index, "pending_reindexes_drain_ms", pending_ms)
      max_ui_metric(index, "pending_reindexes_drain_max_ms", pending_ms)
      if drained then
        log_quiet("Tree-sitter Project index: drained pending reindexes for %s in %.1fms", tostring(index.root), pending_ms)
      end
    end)
  else
    log_quiet("Tree-sitter Project index: worker finished status=%s root=%s reason=%s", tostring(status), tostring(index.root), tostring(index.reason))
  end
end

local submit_worker_scan
local close_snapshot

local function cancel_index_work(index)
  if not index then return false end
  local cancelled = false
  if index.worker_handle then
    cancelled = worker_pool.system():cancel(index.worker_handle) or cancelled
    index.worker_handle = nil
  end
  if index.native_partial_snapshot then close_snapshot(index, index.native_partial_snapshot, "cancelled-partial") end
  index.native_partial_snapshot = nil
  index.partial_symbols_cache = nil
  index.worker_run = nil
  return cancelled
end

local function add_worker_diagnostics(index, phase, diagnostics)
  if not diagnostics then return end
  index.diagnostics = index.diagnostics or { ui = {}, phases = {} }
  index.diagnostics.phases = index.diagnostics.phases or {}
  local phase_entry = index.diagnostics.phases[phase] or { worker = {}, ui = {} }
  local worker = phase_entry.worker or {}
  worker.native_run_jobs = (worker.native_run_jobs or 0) + 1

  for key, value in pairs(diagnostics) do
    if type(value) == "number" then
      if tostring(key):match("_max$") or key == "files_scanned" then
        worker[key] = math.max(worker[key] or 0, value)
      elseif key ~= "worker_id" and key ~= "job_id" then
        worker[key] = (worker[key] or 0) + value
      end
    elseif key == "roots" and type(value) == "table" then
      worker.roots = worker.roots or {}
      for _, root in ipairs(value) do worker.roots[#worker.roots + 1] = root end
    elseif worker[key] == nil and key ~= "worker_id" and key ~= "job_id" then
      worker[key] = value
    end
  end

  worker.phase = phase
  worker.worker_id = worker.worker_id or "native"
  worker.job_id = worker.job_id or "native-run"
  phase_entry.worker = worker
  phase_entry.ui = common.merge({}, index.diagnostics.ui or {})
  index.diagnostics.phases[phase] = phase_entry
  index.diagnostics.worker = worker
end

local function current_run_message(index, run, message)
  return run
     and index.worker_run == run
     and current_worker_message(index, message)
     and message.phase == run.phase
end

close_snapshot = function(index, snapshot, kind)
  if not snapshot then return 0 end
  local started = now()
  local handle, submit_error = worker_pool.system():submit({
    kind = "project_snapshot_release",
    native = true,
    native_kind = "project_snapshot_release",
    priority = "background",
    native_payload = { release_snapshot = snapshot },
  })
  if not handle then
    pcall(snapshot.close, snapshot)
    log_quiet("Tree-sitter Project index: asynchronous %s snapshot release unavailable for %s: %s",
      tostring(kind or "native"), tostring(index and index.root), tostring(submit_error))
  end
  local duration = elapsed_ms(started)
  add_ui_metric(index, "native_snapshot_release_submit_ms", duration)
  max_ui_metric(index, "native_snapshot_release_submit_max_ms", duration)
  if duration > 10 then
    log_quiet("Tree-sitter Project index: submitted asynchronous %s snapshot release for %s in %.1fms",
      tostring(kind or "native"), tostring(index and index.root), duration)
  end
  return duration
end

local function publish_native_snapshot(index, run, message)
  local snapshot = run.completed_snapshot
  if not snapshot then
    close_snapshot(index, index.native_partial_snapshot, "partial")
    index.native_partial_snapshot = nil
    index.partial_symbols_cache = nil
    index.worker_run = nil
    finish_worker_scan(index, { error = "native-worker-snapshot-missing", payload = {} }, "failed")
    return
  end
  run.completed_snapshot = nil
  local previous_snapshot = index.native_snapshot
  index.native_snapshot = snapshot
  if previous_snapshot and previous_snapshot ~= snapshot then close_snapshot(index, previous_snapshot, "ready") end
  close_snapshot(index, index.native_partial_snapshot, "partial")
  index.native_partial_snapshot = nil
  index.partial_symbols_cache = nil
  if not current_run_message(index, run, message) then return end
  local summary = snapshot:summary()
  index.by_path = {}
  index.native_query_filter_cache = {}
  index.symbols = {}
  index.usages_by_name = {}
  index.usage_count = summary.usages
  index.usage_truncated = summary.usage_truncated and true or false
  index.usage_truncated_reason = index.usage_truncated and "project-usage-cap" or nil
  invalidate_combined_symbols_cache(index)
  index.worker_run = nil
  finish_worker_scan(index, message, "ready")
end

local function finish_native_run(index, run, status, message)
  if not current_run_message(index, run, message) then return end
  run.terminal = true
  if status == "ready" and run.completed_snapshot then
    publish_native_snapshot(index, run, message)
  else
    if run.completed_snapshot then close_snapshot(index, run.completed_snapshot, "unpublished") end
    run.completed_snapshot = nil
    close_snapshot(index, index.native_partial_snapshot, "cancelled-partial")
    index.native_partial_snapshot = nil
    index.partial_symbols_cache = nil
    index.worker_run = nil
    finish_worker_scan(index, message, status)
  end
end

local function submit_native_run(index, generation, opts, phase)
  opts = opts or {}
  phase = phase or "combined"
  cancel_index_work(index)
  if not project_native then
    index.status = "failed"
    index.symbol_status = "failed"
    index.usage_status = "failed"
    index.reason = "native-project-builder-unavailable"
    return false, index.reason
  end
  index.status = "indexing"
  if phase ~= "usages" then
    index.symbol_status = "indexing"
    index.usage_status = "indexing"
    index.started_at = system.get_time()
    index.project_paths_generation = project_paths_module().generation()
  else
    index.symbol_status = "ready"
    index.usage_status = "indexing"
  end
  index.reason = opts.reason
  index.finished_at = nil
  index.files_total = 0
  index.files_scanned = 0
  index.files_indexed = 0
  index.worker_seen_paths = {}
  local previous_phases = phase ~= "usages" and {} or ((index.diagnostics and index.diagnostics.phases) or {})
  index.diagnostics = {
    ui = {},
    phases = previous_phases,
    phase = phase,
    generation = generation,
    project_paths_generation = index.project_paths_generation,
    root = index.root,
  }
  if index.watcher then refresh_watches_for_dir(index, index.root) end

  local run = {
    generation = generation,
    project_paths_generation = index.project_paths_generation,
    phase = phase,
    opts = opts,
  }
  index.worker_run = run
  index.worker_handle = nil

  local native_run_phase = phase == "combined" or phase == "targeted" or phase == "targeted-directory"
  if native_run_phase then
    local scan_paths, scoped = {}, phase ~= "combined" or opts.files ~= nil or opts.scan_root ~= nil
    if opts.files then
      for _, file in ipairs(opts.files) do scan_paths[#scan_paths + 1] = file.path end
    elseif opts.scan_roots then
      for _, path in ipairs(opts.scan_roots) do scan_paths[#scan_paths + 1] = path end
    elseif opts.scan_root then
      scan_paths[1] = opts.scan_root
    end
    table.sort(scan_paths)
    run.native_orchestrated = true
    local excluded_paths = {}
    for _, entry in ipairs(project_index_exclusions_payload()) do excluded_paths[#excluded_paths + 1] = entry.path end
    local handle, submit_error = worker_pool.system():submit({
      kind = "treesitter_project_run",
      native = true,
      native_kind = "treesitter_project_run",
      priority = "background",
      generation = generation,
      project_paths_generation = index.project_paths_generation,
      phase = phase,
      native_payload = {
        base_snapshot = opts.base_snapshot,
        project_root = index.root,
        project_scoped = scoped,
        scan_paths = scan_paths,
        remove_paths = opts.remove_paths or {},
        excluded_paths = excluded_paths,
        ignore_patterns = config.ignore_files,
        languages = native_project_run_languages_payload(),
        project_usage_cap = index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP,
        project_progress_files = opts.progress_files or 64,
        publish_partial_snapshots = phase == "combined",
        max_file_bytes = MAX_FILE_BYTES,
      },
      is_stale = function(message) return not current_run_message(index, run, message) end,
      on_stale = function(message)
        local snapshot = message and message.payload and message.payload.snapshot
        if snapshot then close_snapshot(index, snapshot, "stale") end
      end,
      on_progress = function(message)
        if not current_run_message(index, run, message) then return end
        local p = message.payload or {}
        index.files_scanned = (p.files_completed or 0) + (p.files_skipped or 0)
        index.files_indexed = p.files_completed or 0
        index.files_total = index.files_indexed
        local partial = p.snapshot
        if partial then
          local previous = index.native_partial_snapshot
          index.native_partial_snapshot = partial
          index.partial_symbols_cache = nil
          if previous and previous ~= partial then close_snapshot(index, previous, "partial") end
        end
        core.redraw = true
      end,
      on_result = function(message)
        if not current_run_message(index, run, message) or message.type ~= "result" then return end
        local p = message.payload or {}
        index.files_scanned = (p.files_completed or 0) + (p.files_skipped or 0)
        index.files_indexed = p.files_completed or 0
        index.files_total = index.files_indexed
        run.completed_snapshot = p.snapshot
        add_worker_diagnostics(index, phase, {
          files_scanned = index.files_scanned,
          files_indexed = index.files_indexed,
          files_skipped = p.files_skipped or 0,
          parse_calls = math.max(0, (p.files_completed or 0) - (p.files_reused or 0)),
          files_reused = p.files_reused or 0,
          symbols_emitted = p.symbols_found or 0,
          usages_emitted = p.usages_found or 0,
          native_project_run_jobs = 1,
          native_batch_ms = p.batch_total_ms or 0,
          parse_ms = p.batch_parse_ms or 0,
          native_project_record_ms = p.batch_project_record_ms or 0,
          native_project_builder_ms = p.project_builder_ms or 0,
          native_project_snapshot_ms = p.project_snapshot_ms or 0,
          native_project_files_transferred = p.files_completed or 0,
        })
      end,
      on_error = function(message)
        if current_run_message(index, run, message) then finish_native_run(index, run, "failed", message) end
      end,
      on_cancelled = function(message)
        if current_run_message(index, run, message) then finish_native_run(index, run, "cancelled", message) end
      end,
      on_complete = function(message)
        if not current_run_message(index, run, message) then return end
        -- Publish progress for at least one scheduler turn before replacing it with
        -- the immutable final snapshot. This keeps partial queries observable and
        -- avoids consuming progress and completion in the same worker-pool drain.
        core.add_thread(function()
          safe_yield(0.05)
          if current_run_message(index, run, message) then
            finish_native_run(index, run, "ready", message)
          end
        end)
      end,
    })
    if not handle then
      index.worker_run = nil
      index.status = "failed"
      index.symbol_status = "failed"
      index.usage_status = "failed"
      index.reason = submit_error or "native-project-run-submit-failed"
      return false, index.reason
    end
    index.worker_handle = handle
    log_quiet("Tree-sitter Project index: submitted native run generation=%d root=%s", generation, tostring(index.root))
    return true, "scheduled"
  end

  index.worker_run = nil
  index.status = "failed"
  index.symbol_status = "failed"
  index.usage_status = "failed"
  index.reason = "unsupported-native-project-phase"
  return false, index.reason
end

submit_worker_scan = function(index, generation, opts, phase)
  opts = opts or {}
  phase = phase or "combined"
  submit_native_run(index, generation, opts, phase)
end

function symbol_index.ensure_scan(root, opts)
  opts = opts or {}
  local index = index_for_root(root)
  start_project_watcher(index)
  if index.status == "indexing" and not opts.force then return index end
  if index.status == "ready" and not opts.force then
    local refresh_after = tonumber(opts.refresh_after_seconds or DEFAULT_REFRESH_AFTER_SECONDS)
    if refresh_after <= 0 or (index.finished_at and system.get_time() - index.finished_at < refresh_after) then
      return index
    end
  end
  index.generation = index.generation + 1
  local generation = index.generation
  submit_worker_scan(index, generation, opts)
  return index
end

local function project_path_roots(kind, opts)
  opts = opts or {}
  local roots = {}
  local root_kind = opts.kind or kind
  if opts.root or opts.project then
    roots[1] = normalize_root(opts.root or opts.project)
  else
    for _, entry in ipairs(project_paths_module().search_roots(root_kind)) do
      if entry and entry.path then roots[#roots + 1] = normalize_root(entry.path) end
    end
  end
  return roots
end

local function scan_options_from_query(opts)
  opts = opts or {}
  return {
    force = opts.force,
    -- Query APIs must not kick off freshness rescans by default. Large external
    -- Roots can take minutes to reindex; queries should search the previous
    -- immutable snapshot instead of triggering freshness work.
    refresh_after_seconds = opts.refresh_after_seconds ~= nil and opts.refresh_after_seconds or 0,
    progress_files = opts.progress_files,
  }
end

function symbol_index.start_project_indexing(opts)
  opts = opts or {}
  local roots = project_path_roots("symbols", opts)
  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    log_quiet("Tree-sitter Project index: scheduled %s indexing for %s status=%s", tostring(opts.reason or "project"), tostring(root), tostring(index.status))
  end
end

function symbol_index.invalidate(root)
  if root then
    local normalized = normalize_root(root)
    local index = index_for_root(normalized)
    cancel_index_work(index)
    index.status = "idle"
    index.symbol_status = "idle"
    index.usage_status = "idle"
    index.generation = index.generation + 1
  else
    for _, index in pairs(indexes) do
      cancel_index_work(index)
      index.status = "idle"
      index.symbol_status = "idle"
      index.usage_status = "idle"
      index.generation = index.generation + 1
    end
  end
end

local refresh_open_document_overlays
local overlay_entry_current

local function doc_should_suppress_disk(doc)
  if not doc then return false end
  if type(doc.is_dirty) == "function" then
    local ok, dirty = pcall(doc.is_dirty, doc)
    return ok and dirty or false
  end
  return false
end

local function has_pending_open_doc_overlay(index)
  return index and index.open_doc_jobs and next(index.open_doc_jobs) ~= nil
end

local function overlay_paths(index)
  local paths = {}
  for path in pairs(index.open_doc_jobs or {}) do paths[path] = true end
  for path, entry in pairs(index.open_docs or {}) do
    if overlay_entry_current and overlay_entry_current(entry) then paths[path] = true end
  end
  for path, doc in pairs(open_documents) do
    if common.path_belongs_to(path, index.root) and doc_should_suppress_disk(doc) then paths[path] = true end
  end
  for _, doc in pairs(core.docs or {}) do
    local path = doc and (doc.abs_filename or doc.filename)
    path = path and common.normalize_path(path)
    if path and common.path_belongs_to(path, index.root) and doc_should_suppress_disk(doc) then paths[path] = true end
  end

  local ordered = {}
  for path in pairs(paths) do ordered[#ordered + 1] = path end
  table.sort(ordered)
  return paths, table.concat(ordered, "\0")
end

overlay_entry_current = function(entry)
  if not entry or not entry.doc then return false end
  local doc = entry.doc
  local ts = doc.treesitter
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  return ts and ts.status == "ready" and entry.change_id == change_id
end

local function partial_snapshot_symbols(index, max_items)
  local snapshot = index.native_partial_snapshot
  if not snapshot or index.symbol_status == "ready" then return index.symbols or {}, #(index.symbols or {}) end
  local ok, summary = pcall(snapshot.summary, snapshot)
  local count = ok and summary and (summary.symbols or 0) or 0
  if max_items and count > max_items then return nil, count end
  local cache = index.partial_symbols_cache
  if cache and cache.snapshot == snapshot then return cache.symbols, #cache.symbols end
  local symbols, offset = {}, 1
  while offset <= count do
    local page_ok, page = pcall(snapshot.symbols, snapshot, { offset = offset, limit = 4096 })
    if not page_ok then return nil, count end
    for _, symbol in ipairs(page) do
      symbol.text = nil
      symbol.file = nil
      symbol.range = nil
      symbol.search_text = nil
      symbols[#symbols + 1] = symbol
    end
    if #page == 0 or offset + #page > (page.total or count) then break end
    offset = page.next_offset
  end
  index.partial_symbols_cache = { snapshot = snapshot, symbols = symbols }
  return symbols, #symbols
end

local function combined_symbols(index, kind, disk_symbols)
  kind = kind or "symbols"
  disk_symbols = disk_symbols or index.symbols or {}
  if refresh_open_document_overlays then refresh_open_document_overlays(index) end
  index.combined_symbols_cache = index.combined_symbols_cache or {}
  local project_paths_generation = project_paths_module().generation()
  local paths, paths_signature = overlay_paths(index)
  local cache = index.combined_symbols_cache[kind]
  if cache
  and cache.index_generation == index.generation
  and cache.project_paths_generation == project_paths_generation
  and cache.overlay_generation == (index.overlay_generation or 0)
  and cache.overlay_paths_signature == paths_signature
  and cache.symbols_table == disk_symbols then
    inc_ui_metric(index, "combined_symbols_cache_hits", 1)
    return cache.symbols
  end

  inc_ui_metric(index, "combined_symbols_cache_misses", 1)
  local overlay = index.open_docs or {}
  local out = {}
  for _, symbol in ipairs(disk_symbols) do
    if not paths[symbol.path] and project_path_allows(symbol.path, kind) then
      out[#out + 1] = refresh_project_path_metadata(index, copy_item(symbol), kind)
    end
  end
  for _, entry in pairs(overlay) do
    if overlay_entry_current(entry) then
      for _, symbol in ipairs(entry.symbols or {}) do
        if project_path_allows(symbol.path, kind) then
          out[#out + 1] = refresh_project_path_metadata(index, copy_item(symbol), kind)
        end
      end
    end
  end
  sort_symbols(out)
  index.combined_symbols_cache[kind] = {
    index_generation = index.generation,
    project_paths_generation = project_paths_generation,
    overlay_generation = index.overlay_generation or 0,
    overlay_paths_signature = paths_signature,
    symbols_table = disk_symbols,
    symbols = out,
  }
  return out
end

local function combined_usages_for_name(index, name)
  if refresh_open_document_overlays then refresh_open_document_overlays(index) end
  local overlay = index.open_docs or {}
  local paths = overlay_paths(index)
  local out = {}
  for _, usage in ipairs((index.usages_by_name or {})[name] or {}) do
    if not paths[usage.path] and not project_paths_module().is_excluded(usage.path, "usages") then
      out[#out + 1] = refresh_project_path_metadata(index, usage, "usages")
    end
  end
  for _, entry in pairs(overlay) do
    if overlay_entry_current(entry) then
      for _, usage in ipairs((entry.usages_by_name or {})[name] or {}) do
        if not project_paths_module().is_excluded(usage.path, "usages") then
          out[#out + 1] = refresh_project_path_metadata(index, usage, "usages")
        end
      end
    end
  end
  sort_usages(out)
  return out
end


local function symbol_fuzzy_text(symbol)
  return tostring(symbol and (symbol.search_text or symbol.text or symbol.name) or "")
end

local function public_symbol(symbol)
  if not symbol then return nil end
  local item = copy_item(symbol)
  item.text = item.text or item.name
  item.file = item.file or item.relpath or item.path
  item.relpath = item.relpath or item.file
  item.range = item.range or {
    start = { line = item.start_line, col = item.start_col },
    ["end"] = { line = item.end_line, col = item.end_col },
  }
  return item
end

local function symbol_language_allowed(symbol, languages)
  if not languages or #languages == 0 then return true end
  local language_id = tostring(symbol and symbol.language_id or "")
  for _, allowed in ipairs(languages) do
    if language_id == tostring(allowed) then return true end
  end
  return false
end

local function symbol_parent_allowed(symbol, parent_names)
  if not parent_names or #parent_names == 0 then return true end
  local parent_name = tostring(symbol and symbol.parent_name or "")
  for _, allowed in ipairs(parent_names) do
    if parent_name == tostring(allowed) then return true end
  end
  return false
end

local function filtered_symbols(symbols, query, limit, opts)
  symbols = symbols or {}
  opts = opts or {}
  local languages = opts.language_ids or opts.languages
  if languages and #languages > 0 then
    local allowed = {}
    for _, symbol in ipairs(symbols) do
      if symbol_language_allowed(symbol, languages) then allowed[#allowed + 1] = symbol end
    end
    symbols = allowed
  end
  local parent_names = opts.parent_names
  if parent_names and #parent_names > 0 then
    local allowed = {}
    for _, symbol in ipairs(symbols) do
      if symbol_parent_allowed(symbol, parent_names) then allowed[#allowed + 1] = symbol end
    end
    symbols = allowed
  end
  query = tostring(query or "")
  limit = math.max(0, math.floor(tonumber(limit) or DEFAULT_QUERY_LIMIT))
  local out = {}
  if query == "" then
    for i = 1, math.min(limit, #symbols) do out[i] = symbols[i] end
    return out, #symbols > #out
  end
  if native_fuzzy then
    local texts = {}
    for i, symbol in ipairs(symbols) do texts[i] = symbol_fuzzy_text(symbol) end
    local matches = native_fuzzy.filter(texts, query, {
      mode = "generic",
      limit = math.min(#texts, limit + 1),
      spans = false,
    }) or {}
    for i = 1, math.min(limit, #matches) do out[i] = symbols[matches[i].index] end
    return out, #matches > #out
  end
  local items = common.fuzzy_match(symbols, query, false)
  for i = 1, math.min(limit, #items) do out[i] = items[i] end
  return out, #items > #out
end

local function refresh_current_core_docs_for_index(index)
  -- Query paths must not synchronously extract open-document overlays. Open
  -- documents are remembered here only so dirty buffers can suppress stale disk
  -- entries; overlay records are updated by the Tree-sitter parse-ready hook.
  if not index then return end
  for _, doc in pairs(core.docs or {}) do
    local path = doc and (doc.abs_filename or doc.filename)
    path = path and common.normalize_path(path)
    if path and common.path_belongs_to(path, index.root) then open_documents[path] = doc end
  end
end

local function merge_status(current, next_status)
  if current == "pending" or next_status == "pending" then return "pending" end
  if current == "stale" or next_status == "stale" then return "stale" end
  return "fresh"
end

local function native_query_path_rules(index, snapshot, kind)
  refresh_current_core_docs_for_index(index)
  if refresh_open_document_overlays then refresh_open_document_overlays(index) end
  local suppressed, signature = overlay_paths(index)
  local generation = project_paths_module().generation()
  index.native_query_filter_cache = index.native_query_filter_cache or {}
  local cache_key = tostring(kind) .. "\0" .. signature
  local cache = index.native_query_filter_cache[cache_key]
  if cache and cache.snapshot == snapshot and cache.project_paths_generation == generation then
    return cache.excluded, cache.included, suppressed
  end
  local excluded, included = {}, {}
  for path in pairs(suppressed) do excluded[#excluded + 1] = path end
  for _, entry in ipairs(project_paths_module().entries()) do
    local target = entry[kind] == false and excluded or included
    target[#target + 1] = entry.path
  end
  table.sort(excluded)
  table.sort(included)
  cache = {
    snapshot = snapshot,
    project_paths_generation = generation,
    excluded = excluded,
    included = included,
  }
  index.native_query_filter_cache[cache_key] = cache
  return excluded, included, suppressed
end

local function symbol_kind_allowed(symbol, kinds)
  if not kinds or #kinds == 0 then return true end
  for _, kind in ipairs(kinds) do
    if symbol.kind == kind then return true end
  end
  return false
end

local function insert_bounded(items, item, less, capacity)
  if capacity <= 0 then return end
  local low, high = 1, #items + 1
  while low < high do
    local middle = math.floor((low + high) / 2)
    if less(item, items[middle]) then high = middle else low = middle + 1 end
  end
  if low <= capacity then
    table.insert(items, low, item)
    if #items > capacity then items[#items] = nil end
  end
end

local function bounded_overlay_symbols(index, suppressed, query, opts, capacity)
  local candidates, matched = {}, 0
  local kinds = opts.symbol_kinds or opts.kinds
  query = tostring(query or "")
  for path, entry in pairs(index.open_docs or {}) do
    if suppressed[path] and overlay_entry_current(entry) then
      for _, symbol in ipairs(entry.symbols or {}) do
        if project_path_allows(symbol.path, opts.kind or "symbols")
        and symbol_kind_allowed(symbol, kinds)
        and symbol_language_allowed(symbol, opts.language_ids or opts.languages)
        and symbol_parent_allowed(symbol, opts.parent_names) then
          local score = query == "" and 0 or (native_fuzzy and native_fuzzy.score(symbol_fuzzy_text(symbol), query, { mode = "generic" }))
          if query == "" or score then
            matched = matched + 1
            local candidate = { symbol = symbol, score = score or 0 }
            insert_bounded(candidates, candidate, function(a, b)
              if a.score ~= b.score then return a.score > b.score end
              local an, bn = symbol_fuzzy_text(a.symbol), symbol_fuzzy_text(b.symbol)
              if an ~= bn then return an < bn end
              return symbol_less(a.symbol, b.symbol)
            end, capacity)
          end
        end
      end
    end
  end
  local out = {}
  for _, candidate in ipairs(candidates) do out[#out + 1] = candidate.symbol end
  return out, matched > #out
end

local function native_project_symbols(index, snapshot, query, opts)
  local kind = opts.kind or "symbols"
  local excluded, included, suppressed = native_query_path_rules(index, snapshot, kind)
  local limit = math.max(0, math.floor(tonumber(opts.limit) or DEFAULT_QUERY_LIMIT))
  local candidate_limit = math.min(4096, limit + 1)
  local overlays, overlay_more = bounded_overlay_symbols(index, suppressed, query, opts, candidate_limit)
  local native_limit = candidate_limit
  local query_started = system.get_time()
  local page = snapshot:query_symbols(query, {
    offset = 0,
    limit = native_limit,
    kinds = opts.symbol_kinds or opts.kinds,
    parent_names = opts.parent_names,
    languages = opts.language_ids or opts.languages,
    excluded_paths = excluded,
    included_paths = included,
  })
  local query_ms = (system.get_time() - query_started) * 1000
  add_ui_metric(index, "native_symbol_query_ms", query_ms)
  max_ui_metric(index, "native_symbol_query_max_ms", query_ms)
  inc_ui_metric(index, "native_symbol_queries", 1)
  local combined = {}
  for _, symbol in ipairs(page) do combined[#combined + 1] = symbol end
  for _, symbol in ipairs(overlays) do combined[#combined + 1] = symbol end
  sort_symbols(combined)
  local results, merged_more = filtered_symbols(combined, query, limit, opts)
  for i, symbol in ipairs(results) do
    results[i] = public_symbol(refresh_project_path_metadata(index, symbol, kind))
  end
  return results, page.has_more or overlay_more or merged_more, has_pending_open_doc_overlay(index)
end

function symbol_index.workspace_symbols(query, opts)
  opts = opts or {}
  local roots = project_path_roots("symbols", opts)
  local single_root = #roots == 1
  local query_text = tostring(query or "")
  local sync_limit = math.max(0, math.floor(tonumber(opts.max_sync_query_items or DEFAULT_SYNC_QUERY_ITEM_LIMIT) or DEFAULT_SYNC_QUERY_ITEM_LIMIT))
  local all_symbols, per_root = {}, {}
  local status = "fresh"
  local reason
  local any_usable = false
  local has_more = false

  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    local native_snapshot = index.symbol_status == "ready" and index.native_snapshot
      or (opts.allow_stale and (index.native_partial_snapshot or index.native_snapshot))
    local disk_symbols, disk_symbol_count = {}, 0
    if not native_snapshot then
      disk_symbols, disk_symbol_count = partial_snapshot_symbols(index,
        query_text ~= "" and not opts.allow_large_sync_query and sync_limit or nil)
    end
    local root_status = "pending"
    if native_snapshot then
      local source, native_more, overlay_pending = native_project_symbols(index, native_snapshot, query_text, opts)
      if single_root and #all_symbols == 0 then
        all_symbols = source
      else
        for _, symbol in ipairs(source) do all_symbols[#all_symbols + 1] = symbol end
      end
      has_more = has_more or native_more
      root_status = index.symbol_status == "ready" and not overlay_pending and "fresh" or "stale"
      if overlay_pending then reason = reason or "overlay-indexing"
      elseif root_status == "stale" then reason = reason or "indexing" end
      any_usable = true
    elseif index.symbol_status == "ready" then
      refresh_current_core_docs_for_index(index)
      if has_pending_open_doc_overlay(index) then
        reason = reason or "overlay-indexing"
      elseif query_text ~= "" and disk_symbol_count > sync_limit and not opts.allow_large_sync_query then
        reason = reason or "query-too-large"
      else
        local suppressed = overlay_paths(index)
        local kind = opts.kind or "symbols"
        local source
        if kind == "symbols" and next(suppressed) == nil then
          source = disk_symbols or {}
        else
          if query_text ~= "" and disk_symbol_count > sync_limit and not opts.allow_large_sync_query then
            reason = reason or "query-too-large"
          else
            source = combined_symbols(index, kind, disk_symbols)
          end
        end
        if source then
          if single_root and #all_symbols == 0 then
            all_symbols = source
          else
            for _, symbol in ipairs(source) do all_symbols[#all_symbols + 1] = symbol end
          end
          root_status = "fresh"
          any_usable = true
        end
      end
    elseif (disk_symbol_count > 0 or next(index.open_docs or {}) ~= nil) and opts.allow_stale then
      if query_text ~= "" and disk_symbol_count > sync_limit and not opts.allow_large_sync_query then
        reason = reason or "query-too-large"
      else
        local source = combined_symbols(index, opts.kind or "symbols", disk_symbols)
        if single_root and #all_symbols == 0 then
          all_symbols = source
        else
          for _, symbol in ipairs(source) do all_symbols[#all_symbols + 1] = symbol end
        end
        root_status = "stale"
        reason = reason or "indexing"
        any_usable = true
      end
    else
      reason = reason or "indexing"
    end
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = { root = root, status = root_status, index = index }
  end

  if any_usable and status ~= "fresh" and not opts.allow_stale then
    return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  end
  if any_usable then
    if #per_root > 1 then sort_symbols(all_symbols) end
    local results, filtered_more
    results, filtered_more = filtered_symbols(all_symbols, query, opts.limit, opts)
    has_more = has_more or filtered_more
    for i, symbol in ipairs(results) do results[i] = public_symbol(symbol) end
    return results, status == "fresh" and nil or (reason or "indexing"), status == "fresh" and "fresh" or "stale", {
      has_more = has_more,
      roots = per_root,
      index = #per_root == 1 and per_root[1].index or nil,
    }
  end
  return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
end

local function public_usage(name, usage)
  if not usage then return nil end
  local item = copy_item(usage)
  item.name = item.name or name
  item.text = item.text or item.name
  item.file = item.file or item.relpath or item.path
  item.relpath = item.relpath or item.file
  item.range = item.range or {
    start = { line = item.start_line, col = item.start_col },
    ["end"] = { line = item.end_line, col = item.end_col },
  }
  return item
end

local function filter_usages(usages, opts, name)
  opts = opts or {}
  local include_declaration = opts.include_declaration ~= false
  local out = {}
  local has_more = false
  local limit = tonumber(opts.limit) or DEFAULT_QUERY_LIMIT
  for _, usage in ipairs(usages or {}) do
    if include_declaration or not usage.is_declaration then
      if #out < limit then
        out[#out + 1] = public_usage(name, usage)
      else
        has_more = true
        break
      end
    end
  end
  return out, has_more
end

local function completed_native_query_request(results, reason, source_status, meta)
  local query_project_paths_generation = project_paths_module().generation()
  local generations = {}
  for _, root_meta in ipairs(meta and meta.roots or {}) do
    local index = root_meta.index
    generations[#generations + 1] = {
      index = index,
      generation = index and index.generation,
      project_paths_generation = index and index.project_paths_generation,
    }
  end
  local request = {
    status = "pending",
    reason = reason,
    source_status = source_status,
    results = results,
    has_more = meta and meta.has_more or false,
    meta = meta,
  }
  function request:cancel()
    if self.done then return false end
    self.cancelled = true
    self.status = "cancelled"
    self.reason = "cancelled"
    self.results = nil
    self.done = true
    return true
  end
  core.add_thread(function()
    safe_yield(0)
    if request.done then return end
    if project_paths_module().generation() ~= query_project_paths_generation then
      request.status = "stale-cancelled"
      request.reason = "project-paths-generation-changed"
      request.results = nil
      request.done = true
      return
    end
    for _, captured in ipairs(generations) do
      local index = captured.index
      if not index or index.generation ~= captured.generation
      or index.project_paths_generation ~= captured.project_paths_generation then
        request.status = "stale-cancelled"
        request.reason = "index-generation-changed"
        request.results = nil
        request.done = true
        return
      end
    end
    request.status = source_status
    request.done = true
  end)
  return request, nil, "pending", meta
end

function symbol_index.workspace_symbols_async(query, opts)
  local results, reason, status, meta = symbol_index.workspace_symbols(query, opts or {})
  if status == "fresh" or status == "stale" then
    return completed_native_query_request(results, reason, status, meta)
  end
  return nil, reason, status, meta
end

function symbol_index.query_symbols_async(query, opts)
  return symbol_index.workspace_symbols_async(query, opts)
end

function symbol_index.workspace_usages_async(name, opts)
  local results, reason, status, meta = symbol_index.workspace_usages(name, opts or {})
  if status == "fresh" or status == "stale" then
    return completed_native_query_request(results, reason, status, meta)
  end
  return nil, reason, status, meta
end

local function bounded_overlay_usages(index, suppressed, name, opts, capacity)
  local candidates, matched = {}, 0
  local include_declaration = opts.include_declaration ~= false
  for path, entry in pairs(index.open_docs or {}) do
    if suppressed[path] and overlay_entry_current(entry) then
      for _, usage in ipairs((entry.usages_by_name or {})[name] or {}) do
        if (include_declaration or not usage.is_declaration)
        and project_path_allows(usage.path, "usages") then
          matched = matched + 1
          insert_bounded(candidates, usage, usage_less, capacity)
        end
      end
    end
  end
  return candidates, matched > #candidates
end

local function native_project_usages(index, snapshot, name, opts)
  local excluded, included, suppressed = native_query_path_rules(index, snapshot, "usages")
  local limit = math.max(0, math.floor(tonumber(opts.limit) or DEFAULT_QUERY_LIMIT))
  local candidate_limit = math.min(4096, limit + 1)
  local overlays, overlay_more = bounded_overlay_usages(index, suppressed, name, opts, candidate_limit)
  local query_started = system.get_time()
  local page = snapshot:query_usages(name, {
    offset = 0,
    limit = candidate_limit,
    include_declaration = opts.include_declaration ~= false,
    excluded_paths = excluded,
    included_paths = included,
  })
  local query_ms = (system.get_time() - query_started) * 1000
  add_ui_metric(index, "native_usage_query_ms", query_ms)
  max_ui_metric(index, "native_usage_query_max_ms", query_ms)
  inc_ui_metric(index, "native_usage_queries", 1)
  local combined = {}
  for _, usage in ipairs(page) do combined[#combined + 1] = usage end
  for _, usage in ipairs(overlays) do combined[#combined + 1] = usage end
  sort_usages(combined)
  local has_more = page.has_more or overlay_more or #combined > limit
  while #combined > limit do combined[#combined] = nil end
  for i, usage in ipairs(combined) do
    combined[i] = public_usage(name, refresh_project_path_metadata(index, usage, "usages"))
  end
  return combined, has_more, has_pending_open_doc_overlay(index)
end

function symbol_index.workspace_usages(name, opts)
  opts = opts or {}
  name = tostring(name or "")
  if name == "" then return {}, "no-symbol", "fresh", { has_more = false } end
  local roots = project_path_roots("usages", opts)
  local single_root = #roots == 1
  local sync_limit = math.max(0, math.floor(tonumber(opts.max_sync_query_items or DEFAULT_SYNC_QUERY_ITEM_LIMIT) or DEFAULT_SYNC_QUERY_ITEM_LIMIT))
  local all_usages, per_root = {}, {}
  local status = "fresh"
  local reason
  local any_usable = false
  local has_more = false
  local usage_truncated = false
  local usage_truncated_reason

  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    local root_status = "pending"
    local native_snapshot = index.usage_status == "ready" and index.native_snapshot
      or (opts.allow_stale and (index.native_partial_snapshot or index.native_snapshot))
    if native_snapshot then
      local source, native_more, overlay_pending = native_project_usages(index, native_snapshot, name, opts)
      if single_root and #all_usages == 0 then
        all_usages = source
      else
        for _, usage in ipairs(source) do all_usages[#all_usages + 1] = usage end
      end
      has_more = has_more or native_more
      root_status = index.usage_status == "ready" and not overlay_pending and "fresh" or "stale"
      if overlay_pending then reason = reason or "overlay-indexing"
      elseif root_status == "stale" then reason = reason or "indexing" end
      any_usable = true
    elseif index.usage_status == "ready" then
      refresh_current_core_docs_for_index(index)
      if has_pending_open_doc_overlay(index) then
        reason = reason or "overlay-indexing"
      elseif #((index.usages_by_name or {})[name] or {}) > sync_limit and not opts.allow_large_sync_query then
        reason = reason or "query-too-large"
      else
        refresh_current_core_docs_for_index(index)
        local source = combined_usages_for_name(index, name)
        if single_root and #all_usages == 0 then
          all_usages = source
        else
          for _, usage in ipairs(source) do all_usages[#all_usages + 1] = usage end
        end
        root_status = "fresh"
        any_usable = true
      end
    elseif opts.allow_stale and ((index.usages_by_name or {})[name] or next(index.open_docs or {}) ~= nil) then
      if #((index.usages_by_name or {})[name] or {}) > sync_limit and not opts.allow_large_sync_query then
        reason = reason or "query-too-large"
      else
        local source = combined_usages_for_name(index, name)
        if single_root and #all_usages == 0 then
          all_usages = source
        else
          for _, usage in ipairs(source) do all_usages[#all_usages + 1] = usage end
        end
        root_status = "stale"
        reason = reason or "indexing"
        any_usable = true
      end
    else
      reason = reason or "indexing"
    end
    usage_truncated = usage_truncated or index.usage_truncated or false
    usage_truncated_reason = usage_truncated_reason or index.usage_truncated_reason
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = { root = root, status = root_status, index = index }
  end

  if any_usable and status ~= "fresh" and not opts.allow_stale then
    return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  end
  if any_usable then
    if #per_root > 1 then sort_usages(all_usages) end
    local results, filtered_more
    results, filtered_more = filter_usages(all_usages, opts, name)
    has_more = has_more or filtered_more or usage_truncated
    return results, status == "fresh" and nil or (reason or "indexing"), status == "fresh" and "fresh" or "stale", {
      has_more = has_more,
      roots = per_root,
      index = #per_root == 1 and per_root[1].index or nil,
      usage_truncated = usage_truncated,
      usage_truncated_reason = usage_truncated_reason,
    }
  end
  return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
end

function symbol_index.workspace_references(name, opts)
  return symbol_index.workspace_usages(name, opts)
end

function symbol_index.workspace_references_async(name, opts)
  return symbol_index.workspace_usages_async(name, opts)
end

function symbol_index.query_usages_async(name, opts)
  return symbol_index.workspace_usages_async(name, opts)
end

local function doc_path(doc)
  local path = doc and (doc.abs_filename or doc.filename)
  return path and common.normalize_path(path) or nil
end

local function doc_lines(doc)
  return doc and doc.lines or nil
end

local function doc_text_from_lines(lines)
  if type(lines) ~= "table" then return nil, "missing-lines" end
  return table.concat(lines, "\n")
end

local function cancel_open_doc_job(index, path)
  local job = index and index.open_doc_jobs and index.open_doc_jobs[path]
  if job and job.handle then worker_pool.system():cancel(job.handle) end
  if index and index.open_doc_jobs then index.open_doc_jobs[path] = nil end
end

local function submit_open_doc_overlay(index, doc, path, reason)
  local ts = doc and doc.treesitter
  if not ts or ts.status ~= "ready" then return false, "not-ready" end
  local language = ts.language
  if not language then return false, "missing-language" end
  local text, text_err = doc_text_from_lines(doc_lines(doc))
  if not text then return false, text_err or "missing-lines" end
  if #text > MAX_FILE_BYTES then return false, "too-large" end

  local change_id = doc.get_change_id and doc:get_change_id() or 0
  local project_paths_generation = index.project_paths_generation or project_paths_module().generation()
  cancel_open_doc_job(index, path)
  index.open_doc_jobs = index.open_doc_jobs or {}
  local job = {
    doc = doc,
    path = path,
    change_id = change_id,
    generation = index.generation,
    project_paths_generation = project_paths_generation,
  }
  index.open_doc_jobs[path] = job

  local function current()
    local active = index.open_doc_jobs and index.open_doc_jobs[path]
    local current_change_id = doc.get_change_id and doc:get_change_id() or 0
    return active == job
       and index.generation == job.generation
       and current_change_id == change_id
       and common.path_belongs_to(path, index.root)
  end

  local sources = language.query_sources or {}
  local usage_kind = usage_query_kind(language)
  local handle, err = worker_pool.system():submit({
    kind = "treesitter_open_doc_overlay",
    native = true,
    native_kind = "treesitter_index_text",
    priority = "interactive",
    generation = index.generation,
    project_paths_generation = project_paths_generation,
    phase = "open-doc-overlay",
    native_payload = {
      path = path,
      relpath = common.relative_path(index.root, path),
      language = language.grammar,
      text = text,
      outline_query = sources.outline,
      usage_query = usage_kind and sources[usage_kind] or nil,
      parse_timeout_ms = language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS,
      query_timeout_ms = effective_query_limit(language, "outline", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS),
      match_limit = effective_query_limit(language, "outline", "match_limit", DEFAULT_MATCH_LIMIT),
      max_captures = effective_query_limit(language, "outline", "max_captures", DEFAULT_MAX_CAPTURES),
      usage_query_timeout_ms = effective_query_limit(language, "usages", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS),
      usage_match_limit = effective_query_limit(language, "usages", "match_limit", DEFAULT_MATCH_LIMIT),
      usage_max_captures = effective_query_limit(language, "usages", "max_captures", DEFAULT_MAX_CAPTURES),
      capture_paging = false,
      line_range_lookup = false,
      compact_project_records = true,
    },
    is_stale = function()
      return not current()
    end,
    on_result = function(message)
      if not current() or message.type ~= "result" then return end
      local result = message.payload and message.payload.result
      if not result then return end
      local file = {
        path = path,
        relpath = common.relative_path(index.root, path),
        language_id = language.id,
        symbols = {},
        usages_by_name = {},
        usage_count = 0,
        doc = doc,
        change_id = change_id,
      }
      local offset = 0
      repeat
        local page = result:symbols({ offset = offset, limit = 4096 })
        for _, symbol in ipairs(page) do file.symbols[#file.symbols + 1] = symbol end
        offset = page.next_offset
      until offset >= page.total
      offset = 0
      repeat
        local page = result:usages({ offset = offset, limit = 4096 })
        for _, usage in ipairs(page) do
          local bucket = file.usages_by_name[usage.name] or {}
          file.usages_by_name[usage.name] = bucket
          bucket[#bucket + 1] = usage
          file.usage_count = file.usage_count + 1
        end
        offset = page.next_offset
      until offset >= page.total
      result:close()
      index.open_docs[path] = file
      bump_overlay_generation(index)
      core.redraw = true
    end,
    on_complete = function()
      if current() then
        index.open_doc_jobs[path] = nil
        log_quiet("Tree-sitter Project index: updated open document overlay for %s (%s)", tostring(path), tostring(reason or "change"))
      end
    end,
    on_error = function(message)
      if current() then
        index.open_doc_jobs[path] = nil
        if index.open_docs[path] then
          index.open_docs[path] = nil
          bump_overlay_generation(index)
        end
        log_quiet("Tree-sitter Project index: skipped open doc overlay for %s under %s: %s", tostring(path), tostring(index.root), tostring(message and message.error or "overlay-failed"))
      end
    end,
    on_cancelled = function()
      if current() then index.open_doc_jobs[path] = nil end
    end,
  })
  if not handle then
    index.open_doc_jobs[path] = nil
    return false, err or "submit-failed"
  end
  job.handle = handle
  return true, "scheduled"
end

refresh_open_document_overlays = function(index)
  if not index then return false end
  local changed = false
  local seen = {}
  local docs = {}
  for path, doc in pairs(open_documents) do docs[path] = doc end
  for _, doc in pairs(core.docs or {}) do
    local path = doc_path(doc)
    if path then docs[path] = doc end
  end
  for path, doc in pairs(docs) do
    if path and common.path_belongs_to(path, index.root) then
      seen[path] = true
      local current = index.open_docs[path]
      local change_id = doc.get_change_id and doc:get_change_id() or 0
      if not current or current.doc ~= doc or current.change_id ~= change_id then
        local scheduled = submit_open_doc_overlay(index, doc, path, "refresh")
        changed = scheduled or changed
      end
    end
  end
  for path, entry in pairs(index.open_docs or {}) do
    if not seen[path] or not entry.doc then
      cancel_open_doc_job(index, path)
      index.open_docs[path] = nil
      changed = true
    end
  end
  if changed then bump_overlay_generation(index) end
  return changed
end

function symbol_index.remember_open_document(doc)
  local path = doc_path(doc)
  if not path then return false, "no-path" end
  open_documents[path] = doc
  return true
end

function symbol_index.update_open_document(doc, reason)
  local path = doc_path(doc)
  if not path then return false, "no-path" end
  open_documents[path] = doc
  local updated = false
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  for _, index in pairs(indexes) do
    if common.path_belongs_to(path, index.root) then
      local current = index.open_docs[path]
      if current and current.doc == doc and current.change_id == change_id then
        updated = true
      else
        local scheduled, err = submit_open_doc_overlay(index, doc, path, reason)
        if scheduled then
          updated = true
        else
          cancel_open_doc_job(index, path)
          if index.open_docs[path] then bump_overlay_generation(index) end
          index.open_docs[path] = nil
          log_quiet("Tree-sitter Project index: skipped open doc overlay for %s under %s: %s", tostring(path), tostring(index.root), tostring(err))
        end
      end
    end
  end
  if updated then
    core.redraw = true
    log_quiet("Tree-sitter Project index: updated open document overlay for %s (%s)", tostring(path), tostring(reason or "change"))
  end
  return updated
end

function symbol_index.clear_open_document(doc, reason)
  local path = doc_path(doc)
  local cleared = false
  for open_path, open_doc in pairs(open_documents) do
    if (path and open_path == path) or open_doc == doc then
      open_documents[open_path] = nil
      cleared = true
    end
  end
  for _, index in pairs(indexes) do
    local index_cleared = false
    for overlay_path, entry in pairs(index.open_docs or {}) do
      if (path and overlay_path == path) or entry.doc == doc then
        cancel_open_doc_job(index, overlay_path)
        index.open_docs[overlay_path] = nil
        cleared = true
        index_cleared = true
      end
    end
    for overlay_path, job in pairs(index.open_doc_jobs or {}) do
      if (path and overlay_path == path) or job.doc == doc then
        cancel_open_doc_job(index, overlay_path)
        cleared = true
      end
    end
    if index_cleared then bump_overlay_generation(index) end
  end
  if cleared then
    core.redraw = true
    log_quiet("Tree-sitter Project index: cleared open document overlay for %s (%s)", tostring(path or doc), tostring(reason or "clear"))
  end
  return cleared
end

local function serializable_file_info(info)
  if not info then return nil end
  return {
    type = info.type,
    size = info.size,
    modified = info.modified,
  }
end

local function submit_targeted_file_reindex(index, path, opts)
  opts = opts or {}
  if not index or not path then return false, "no-index" end
  if not common.path_belongs_to(path, index.root) then return false, "outside-project" end

  local info = system.get_file_info(path)
  if index.native_snapshot then
    local language = info and info.type == "file" and registry.get(path) or nil
    local files = {}
    if language and language.query_sources and language.query_sources.outline then
      files[1] = { path = path, root = index.root, info = serializable_file_info(info), language_id = language.id }
    end
    index.generation = (index.generation or 0) + 1
    local scheduled, reason = submit_native_run(index, index.generation, {
      reason = opts.reason or "file-dirty",
      base_snapshot = index.native_snapshot,
      remove_paths = #files == 0 and { path } or {},
      files = files,
    }, "targeted")
    return scheduled and true or false, reason
  end
  return false, "native-snapshot-unavailable"
end

local function submit_targeted_directories_reindex(index, dirs, opts)
  opts = opts or {}
  if not index or not dirs or #dirs == 0 then return false, "no-index" end

  if index.native_snapshot then
    local scan_roots, remove_paths = {}, {}
    for _, dir in ipairs(dirs) do
      if not (common.path_equals(dir, index.root) or common.path_belongs_to(dir, index.root)) then
        return false, "outside-project"
      end
      local info = system.get_file_info(dir)
      if info and info.type == "dir" then scan_roots[#scan_roots + 1] = dir
      else remove_paths[#remove_paths + 1] = dir end
    end
    index.generation = (index.generation or 0) + 1
    local scheduled, reason = submit_native_run(index, index.generation, {
      reason = opts.reason or "directory-dirty",
      base_snapshot = index.native_snapshot,
      remove_paths = remove_paths,
      scan_roots = scan_roots,
    }, "targeted-directory")
    return scheduled and true or false, reason
  end
  return false, "native-snapshot-unavailable"
end

function symbol_index.reindex_file(path, opts)
  opts = opts or {}
  path = path and common.normalize_path(path)
  if not path then return false, "no-path" end
  local matched = false
  for _, index in pairs(indexes) do
    if common.path_belongs_to(path, index.root) then
      matched = true
      if index.status == "indexing" then
        index.pending_reindex_paths = index.pending_reindex_paths or {}
        index.pending_reindex_paths[path] = opts.reason or "file-dirty"
        log_quiet("Tree-sitter Project index: coalesced targeted file refresh for %s under %s while worker indexing (%s)",
          tostring(path), tostring(index.root), tostring(index.pending_reindex_paths[path]))
      else
        local submitted, submit_reason = submit_targeted_file_reindex(index, path, opts)
        if not submitted and submit_reason ~= "fresh" then
          index.status = "failed"
          index.symbol_status = "failed"
          index.usage_status = "failed"
          index.reason = submit_reason or "targeted-submit-failed"
          index.finished_at = system.get_time()
          log_quiet("Tree-sitter Project index: targeted worker reindex for %s under %s failed: %s",
            tostring(path), tostring(index.root), tostring(submit_reason))
        else
          log_quiet("Tree-sitter Project index: scheduled targeted worker reindex for %s under %s (%s)",
            tostring(path), tostring(index.root), tostring(submit_reason or opts.reason or "file-dirty"))
        end
      end
    end
  end
  return matched, matched and nil or "no-index"
end

function symbol_index.mark_directories_dirty(dirs, reason, opts)
  opts = opts or {}
  if type(dirs) ~= "table" then return false, "no-directory" end
  local scopes = {}
  for key, value in pairs(dirs) do
    local dir = type(key) == "number" and value or key
    dir = dir and common.normalize_path(dir)
    if dir then add_coalesced_scope(scopes, dir, true) end
  end
  if not next(scopes) then return false, "no-directory" end
  opts = common.merge(opts, { reason = reason or opts.reason or "directory-dirty" })
  local matched = false
  for _, index in pairs(indexes) do
    local index_dirs = {}
    for dir in pairs(scopes) do
      if common.path_equals(dir, index.root) or common.path_belongs_to(dir, index.root) then
        index_dirs[#index_dirs + 1] = dir
      end
    end
    if #index_dirs > 0 then
      matched = true
      if index.status == "indexing" then
        index.pending_reindex_dirs = index.pending_reindex_dirs or {}
        for _, dir in ipairs(index_dirs) do
          add_coalesced_scope(index.pending_reindex_dirs, dir, {
            reason = opts.reason or "directory-dirty",
            force = opts.force,
          })
          log_quiet("Tree-sitter Project index: coalesced dirty directory refresh for %s under %s while worker indexing (%s)",
            tostring(dir), tostring(index.root), tostring(opts.reason))
        end
      else
        local submitted, submit_reason = submit_targeted_directories_reindex(index, index_dirs, opts)
        if not submitted then
          index.status = "failed"
          index.symbol_status = "failed"
          index.usage_status = "failed"
          index.reason = submit_reason or "targeted-directory-submit-failed"
          index.finished_at = system.get_time()
          log_quiet("Tree-sitter Project index: targeted directory worker reindex for %d scope(s) under %s failed: %s",
            #index_dirs, tostring(index.root), tostring(submit_reason))
        else
          log_quiet("Tree-sitter Project index: scheduled targeted directory worker reindex for %d dirty scope(s) under %s (%s)",
            #index_dirs, tostring(index.root), tostring(submit_reason or opts.reason or "directory-dirty"))
        end
      end
    end
  end
  return matched, matched and nil or "no-index"
end

function symbol_index.mark_directory_dirty(dir, reason, opts)
  return symbol_index.mark_directories_dirty({ dir }, reason, opts)
end

function symbol_index.mark_file_dirty(path, reason)
  path = path and common.normalize_path(path)
  if not path then return false end
  local info = system.get_file_info(path)
  if info and info.type == "dir" then
    return symbol_index.mark_directory_dirty(path, reason or "dirty")
  end
  return symbol_index.reindex_file(path, { force = true, reason = reason or "dirty" })
end

function symbol_index.current_document_symbols(doc, query, opts)
  opts = opts or {}
  if not doc then return {}, "no-document", "unavailable" end
  local symbols, reason = outline.get_document_outline(doc, opts)
  if not symbols or #symbols == 0 then return {}, reason or "no-symbols", "fresh" end
  local path = doc.abs_filename or doc.filename
  local root = normalize_root(opts.root)
  local relpath = path
  if path and common.path_belongs_to(path, root) then relpath = common.relative_path(root, path):gsub("\\", "/") end
  for _, symbol in ipairs(symbols) do
    symbol.path = path
    symbol.file = relpath or path
    symbol.relpath = relpath or path
    symbol.text = symbol.name
  end
  local results, has_more = filtered_symbols(symbols, query, opts.limit, opts)
  return results, nil, "fresh", { has_more = has_more }
end

function symbol_index.status(root)
  return index_for_root(root)
end

function symbol_index.reset_for_tests()
  for _, index in pairs(indexes) do
    cancel_index_work(index)
    if index.native_snapshot then pcall(index.native_snapshot.close, index.native_snapshot) end
    index.native_snapshot = nil
    index.generation = (index.generation or 0) + 1
    index.watch_generation = (index.watch_generation or 0) + 1
    index.watch_running = false
    index.watcher = nil
    index.watched_dirs = {}
  end
  indexes = {}
  open_documents = setmetatable({}, { __mode = "v" })
end

return symbol_index
