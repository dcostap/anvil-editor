local core = require "core"
local common = require "core.common"
local config = require "core.config"
local project_paths = require "core.project_paths"
local project_files = require "core.project_files"
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
local DEFAULT_QUERY_LIMIT = 200
local DEFAULT_REFRESH_AFTER_SECONDS = 5
local DEFAULT_MATCH_LIMIT = 50000
local DEFAULT_MAX_CAPTURES = 50000
local DEFAULT_QUERY_TIMEOUT_MS = 20
local DEFAULT_PROJECT_USAGE_CAP = 750000
local DEFAULT_SYNC_QUERY_ITEM_LIMIT = 5000
local MAX_FILE_BYTES = 2 * 1024 * 1024

local indexes = {}
local open_buffers = setmetatable({}, { __mode = "v" })

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
  local yieldable = coroutine.isyieldable and coroutine.isyieldable()
    or not coroutine.isyieldable and coroutine.running() ~= nil
  if yieldable then
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
    open_buffers = {},
    open_buffer_jobs = {},
    pending_reindex_paths = {},
    pending_reindex_dirs = {},
    watch_running = false,
    watch_ignored_events = 0,
    watch_irrelevant_events = 0,
    files_total = 0,
    files_scanned = 0,
    files_indexed = 0,
    reason = nil,
    started_at = nil,
    finished_at = nil,
    worker_handle = nil,
    worker_run = nil,
    worker_seen_paths = nil,
    symbol_query_requests = {},
    project_paths_generation = nil,
    overlay_generation = 0,
    combined_symbols_cache = {},
    enclosing_symbol_cache = {},
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
  index.enclosing_symbol_cache = {}
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
    local paths = {}
    for path in pairs(pending) do paths[path] = true end
    if symbol_index.mark_watch_paths_dirty then
      symbol_index.mark_watch_paths_dirty(index.root, paths, "queued-during-indexing", {
        project_files_refreshed = true,
      })
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

local function start_project_watcher(index)
  if not index or index.watch_running then return false end
  index.watch_running = true
  local root = index.root
  project_files.subscribe(root, index, function(changed_paths, event)
    if not index.watch_running then return end
    if event and event.error then
      log_quiet("Tree-sitter Project watcher reconciliation failed for %s: %s",
        tostring(root), tostring(event.error))
    end
    if next(changed_paths or {}) and symbol_index.mark_watch_paths_dirty then
      symbol_index.mark_watch_paths_dirty(root, changed_paths, "project-watch", {
        project_files_refreshed = true,
        previous_membership = event and event.previous_membership,
      })
    end
  end)
  log_quiet("Tree-sitter Project index: subscribed to Project file changes for %s", tostring(root))
  return true
end

local function coalesce_scope_candidates(candidates)
  local scopes = {}
  local processed = 0
  for path, value in pairs(candidates) do
    local ancestor = common.dirname(path)
    local covered = false
    while ancestor and ancestor ~= path do
      if candidates[ancestor] then covered = true; break end
      local parent = common.dirname(ancestor)
      if not parent or parent == ancestor then break end
      ancestor = parent
    end
    if not covered then scopes[path] = value end
    processed = processed + 1
    if processed % 128 == 0 then safe_yield(0) end
  end
  return scopes
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
    if worker.first_skipped_path then
      log_quiet("Tree-sitter Project index: skipped %d file(s) under %s; first=%s reason=%s",
        tonumber(worker.files_skipped or 0) or 0,
        tostring(index.root), tostring(worker.first_skipped_path),
        tostring(worker.first_skipped_reason or "unavailable"))
    end
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
  local symbol_requests = {}
  for request in pairs(index.symbol_query_requests or {}) do
    symbol_requests[#symbol_requests + 1] = request
  end
  for _, request in ipairs(symbol_requests) do
    if request.cancel_stale then
      request:cancel_stale("index-generation-changed")
      cancelled = true
    end
  end
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
  index.enclosing_symbol_cache = {}
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
          invalid_text_files_skipped = p.invalid_text_files_skipped or 0,
          io_files_skipped = p.io_files_skipped or 0,
          parse_files_skipped = p.parse_files_skipped or 0,
          first_skipped_path = p.first_skipped_path,
          first_skipped_reason = p.first_skipped_reason,
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
  if phase == "combined" and not opts.files and not opts.scan_root and not opts.scan_roots then
    index.status = "indexing"
    index.symbol_status = "indexing"
    index.usage_status = "indexing"
    index.reason = opts.reason
    index.started_at = system.get_time()
    index.finished_at = nil
    core.add_thread(function()
      local listed, list_error = project_files.list(index.root, { refresh = true })
      if index.generation ~= generation then return end
      if not listed then
        index.status = "failed"
        index.symbol_status = "failed"
        index.usage_status = "failed"
        index.reason = list_error or "Project file listing failed"
        index.finished_at = system.get_time()
        core.log_quiet("Tree-sitter Project index could not list files under %s: %s",
          tostring(index.root), tostring(index.reason))
        return
      end
      local files = {}
      for i, file in ipairs(listed) do
        files[#files + 1] = { path = file.path }
        if i % 128 == 0 then safe_yield(0) end
      end
      local run_opts = common.merge(opts, { files = files })
      submit_native_run(index, generation, run_opts, phase)
    end)
    return true, "listing"
  end
  submit_native_run(index, generation, opts, phase)
end

function symbol_index.ensure_scan(root, opts)
  opts = opts or {}
  local index = index_for_root(root)
  start_project_watcher(index)
  if index.status == "indexing" and not opts.force then return index end
  if (index.status == "failed" or index.status == "cancelled") and not opts.force then
    return index
  end
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

local refresh_open_buffer_overlays
local overlay_entry_current
local refresh_current_core_buffers_for_index

local function buffer_should_suppress_disk(buffer)
  if not buffer then return false end
  if type(buffer.is_dirty) == "function" then
    local ok, dirty = pcall(buffer.is_dirty, buffer)
    return ok and dirty or false
  end
  return false
end

local function buffer_can_overlay_project_index(buffer)
  return buffer
    and not buffer.disable_language_services
    and not buffer.disable_treesitter
end

local function has_pending_open_buffer_overlay(index)
  return index and index.open_buffer_jobs and next(index.open_buffer_jobs) ~= nil
end

local function overlay_paths(index)
  local paths = {}
  for path in pairs(index.open_buffer_jobs or {}) do paths[path] = true end
  for path, entry in pairs(index.open_buffers or {}) do
    if overlay_entry_current and overlay_entry_current(entry) then paths[path] = true end
  end
  for path, buffer in pairs(open_buffers) do
    if common.path_belongs_to(path, index.root) and buffer_should_suppress_disk(buffer) then paths[path] = true end
  end
  for _, buffer in pairs(core.buffers or {}) do
    local path = buffer and (buffer.abs_filename or buffer.filename)
    path = path and common.normalize_path(path)
    if path and common.path_belongs_to(path, index.root) and buffer_should_suppress_disk(buffer) then paths[path] = true end
  end

  local ordered = {}
  for path in pairs(paths) do ordered[#ordered + 1] = path end
  table.sort(ordered)
  return paths, table.concat(ordered, "\0")
end

overlay_entry_current = function(entry)
  if not entry or not entry.buffer then return false end
  local buffer = entry.buffer
  local ts = buffer.treesitter
  local change_id = buffer.get_change_id and buffer:get_change_id() or 0
  return buffer_can_overlay_project_index(buffer)
    and ts and ts.status == "ready" and entry.change_id == change_id
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
  if refresh_open_buffer_overlays then refresh_open_buffer_overlays(index) end
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
  local overlay = index.open_buffers or {}
  local out = {}
  for _, symbol in ipairs(disk_symbols) do
    if not paths[symbol.path] then
      out[#out + 1] = refresh_project_path_metadata(index, copy_item(symbol), kind)
    end
  end
  for _, entry in pairs(overlay) do
    if overlay_entry_current(entry) then
      for _, symbol in ipairs(entry.symbols or {}) do
        out[#out + 1] = refresh_project_path_metadata(index, copy_item(symbol), kind)
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
  if refresh_open_buffer_overlays then refresh_open_buffer_overlays(index) end
  local overlay = index.open_buffers or {}
  local paths = overlay_paths(index)
  local out = {}
  for _, usage in ipairs((index.usages_by_name or {})[name] or {}) do
    if not paths[usage.path] then
      out[#out + 1] = refresh_project_path_metadata(index, usage, "usages")
    end
  end
  for _, entry in pairs(overlay) do
    if overlay_entry_current(entry) then
      for _, usage in ipairs((entry.usages_by_name or {})[name] or {}) do
        out[#out + 1] = refresh_project_path_metadata(index, usage, "usages")
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

local function point_before_or_equal(line1, col1, line2, col2)
  return line1 < line2 or (line1 == line2 and col1 <= col2)
end

local function symbol_contains_point(symbol, line, col)
  local start_line = tonumber(symbol and symbol.start_line)
  local start_col = tonumber(symbol and symbol.start_col)
  local end_line = tonumber(symbol and symbol.end_line)
  local end_col = tonumber(symbol and symbol.end_col)
  if not (start_line and start_col and end_line and end_col) then return false end
  return point_before_or_equal(start_line, start_col, line, col)
    and (line < end_line or (line == end_line and col < end_col))
end

local function enclosing_symbol_from_list(symbols, line, col, kinds)
  local allowed
  if kinds and #kinds > 0 then
    allowed = {}
    for _, kind in ipairs(kinds) do allowed[kind] = true end
  end
  local best
  for _, symbol in ipairs(symbols or {}) do
    if (not allowed or allowed[symbol.kind]) and symbol_contains_point(symbol, line, col) then
      if not best or (tonumber(symbol.depth) or 0) >= (tonumber(best.depth) or 0) then
        best = symbol
      end
    end
  end
  return best and public_symbol(best) or nil
end

function symbol_index.enclosing_symbol(path, line, col, opts)
  opts = opts or {}
  path = path and common.normalize_path(path) or nil
  line = math.floor(tonumber(line) or 0)
  col = math.floor(tonumber(col) or 1)
  if not path or path == "" or line < 1 or col < 1 then return nil, "invalid-location" end

  for _, root in ipairs(project_path_roots("symbols", opts)) do
    if common.path_belongs_to(path, root) then
      local index = indexes[root]
      if not index then return nil, "index-unavailable" end
      refresh_current_core_buffers_for_index(index)
      if refresh_open_buffer_overlays then refresh_open_buffer_overlays(index) end

      local overlay = index.open_buffers and index.open_buffers[path]
      if overlay_entry_current(overlay) then
        return enclosing_symbol_from_list(overlay.symbols, line, col, opts.kinds), nil
      end

      local suppressed = overlay_paths(index)
      if suppressed[path] then return nil, "overlay-indexing" end
      local snapshot = index.native_snapshot
      if not snapshot or type(snapshot.enclosing_symbol) ~= "function" then
        return nil, index.symbol_status == "indexing" and "indexing" or "index-unavailable"
      end

      local kinds = opts.kinds or opts.symbol_kinds
      local cache = index.enclosing_symbol_cache or {}
      index.enclosing_symbol_cache = cache
      local key = table.concat({ path, tostring(line), tostring(col), table.concat(kinds or {}, "\0") }, "\1")
      local cached = cache[key]
      if cached and cached.snapshot == snapshot and cached.overlay_generation == (index.overlay_generation or 0) then
        return cached.symbol, nil
      end

      local ok, symbol = pcall(snapshot.enclosing_symbol, snapshot, path, line, col, { kinds = kinds })
      if not ok then
        log_quiet("Tree-sitter Project enclosing symbol lookup failed for %s:%d:%d: %s",
          tostring(path), line, col, tostring(symbol))
        return nil, "lookup-failed"
      end
      symbol = symbol and public_symbol(symbol) or nil
      cache[key] = {
        snapshot = snapshot,
        overlay_generation = index.overlay_generation or 0,
        symbol = symbol,
      }
      return symbol, nil
    end
  end
  return nil, "outside-project"
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

local function symbol_kind_allowed(symbol, kinds)
  if not kinds or #kinds == 0 then return true end
  for _, kind in ipairs(kinds) do
    if symbol.kind == kind then return true end
  end
  return false
end

local function filtered_symbols(symbols, query, limit, opts)
  symbols = symbols or {}
  opts = opts or {}
  local kinds = opts.symbol_kinds or opts.kinds
  if kinds and #kinds > 0 then
    local allowed = {}
    for _, symbol in ipairs(symbols) do
      if symbol_kind_allowed(symbol, kinds) then allowed[#allowed + 1] = symbol end
    end
    symbols = allowed
  end
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

refresh_current_core_buffers_for_index = function(index)
  -- Query paths must not synchronously extract open-buffer overlays. Open
  -- Buffers are remembered here only so dirty Buffers can suppress stale disk
  -- entries; overlay records are updated by the Tree-sitter parse-ready hook.
  if not index then return end
  for _, buffer in pairs(core.buffers or {}) do
    local path = buffer and (buffer.abs_filename or buffer.filename)
    path = path and common.normalize_path(path)
    if path and common.path_belongs_to(path, index.root) then open_buffers[path] = buffer end
  end
end

local function merge_status(current, next_status)
  if current == "pending" or next_status == "pending" then return "pending" end
  if current == "stale" or next_status == "stale" then return "stale" end
  if current == "unavailable" or next_status == "unavailable" then return "unavailable" end
  return "fresh"
end

local function native_query_path_rules(index, snapshot, kind)
  refresh_current_core_buffers_for_index(index)
  if refresh_open_buffer_overlays then refresh_open_buffer_overlays(index) end
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
  for path, entry in pairs(index.open_buffers or {}) do
    if suppressed[path] and overlay_entry_current(entry) then
      for _, symbol in ipairs(entry.symbols or {}) do
        if symbol_kind_allowed(symbol, kinds)
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
  return results, page.has_more or overlay_more or merged_more, has_pending_open_buffer_overlay(index)
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
      refresh_current_core_buffers_for_index(index)
      if has_pending_open_buffer_overlay(index) then
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
    elseif (disk_symbol_count > 0 or next(index.open_buffers or {}) ~= nil) and opts.allow_stale then
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
    elseif index.symbol_status == "failed" or index.symbol_status == "cancelled" then
      root_status = "unavailable"
      reason = reason or index.reason or index.symbol_status
    else
      reason = reason or "indexing"
    end
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = { root = root, status = root_status, index = index }
  end

  if any_usable and status ~= "fresh" and not opts.allow_stale then
    return nil, reason or "indexing", status == "unavailable" and "unavailable" or "pending",
      { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
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
  return nil, reason or "indexing", status == "unavailable" and "unavailable" or "pending",
    { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
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

local function native_workspace_symbols_async(query, opts, roots)
  local pool = worker_pool.system()
  local project_paths_generation = project_paths_module().generation()
  local children, per_root = {}, {}
  local candidate_limit = math.min(4096,
    math.max(0, math.floor(tonumber(opts.limit) or DEFAULT_QUERY_LIMIT)) + 1)

  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    local snapshot = index.symbol_status == "ready" and index.native_snapshot
      or (opts.allow_stale and (index.native_partial_snapshot or index.native_snapshot))
    if not snapshot then
      local status = index.symbol_status == "failed" and "unavailable" or "pending"
      return nil, index.reason or (status == "pending" and "indexing" or status), status, {
        roots = per_root, index = #roots == 1 and index or nil,
      }
    end
    refresh_current_core_buffers_for_index(index)
    if has_pending_open_buffer_overlay(index) then
      return nil, "overlay-indexing", "pending", { roots = per_root, index = #roots == 1 and index or nil }
    end
    local excluded, included, suppressed = native_query_path_rules(index, snapshot, opts.kind or "symbols")
    local overlays, overlay_more = bounded_overlay_symbols(index, suppressed, query, opts, candidate_limit)
    local child = {
      root = root,
      index = index,
      snapshot = snapshot,
      generation = index.generation,
      overlay_generation = index.overlay_generation,
      project_paths_generation = index.project_paths_generation,
      excluded = excluded,
      included = included,
      overlays = overlays,
      overlay_more = overlay_more,
      source_status = index.symbol_status == "ready" and "fresh" or "stale",
    }
    children[#children + 1] = child
    per_root[#per_root + 1] = { root = root, status = "pending", index = index }
  end

  local request = {
    status = "pending",
    reason = "querying",
    results = nil,
    handles = {},
    children = children,
    meta = { roots = per_root, index = #children == 1 and children[1].index or nil },
    remaining = #children,
    diagnostics = { native_query_ms = 0 },
  }

  local function unregister()
    for _, child in ipairs(children) do
      if child.index.symbol_query_requests then
        child.index.symbol_query_requests[request] = nil
      end
    end
  end

  local function cancel_handles()
    for _, handle in ipairs(request.handles) do pool:cancel(handle) end
  end

  function request:cancel()
    if self.done then return false end
    self.cancelled = true
    self.status = "cancelled"
    self.reason = "cancelled"
    self.results = nil
    self.done = true
    cancel_handles()
    unregister()
    return true
  end

  function request:cancel_stale(reason)
    if self.done then return false end
    self.status = "stale-cancelled"
    self.reason = reason or "index-generation-changed"
    self.results = nil
    self.done = true
    cancel_handles()
    unregister()
    return true
  end

  local function fail(reason)
    if request.done then return end
    request.status = "unavailable"
    request.reason = reason or "native-project-symbol-query-failed"
    request.results = nil
    request.done = true
    cancel_handles()
    unregister()
  end

  local function finalize()
    if request.done or request.remaining > 0 then return end
    if project_paths_module().generation() ~= project_paths_generation then
      request:cancel_stale("project-paths-generation-changed")
      return
    end
    local combined, has_more, source_status = {}, false, "fresh"
    for child_index, child in ipairs(children) do
      if child.index.generation ~= child.generation
      or child.index.overlay_generation ~= child.overlay_generation
      or child.index.project_paths_generation ~= child.project_paths_generation then
        request:cancel_stale("index-generation-changed")
        return
      end
      local kind = opts.kind or "symbols"
      for _, symbol in ipairs(child.symbols or {}) do
        combined[#combined + 1] = public_symbol(
          refresh_project_path_metadata(child.index, symbol, kind)
        )
      end
      for _, symbol in ipairs(child.overlays or {}) do
        combined[#combined + 1] = public_symbol(
          refresh_project_path_metadata(child.index, symbol, kind)
        )
      end
      has_more = has_more or child.has_more or child.overlay_more
      if child.source_status == "stale" then source_status = "stale" end
      request.meta.roots[child_index].status = child.source_status
    end
    if #children > 1 then sort_symbols(combined) end
    local results, filtered_more = filtered_symbols(combined, query, opts.limit, opts)
    request.results = results
    request.has_more = has_more or filtered_more
    request.meta.has_more = request.has_more
    request.status = source_status
    request.reason = source_status == "stale" and "indexing" or nil
    request.done = true
    unregister()
  end

  for _, child in ipairs(children) do
    child.index.symbol_query_requests = child.index.symbol_query_requests or {}
    child.index.symbol_query_requests[request] = true
    local handle, submit_error = pool:submit({
      kind = "project_snapshot_query_symbols",
      native = true,
      native_kind = "project_snapshot_query_symbols",
      priority = "interactive",
      generation = child.generation,
      project_paths_generation = child.project_paths_generation,
      phase = "symbols-query",
      native_payload = {
        query_snapshot = child.snapshot,
        value = tostring(query or ""),
        offset = 0,
        limit = candidate_limit,
        kinds = opts.symbol_kinds or opts.kinds,
        parent_names = opts.parent_names,
        query_languages = opts.language_ids or opts.languages,
        excluded_paths = child.excluded,
        included_paths = child.included,
      },
      is_stale = function()
        if request.done then return true end
        if project_paths_module().generation() ~= project_paths_generation then
          request:cancel_stale("project-paths-generation-changed")
          return true
        end
        if child.index.generation ~= child.generation
        or child.index.overlay_generation ~= child.overlay_generation
        or child.index.project_paths_generation ~= child.project_paths_generation then
          request:cancel_stale("index-generation-changed")
          return true
        end
        return false
      end,
      on_result = function(message)
        if request.done or message.type ~= "result" then return end
        local payload = message.payload or {}
        child.symbols = payload.symbols or {}
        child.has_more = child.symbols.has_more and true or false
        local query_ms = tonumber(child.symbols.query_ms) or 0
        request.diagnostics.native_query_ms = request.diagnostics.native_query_ms + query_ms
        add_ui_metric(child.index, "native_symbol_query_ms", query_ms)
        max_ui_metric(child.index, "native_symbol_query_max_ms", query_ms)
        inc_ui_metric(child.index, "native_symbol_queries", 1)
      end,
      on_error = function(message) fail(message.error) end,
      on_cancelled = function()
        if not request.done then fail("cancelled") end
      end,
      on_complete = function()
        if request.done then return end
        child.complete = true
        request.remaining = request.remaining - 1
        finalize()
      end,
    })
    if not handle then
      fail(submit_error)
      return request, submit_error, "pending", request.meta
    end
    child.handle = handle
    request.handles[#request.handles + 1] = handle
    request.handle = request.handle or handle
  end
  return request, nil, "pending", request.meta
end

function symbol_index.workspace_symbols_async(query, opts)
  opts = opts or {}
  local roots = project_path_roots("symbols", opts)
  local any_native = false
  for _, root in ipairs(roots) do
    local index = index_for_root(root)
    if index.native_snapshot or index.native_partial_snapshot then any_native = true; break end
  end
  if any_native then return native_workspace_symbols_async(query, opts, roots) end

  local results, reason, status, meta = symbol_index.workspace_symbols(query, opts)
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
  for path, entry in pairs(index.open_buffers or {}) do
    if suppressed[path] and overlay_entry_current(entry) then
      for _, usage in ipairs((entry.usages_by_name or {})[name] or {}) do
        if include_declaration or not usage.is_declaration then
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
  return combined, has_more, has_pending_open_buffer_overlay(index)
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
      refresh_current_core_buffers_for_index(index)
      if has_pending_open_buffer_overlay(index) then
        reason = reason or "overlay-indexing"
      elseif #((index.usages_by_name or {})[name] or {}) > sync_limit and not opts.allow_large_sync_query then
        reason = reason or "query-too-large"
      else
        refresh_current_core_buffers_for_index(index)
        local source = combined_usages_for_name(index, name)
        if single_root and #all_usages == 0 then
          all_usages = source
        else
          for _, usage in ipairs(source) do all_usages[#all_usages + 1] = usage end
        end
        root_status = "fresh"
        any_usable = true
      end
    elseif opts.allow_stale and ((index.usages_by_name or {})[name] or next(index.open_buffers or {}) ~= nil) then
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
    elseif index.usage_status == "failed" or index.usage_status == "cancelled" then
      root_status = "unavailable"
      reason = reason or index.reason or index.usage_status
    else
      reason = reason or "indexing"
    end
    usage_truncated = usage_truncated or index.usage_truncated or false
    usage_truncated_reason = usage_truncated_reason or index.usage_truncated_reason
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = { root = root, status = root_status, index = index }
  end

  if any_usable and status ~= "fresh" and not opts.allow_stale then
    return nil, reason or "indexing", status == "unavailable" and "unavailable" or "pending",
      { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
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
  return nil, reason or "indexing", status == "unavailable" and "unavailable" or "pending",
    { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
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

local function buffer_path(buffer)
  local path = buffer and (buffer.abs_filename or buffer.filename)
  return path and common.normalize_path(path) or nil
end

local function buffer_lines(buffer)
  return buffer and buffer.lines or nil
end

local function buffer_text_from_lines(lines)
  if type(lines) ~= "table" then return nil, "missing-lines" end
  return table.concat(lines, "\n")
end

local function cancel_open_buffer_job(index, path)
  local job = index and index.open_buffer_jobs and index.open_buffer_jobs[path]
  if job and job.handle then worker_pool.system():cancel(job.handle) end
  if index and index.open_buffer_jobs then index.open_buffer_jobs[path] = nil end
end

local function submit_open_buffer_overlay(index, buffer, path, reason)
  if not buffer_can_overlay_project_index(buffer) then return false, "disabled" end
  local ts = buffer and buffer.treesitter
  if not ts or ts.status ~= "ready" then return false, "not-ready" end
  local language = ts.language
  if not language then return false, "missing-language" end
  local text, text_err = buffer_text_from_lines(buffer_lines(buffer))
  if not text then return false, text_err or "missing-lines" end
  if #text > MAX_FILE_BYTES then return false, "too-large" end

  local change_id = buffer.get_change_id and buffer:get_change_id() or 0
  local project_paths_generation = index.project_paths_generation or project_paths_module().generation()
  cancel_open_buffer_job(index, path)
  index.open_buffer_jobs = index.open_buffer_jobs or {}
  local job = {
    buffer = buffer,
    path = path,
    change_id = change_id,
    generation = index.generation,
    project_paths_generation = project_paths_generation,
  }
  index.open_buffer_jobs[path] = job

  local function current()
    local active = index.open_buffer_jobs and index.open_buffer_jobs[path]
    local current_change_id = buffer.get_change_id and buffer:get_change_id() or 0
    return active == job
       and index.generation == job.generation
       and current_change_id == change_id
       and common.path_belongs_to(path, index.root)
  end

  local sources = language.query_sources or {}
  local usage_kind = usage_query_kind(language)
  local handle, err = worker_pool.system():submit({
    kind = "treesitter_open_buffer_overlay",
    native = true,
    native_kind = "treesitter_index_text",
    priority = "interactive",
    generation = index.generation,
    project_paths_generation = project_paths_generation,
    phase = "open-buffer-overlay",
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
        buffer = buffer,
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
      index.open_buffers[path] = file
      bump_overlay_generation(index)
      core.redraw = true
    end,
    on_complete = function()
      if current() then
        index.open_buffer_jobs[path] = nil
        log_quiet("Tree-sitter Project index: updated open buffer overlay for %s (%s)", tostring(path), tostring(reason or "change"))
      end
    end,
    on_error = function(message)
      if current() then
        index.open_buffer_jobs[path] = nil
        if index.open_buffers[path] then
          index.open_buffers[path] = nil
          bump_overlay_generation(index)
        end
        log_quiet("Tree-sitter Project index: skipped open buffer overlay for %s under %s: %s", tostring(path), tostring(index.root), tostring(message and message.error or "overlay-failed"))
      end
    end,
    on_cancelled = function()
      if current() then index.open_buffer_jobs[path] = nil end
    end,
  })
  if not handle then
    index.open_buffer_jobs[path] = nil
    return false, err or "submit-failed"
  end
  job.handle = handle
  return true, "scheduled"
end

refresh_open_buffer_overlays = function(index)
  if not index then return false end
  local changed = false
  local seen = {}
  local buffers = {}
  for path, buffer in pairs(open_buffers) do buffers[path] = buffer end
  for _, buffer in pairs(core.buffers or {}) do
    local path = buffer_path(buffer)
    if path then buffers[path] = buffer end
  end
  for path, buffer in pairs(buffers) do
    if path and common.path_belongs_to(path, index.root) then
      seen[path] = true
      local current = index.open_buffers[path]
      local change_id = buffer.get_change_id and buffer:get_change_id() or 0
      if not buffer_can_overlay_project_index(buffer) then
        local job = index.open_buffer_jobs and index.open_buffer_jobs[path]
        if job then cancel_open_buffer_job(index, path); changed = true end
        if current then index.open_buffers[path] = nil; changed = true end
      elseif not current or current.buffer ~= buffer or current.change_id ~= change_id then
        local scheduled = submit_open_buffer_overlay(index, buffer, path, "refresh")
        changed = scheduled or changed
      end
    end
  end
  for path, entry in pairs(index.open_buffers or {}) do
    if not seen[path] or not entry.buffer then
      cancel_open_buffer_job(index, path)
      index.open_buffers[path] = nil
      changed = true
    end
  end
  if changed then bump_overlay_generation(index) end
  return changed
end

function symbol_index.remember_open_buffer(buffer)
  local path = buffer_path(buffer)
  if not path then return false, "no-path" end
  open_buffers[path] = buffer
  return true
end

function symbol_index.update_open_buffer(buffer, reason)
  local path = buffer_path(buffer)
  if not path then return false, "no-path" end
  open_buffers[path] = buffer
  local updated = false
  local change_id = buffer.get_change_id and buffer:get_change_id() or 0
  for _, index in pairs(indexes) do
    if common.path_belongs_to(path, index.root) then
      local current = index.open_buffers[path]
      if current and current.buffer == buffer and current.change_id == change_id then
        updated = true
      else
        local scheduled, err = submit_open_buffer_overlay(index, buffer, path, reason)
        if scheduled then
          updated = true
        else
          cancel_open_buffer_job(index, path)
          if index.open_buffers[path] then bump_overlay_generation(index) end
          index.open_buffers[path] = nil
          log_quiet("Tree-sitter Project index: skipped open buffer overlay for %s under %s: %s", tostring(path), tostring(index.root), tostring(err))
        end
      end
    end
  end
  if updated then
    core.redraw = true
    log_quiet("Tree-sitter Project index: updated open buffer overlay for %s (%s)", tostring(path), tostring(reason or "change"))
  end
  return updated
end

function symbol_index.clear_open_buffer(buffer, reason)
  local path = buffer_path(buffer)
  local cleared = false
  for open_path, open_buffer in pairs(open_buffers) do
    if (path and open_path == path) or open_buffer == buffer then
      open_buffers[open_path] = nil
      cleared = true
    end
  end
  for _, index in pairs(indexes) do
    local index_cleared = false
    for overlay_path, entry in pairs(index.open_buffers or {}) do
      if (path and overlay_path == path) or entry.buffer == buffer then
        cancel_open_buffer_job(index, overlay_path)
        index.open_buffers[overlay_path] = nil
        cleared = true
        index_cleared = true
      end
    end
    for overlay_path, job in pairs(index.open_buffer_jobs or {}) do
      if (path and overlay_path == path) or job.buffer == buffer then
        cancel_open_buffer_job(index, overlay_path)
        cleared = true
      end
    end
    if index_cleared then bump_overlay_generation(index) end
  end
  if cleared then
    core.redraw = true
    log_quiet("Tree-sitter Project index: cleared open buffer overlay for %s (%s)", tostring(path or buffer), tostring(reason or "clear"))
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

  local reconciled, reconcile_error = project_files.reconcile(index.root, { [path] = true })
  if not reconciled then return false, reconcile_error or "Project file reconciliation failed" end
  local included = project_files.contains(index.root, path, "file") == true
  local info = system.get_file_info(path)
  if index.native_snapshot then
    local language = included and info and info.type == "file" and registry.get(path) or nil
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
      if info and info.type == "dir" then
        scan_roots[#scan_roots + 1] = dir
        remove_paths[#remove_paths + 1] = dir
      else remove_paths[#remove_paths + 1] = dir end
    end
    local listed = project_files.cached(index.root)
    local files
    if listed then
      files = {}
      local scan_scope_keys = {}
      for _, scan_root in ipairs(scan_roots) do
        scan_scope_keys[common.path_compare_key(scan_root)] = true
      end
      for i, file in ipairs(listed) do
        local directory = common.dirname(file.path)
        while directory and (common.path_equals(directory, index.root)
          or common.path_belongs_to(directory, index.root))
        do
          if scan_scope_keys[common.path_compare_key(directory)] then
            files[#files + 1] = { path = file.path }
            break
          end
          if common.path_equals(directory, index.root) then break end
          directory = common.dirname(directory)
        end
        if i % 128 == 0 then safe_yield(0) end
      end
    end
    index.generation = (index.generation or 0) + 1
    local scheduled, reason = submit_native_run(index, index.generation, {
      reason = opts.reason or "directory-dirty",
      base_snapshot = index.native_snapshot,
      remove_paths = remove_paths,
      scan_roots = files and nil or scan_roots,
      files = files,
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
  local candidates = {}
  for key, value in pairs(dirs) do
    local dir = type(key) == "number" and value or key
    dir = dir and common.normalize_path(dir)
    if dir then candidates[dir] = true end
  end
  local scopes = coalesce_scope_candidates(candidates)
  if not next(scopes) then return false, "no-directory" end
  opts = common.merge(opts, { reason = reason or opts.reason or "directory-dirty" })
  local matched = false
  local ignored = false
  for _, index in pairs(indexes) do
    if not opts.project_files_refreshed then
      local reconciled, reconcile_error = project_files.reconcile(index.root, scopes)
      if not reconciled then
        log_quiet("Tree-sitter Project directory reconciliation failed under %s: %s",
          tostring(index.root), tostring(reconcile_error))
      end
    end
    local index_dirs = {}
    for dir in pairs(scopes) do
      if common.path_equals(dir, index.root) or common.path_belongs_to(dir, index.root) then
        local allowed = true
        local listed = project_files.contains(index.root, dir, "dir")
        if listed ~= nil then allowed = allowed and listed end
        if allowed then index_dirs[#index_dirs + 1] = dir
        else ignored = true end
      end
    end
    if #index_dirs > 0 then
      matched = true
      if index.status == "indexing" then
        index.pending_reindex_dirs = index.pending_reindex_dirs or {}
        for _, dir in ipairs(index_dirs) do
          index.pending_reindex_dirs[dir] = {
            reason = opts.reason or "directory-dirty",
            force = opts.force,
          }
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
  return matched, matched and nil or (ignored and "ignored" or "no-index")
end

function symbol_index.mark_directory_dirty(dir, reason, opts)
  return symbol_index.mark_directories_dirty({ dir }, reason, opts)
end

local function watch_path_allowed(index, path, info, assumed_type)
  local kind = (info and info.type) or assumed_type or "file"
  local listed = project_files.contains(index.root, path, kind)
  if listed ~= nil then return listed end
  return true
end

local function has_project_index_provider(path)
  local language = registry.get(path)
  return language and language.query_sources and language.query_sources.outline ~= nil
end

local function ignore_rules_scope(root, path)
  local name = common.basename(path)
  if name == ".gitignore" or name == ".ignore" or name == ".rgignore" then
    return common.dirname(path)
  end
  local parent = common.dirname(path)
  if name == "exclude" and common.basename(parent) == "info"
    and common.basename(common.dirname(parent)) == ".git"
  then
    return root
  end
end

---Turn changed filesystem leaf paths into the smallest relevant directory
---refresh scopes. Files that cannot contribute to the Project symbol index are
---discarded before a native worker job is submitted.
---@param root string
---@param paths table<string, boolean>|string[]
---@param reason? string
---@param opts? table
---@return boolean matched
---@return string? reason
function symbol_index.mark_watch_paths_dirty(root, paths, reason, opts)
  root = normalize_root(root)
  if type(paths) ~= "table" then return false, "no-path" end
  local index = indexes[root]
  if not index then return false, "no-index" end

  local old_membership = {}
  local processed = 0
  for key, value in pairs(paths) do
    local path = type(key) == "number" and value or key
    if path then
      local normalized = common.normalize_path(path)
      local previous = opts and opts.previous_membership
      if previous and previous[normalized] ~= nil then
        old_membership[normalized] = previous[normalized]
      else
        old_membership[normalized] = project_files.contains(root, path, "file") == true
          or project_files.contains(root, path, "dir") == true
      end
    end
    processed = processed + 1
    if processed % 128 == 0 then safe_yield(0) end
  end
  local files_current = opts and opts.project_files_refreshed == true
  if not files_current then
    local reconciled, reconcile_error = project_files.reconcile(root, paths)
    files_current = reconciled == true
    if not reconciled then
      log_quiet("Tree-sitter Project watcher could not reconcile Project files under %s: %s",
        tostring(root), tostring(reconcile_error))
    end
  end

  local scope_candidates = {}
  local ignored, irrelevant = 0, 0
  processed = 0
  for key, value in pairs(paths) do
    local path = type(key) == "number" and value or key
    path = path and common.normalize_path(path)
    if path and (common.path_equals(path, root) or common.path_belongs_to(path, root)) then
      local rules_scope = ignore_rules_scope(root, path)
      if rules_scope then
        scope_candidates[rules_scope] = true
      else
        local info = system.get_file_info(path)
        if info and info.type == "dir" then
          if watch_path_allowed(index, path, info, "dir") then
            scope_candidates[path] = true
          else
            ignored = ignored + 1
          end
        elseif not info then
          -- The watcher cannot reliably distinguish a removed file from a
          -- removed directory after the path is gone. Conservatively refresh the
          -- parent: dotted directories can contain indexed descendants and must
          -- not leave stale symbols behind.
          local parent = common.dirname(path)
          if not old_membership[path] and not watch_path_allowed(index, path, nil, "dir") then
            ignored = ignored + 1
          elseif watch_path_allowed(index, parent, system.get_file_info(parent), "dir") then
            scope_candidates[parent] = true
          else
            ignored = ignored + 1
          end
        elseif has_project_index_provider(path) then
          -- Do not size-filter source paths here. A file that grew beyond the
          -- native scan cap may already have records in the current snapshot;
          -- refreshing its scope is what removes those now-stale records.
          if watch_path_allowed(index, path, info, "file") then
            scope_candidates[common.dirname(path)] = true
          else
            ignored = ignored + 1
          end
        else
          irrelevant = irrelevant + 1
        end
      end
    end
    processed = processed + 1
    if processed % 128 == 0 then safe_yield(0) end
  end

  local scopes = coalesce_scope_candidates(scope_candidates)

  index.watch_ignored_events = (index.watch_ignored_events or 0) + ignored
  index.watch_irrelevant_events = (index.watch_irrelevant_events or 0) + irrelevant
  if not next(scopes) then
    return false, ignored > 0 and irrelevant == 0 and "ignored" or "irrelevant"
  end
  return symbol_index.mark_directories_dirty(scopes, reason or "project-watch",
    common.merge(opts or {}, { project_files_refreshed = files_current }))
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

function symbol_index.current_buffer_symbols(buffer, query, opts)
  opts = opts or {}
  if not buffer then return {}, "no-buffer", "unavailable" end
  local symbols, reason = outline.get_buffer_outline(buffer, opts)
  if not symbols or #symbols == 0 then return {}, reason or "no-symbols", "fresh" end
  local path = buffer.abs_filename or buffer.filename
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
    project_files.unsubscribe(index.root, index)
    cancel_index_work(index)
    if index.native_snapshot then pcall(index.native_snapshot.close, index.native_snapshot) end
    index.native_snapshot = nil
    index.generation = (index.generation or 0) + 1
    index.watch_running = false
  end
  indexes = {}
  open_buffers = setmetatable({}, { __mode = "v" })
end

return symbol_index
