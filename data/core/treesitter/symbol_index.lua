local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local DirWatch = require "core.dirwatch"
local registry = require "core.treesitter.registry"
local outline = require "core.treesitter.outline"
local worker_pool = require "core.worker_pool"
local IndexScheduler = require "core.treesitter.index_scheduler"

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
local DEFAULT_AGGREGATE_REBUILD_DELAY = 0.075
local DEFAULT_WORKER_CHUNK_RECORDS = 100
local DEFAULT_ASYNC_SYMBOL_SNAPSHOT_LIMIT = 5000
local DEFAULT_ASYNC_USAGE_SNAPSHOT_LIMIT = 5000
local DEFAULT_ASYNC_OVERLAY_SNAPSHOT_LIMIT = 1000
local DEFAULT_INDEX_BATCH_FILES = 64
local DEFAULT_INDEX_BATCH_BYTES = 4 * 1024 * 1024
local DEFAULT_SHARD_USAGE_BUDGET = 8192
local MAX_FILE_BYTES = 2 * 1024 * 1024

local native_ok, native = nil, nil
local query_cache = {}
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

local function worker_pool_frame_stats()
  local c = package.loaded.core or core
  local stats = c and c.worker_pool_frame_stats
  return type(stats) == "table" and stats or nil
end

local function add_worker_pool_frame_metric(key, value)
  local stats = worker_pool_frame_stats()
  if not stats then return end
  stats[key] = (stats[key] or 0) + (tonumber(value) or 0)
end

local function inc_worker_pool_frame_metric(key, amount)
  add_worker_pool_frame_metric(key, amount or 1)
end

local function max_worker_pool_frame_metric(key, value)
  local stats = worker_pool_frame_stats()
  if not stats then return end
  value = tonumber(value) or 0
  if value > (stats[key] or 0) then stats[key] = value end
end

local function safe_yield(wait)
  if coroutine.isyieldable and coroutine.isyieldable() then
    coroutine.yield(wait)
    return true
  end
  return false
end

local function ensure_native()
  if native_ok == nil then native_ok, native = pcall(require, "treesitter") end
  return native_ok and native or nil
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
    aggregate_dirty = false,
    aggregate_rebuild_pending = false,
    next_aggregate_rebuild_at = nil,
    project_path_metadata_cache = {},
    project_path_metadata_cache_generation = nil,
    query_artifacts = {},
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

local function compile_language_query(language, kind)
  if not language or not language.query_sources or not language.query_sources[kind] then
    return nil, "missing-query"
  end
  local n = ensure_native()
  if not n then return nil, "native-unavailable" end
  local source = language.query_sources[kind]
  local key = table.concat({ tostring(language.grammar), tostring(kind), tostring(source) }, "\0")
  if query_cache[key] ~= nil then return query_cache[key] or nil, query_cache[key] == false and "compile-failed" or nil end
  local query, err = n.compile_query(language.grammar, kind, source)
  if not query then
    query_cache[key] = false
    log_quiet("Tree-sitter Project index: disabled %s query for %s: %s", tostring(kind), tostring(language.id), tostring(err))
    return nil, err or "compile-failed"
  end
  query_cache[key] = query
  return query
end

local function compile_outline_query(language)
  return compile_language_query(language, "outline")
end

local function usage_query_kind(language)
  local sources = language and language.query_sources or {}
  if sources.usages then return "usages" end
  if sources.locals then return "locals" end
end

local function compile_usage_query(language)
  local kind = usage_query_kind(language)
  if not kind then return nil, "missing-query", nil end
  local query, err = compile_language_query(language, kind)
  return query, err, kind
end

local function effective_query_limit(language, prefix, name, default)
  local value = language and language[prefix .. "_" .. name]
  if value == nil and prefix == "usages" then value = language and language["locals_" .. name] end
  return value or default
end

local function file_fingerprint(_path, info, language)
  local sources = language and language.query_sources or {}
  local usage_kind = usage_query_kind(language) or ""
  local usage_source = usage_kind ~= "" and sources[usage_kind] or ""
  local outline_source = sources.outline or ""
  return table.concat({
    tostring(info and info.size or ""),
    tostring(info and info.modified or ""),
    tostring(language and language.id or ""),
    tostring(language and language.grammar or ""),
    tostring(language and language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS),
    tostring(effective_query_limit(language, "outline", "match_limit", DEFAULT_MATCH_LIMIT)),
    tostring(effective_query_limit(language, "outline", "max_captures", DEFAULT_MAX_CAPTURES)),
    tostring(effective_query_limit(language, "outline", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS)),
    tostring(#outline_source),
    outline_source,
    tostring(usage_kind),
    tostring(effective_query_limit(language, "usages", "match_limit", DEFAULT_MATCH_LIMIT)),
    tostring(effective_query_limit(language, "usages", "max_captures", DEFAULT_MAX_CAPTURES)),
    tostring(effective_query_limit(language, "usages", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS)),
    tostring(#usage_source),
    usage_source,
  }, "\0")
end

local function read_file_text(path, info)
  local size = info and tonumber(info.size) or nil
  if size and size > MAX_FILE_BYTES then return nil, "too-large" end
  local fp, err = io.open(path, "rb")
  if not fp then return nil, err or "open-failed" end
  local text = fp:read("*a") or ""
  fp:close()
  if #text > MAX_FILE_BYTES then return nil, "too-large" end
  return text:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function lines_from_text(text)
  local lines = {}
  local pos = 1
  text = tostring(text or "")
  while pos <= #text do
    local nl = text:find("\n", pos, true)
    if nl then
      lines[#lines + 1] = text:sub(pos, nl)
      pos = nl + 1
    else
      lines[#lines + 1] = text:sub(pos)
      break
    end
  end
  if #lines == 0 then lines[1] = "\n" end
  return lines
end

local function wait_parse(state, generation, timeout)
  local deadline = system.get_time() + (timeout or 3)
  local status, changed, discarded
  while system.get_time() < deadline do
    status, changed, discarded = state:poll(generation)
    if status == "ready" or status == "failed" or changed or discarded then break end
    if not safe_yield(0.01) and system.sleep then system.sleep(0.01) end
  end
  if status ~= "ready" and not state:has_tree() then return nil, status or "timeout" end
  return true
end

local function lines_byte_len(lines)
  local total = 0
  for i = 1, #(lines or {}) do total = total + #(lines[i] or "") end
  return total
end

local function text_for_capture(lines, capture)
  if not capture then return "" end
  local start_line = capture.start_line or 1
  local end_line = capture.end_line or start_line
  local start_col = capture.start_col or 1
  local end_col = capture.end_col or start_col
  if start_line == end_line then
    local line = lines[start_line] or ""
    return line:sub(start_col, math.max(start_col - 1, end_col - 1))
  end
  local parts = {}
  for line_idx = start_line, end_line do
    local line = lines[line_idx] or ""
    if line_idx == start_line then
      parts[#parts + 1] = line:sub(start_col)
    elseif line_idx == end_line then
      parts[#parts + 1] = line:sub(1, math.max(0, end_col - 1))
    else
      parts[#parts + 1] = line
    end
  end
  return table.concat(parts)
end

local function capture_kind(capture_name)
  return tostring(capture_name or ""):match("^definition%.(.+)$")
end

local function is_usage_capture(capture)
  local name = capture and capture.capture
  if not name then return false end
  return name == "reference"
      or name == "usage"
      or tostring(name):match("^usage%.") ~= nil
      or capture_kind(name) ~= nil
end

local function apply_project_path_metadata(item, path, kind)
  if not project_paths_module().resolve(path) then return item end
  local display = project_paths_module().display_path(path, { kind = kind })
  if display then
    item.display_file = display.text
    item.file = display.text
    item.relpath = display.text
    item.root_label = display.root_label
    item.root_role = display.root_role
    item.root_id = display.root_id
    item.rank_penalty = display.rank_penalty
  end
  return item
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
    inc_worker_pool_frame_metric("treesitter_project_metadata_cache_hits", 1)
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
      metadata.rank_penalty = display.rank_penalty
    end
  end

  cache[key] = metadata
  inc_ui_metric(index, "project_path_metadata_cache_misses", 1)
  inc_worker_pool_frame_metric("treesitter_project_metadata_cache_misses", 1)
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
  item.rank_penalty = metadata.rank_penalty
  return item
end

local function usage_from_capture(path, relpath, lines, language, capture)
  local text = text_for_capture(lines, capture)
  if text == "" then return nil end
  local definition_kind = capture_kind(capture.capture)
  local line = lines[capture.start_line] or ""
  return apply_project_path_metadata({
    name = text,
    kind = definition_kind or "usage",
    capture = capture.capture,
    is_declaration = definition_kind ~= nil,
    path = path,
    file = relpath or path,
    relpath = relpath or path,
    language_id = language.id,
    text = text,
    line_text = line:gsub("\n$", ""),
    start_line = capture.start_line,
    start_col = capture.start_col,
    end_line = capture.end_line,
    end_col = capture.end_col,
    start_byte = capture.start_byte,
    end_byte = capture.end_byte,
    range = {
      start = { line = capture.start_line, col = capture.start_col },
      ["end"] = { line = capture.end_line, col = capture.end_col },
    },
    workspace_tree_sitter_fallback = true,
  }, path, "usages")
end

local function add_usage(usages_by_name, item)
  if not item then return false end
  local list = usages_by_name[item.name]
  if not list then
    list = {}
    usages_by_name[item.name] = list
  end
  list[#list + 1] = item
  return true
end

local function count_usages(usages_by_name)
  local count = 0
  for _, list in pairs(usages_by_name or {}) do count = count + #list end
  return count
end

local function extract_symbols_from_doc(doc, path, relpath, language)
  local symbols = outline.get_document_outline(doc) or {}
  for _, symbol in ipairs(symbols) do
    symbol.path = path
    symbol.file = relpath or path
    symbol.relpath = relpath or path
    symbol.language_id = language.id
    symbol.text = symbol.name
    apply_project_path_metadata(symbol, path, "symbols")
  end
  return symbols
end

local function query_usages_from_state(state, query, lines, language, opts)
  opts = opts or {}
  local captures, err = state:query_captures(query, 0, lines_byte_len(lines), {
    match_limit = opts.match_limit or effective_query_limit(language, "usages", "match_limit", DEFAULT_MATCH_LIMIT),
    max_captures = opts.max_captures or effective_query_limit(language, "usages", "max_captures", DEFAULT_MAX_CAPTURES),
    timeout_ms = opts.timeout_ms or effective_query_limit(language, "usages", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS),
  })
  if not captures then return nil, err or "query-failed" end
  return captures
end

local function extract_usages_from_state(state, query, path, relpath, lines, language, opts)
  if not query then return {}, 0 end
  local captures, err = query_usages_from_state(state, query, lines, language, opts)
  if not captures then return nil, err end

  local by_range = {}
  for _, capture in ipairs(captures) do
    if is_usage_capture(capture) then
      local item = usage_from_capture(path, relpath, lines, language, capture)
      if item then
        local key = table.concat({ item.name, tostring(item.start_byte or 0), tostring(item.end_byte or 0) }, "\0")
        local existing = by_range[key]
        if not existing or (item.is_declaration and not existing.is_declaration) then
          by_range[key] = item
        end
      end
    end
  end

  local usages_by_name = {}
  local count = 0
  for _, item in pairs(by_range) do
    if add_usage(usages_by_name, item) then count = count + 1 end
  end
  return usages_by_name, count
end

local function parse_file_index(path, relpath, info, language, opts)
  opts = opts or {}
  local n = ensure_native()
  if not n then return nil, "native-unavailable" end
  if not n.has_language or not n.has_language(language.grammar) then return nil, "missing-grammar" end
  local outline_query, err = compile_outline_query(language)
  if not outline_query then return nil, err or "missing-query" end
  local usage_query = nil
  if opts.include_usages ~= false then
    usage_query = compile_usage_query(language)
  end
  local text
  text, err = read_file_text(path, info)
  if not text then return nil, err end
  local lines = lines_from_text(text)

  local state
  state, err = n.new_document_state(language.grammar, {
    parse_timeout_ms = language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS,
  })
  if not state then return nil, err or "state-failed" end
  local ok
  ok, err = state:schedule_parse(lines, 1, nil)
  if not ok then state:close(); return nil, err or "schedule-failed" end
  ok, err = wait_parse(state, 1, 3)
  if not ok then state:close(); return nil, err or "parse-failed" end

  local fake_doc = {
    lines = lines,
    abs_filename = path,
    filename = relpath or path,
    treesitter = {
      status = "ready",
      native = state,
      queries = { outline = outline_query, usages = usage_query },
      language = language,
      language_id = language.id,
      grammar = language.grammar,
      stale_unrenderable = false,
    },
    get_name = function() return relpath or path end,
    get_change_id = function() return 0 end,
  }
  local symbols = extract_symbols_from_doc(fake_doc, path, relpath, language)
  local usages_by_name, usage_count = {}, 0
  local usage_complete = opts.include_usages ~= false
  if usage_query then
    usages_by_name, usage_count = extract_usages_from_state(state, usage_query, path, relpath, lines, language, opts)
    if not usages_by_name then
      log_quiet("Tree-sitter Project usages: skipped usages for %s: %s", tostring(relpath), tostring(usage_count))
      usages_by_name, usage_count = {}, 0
      usage_complete = false
    end
  end
  state:close()
  return {
    symbols = symbols,
    usages_by_name = usages_by_name,
    usage_count = usage_count,
    usage_complete = usage_complete,
  }
end

local function sort_symbols(symbols)
  table.sort(symbols, function(a, b)
    local af, bf = tostring(a.relpath or a.path or ""), tostring(b.relpath or b.path or "")
    if af ~= bf then return af < bf end
    if (a.start_line or 0) ~= (b.start_line or 0) then return (a.start_line or 0) < (b.start_line or 0) end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
end

local function sort_usages(usages)
  table.sort(usages, function(a, b)
    local af, bf = tostring(a.relpath or a.path or ""), tostring(b.relpath or b.path or "")
    if af ~= bf then return af < bf end
    if (a.start_line or 0) ~= (b.start_line or 0) then return (a.start_line or 0) < (b.start_line or 0) end
    if (a.start_col or 0) ~= (b.start_col or 0) then return (a.start_col or 0) < (b.start_col or 0) end
    return tostring(a.capture or "") < tostring(b.capture or "")
  end)
end

local invalidate_index_query_artifacts
local cleanup_index_query_artifacts

local function rebuild_disk_aggregates(index)
  local rebuild_started = now()
  local symbols = {}
  local usages_by_name = {}
  local usage_count = 0
  local cap = tonumber(index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP) or DEFAULT_PROJECT_USAGE_CAP
  index.usage_truncated = false
  index.usage_truncated_reason = nil

  for _, entry in pairs(index.by_path or {}) do
    for _, symbol in ipairs(entry.symbols or {}) do symbols[#symbols + 1] = symbol end
    if entry.usage_complete == false then
      index.usage_truncated = true
      index.usage_truncated_reason = "project-usage-cap"
    end
    for name, list in pairs(entry.usages_by_name or {}) do
      local out = usages_by_name[name]
      if not out then
        out = {}
        usages_by_name[name] = out
      end
      for _, usage in ipairs(list) do
        if usage_count < cap then
          out[#out + 1] = usage
          usage_count = usage_count + 1
        else
          index.usage_truncated = true
          index.usage_truncated_reason = "project-usage-cap"
          break
        end
      end
    end
  end

  sort_symbols(symbols)
  for _, list in pairs(usages_by_name) do sort_usages(list) end
  index.symbols = symbols
  index.usages_by_name = usages_by_name
  index.usage_count = usage_count
  invalidate_combined_symbols_cache(index)
  invalidate_index_query_artifacts(index)
  local duration = elapsed_ms(rebuild_started)
  inc_ui_metric(index, "aggregate_rebuilds", 1)
  add_ui_metric(index, "aggregate_rebuild_ms", duration)
  max_ui_metric(index, "aggregate_rebuild_max_ms", duration)
  inc_ui_metric(index, "aggregate_symbols_sorted", #symbols)
  inc_ui_metric(index, "aggregate_usages_sorted", usage_count)
  inc_worker_pool_frame_metric("treesitter_project_aggregate_rebuilds", 1)
  add_worker_pool_frame_metric("treesitter_project_aggregate_rebuild_ms", duration)
  max_worker_pool_frame_metric("treesitter_project_aggregate_rebuild_max_ms", duration)
  add_worker_pool_frame_metric("treesitter_project_aggregate_symbols_sorted", #symbols)
  add_worker_pool_frame_metric("treesitter_project_aggregate_usages_sorted", usage_count)
  index.aggregate_dirty = false
  index.aggregate_rebuild_pending = false
  index.next_aggregate_rebuild_at = nil
end

local function mark_aggregate_dirty(index)
  if not index then return end
  index.aggregate_dirty = true
  invalidate_combined_symbols_cache(index)
  index.aggregate_rebuild_pending = true
  index.next_aggregate_rebuild_at = index.next_aggregate_rebuild_at or (now() + DEFAULT_AGGREGATE_REBUILD_DELAY)
end

local function maybe_rebuild_dirty_aggregates(index, force)
  if not (index and index.aggregate_dirty) then return false end
  if force or now() >= (index.next_aggregate_rebuild_at or 0) then
    rebuild_disk_aggregates(index)
    return true
  end
  return false
end

local function replace_file_entry(index, path, fingerprint, entry)
  entry = entry or {}
  entry.fingerprint = fingerprint
  entry.symbols = entry.symbols or {}
  entry.usages_by_name = entry.usages_by_name or {}
  entry.usage_count = entry.usage_count or count_usages(entry.usages_by_name)
  if entry.usage_complete == nil then entry.usage_complete = true end
  index.by_path[path] = entry
end

local function append_usages_by_name(target, source)
  for name, list in pairs(source or {}) do
    local out = target[name]
    if not out then
      out = {}
      target[name] = out
    end
    for _, usage in ipairs(list) do out[#out + 1] = usage end
  end
end

local function merge_partial_file_entry(index, path, fingerprint, entry)
  local existing = index.by_path[path]
  if not existing or not existing.partial_adopting or existing.fingerprint ~= fingerprint then
    existing = {}
    for key, value in pairs(entry or {}) do
      if key ~= "symbols" and key ~= "usages_by_name" and key ~= "usage_count"
      and key ~= "partial" and key ~= "file_done" then
        existing[key] = value
      end
    end
    existing.fingerprint = fingerprint
    existing.symbols = entry.symbols or {}
    existing.usages_by_name = {}
    existing.usage_count = 0
    existing.usage_complete = false
    existing.partial_adopting = true
    index.by_path[path] = existing
  elseif #(entry.symbols or {}) > 0 then
    if entry.partial then
      for _, symbol in ipairs(entry.symbols or {}) do existing.symbols[#existing.symbols + 1] = symbol end
    else
      existing.symbols = entry.symbols
    end
  end

  append_usages_by_name(existing.usages_by_name, entry.usages_by_name)
  existing.usage_count = (existing.usage_count or 0) + (entry.usage_count or count_usages(entry.usages_by_name))
  if entry.file_done then
    existing.usage_complete = entry.usage_complete
    if existing.usage_complete == nil then existing.usage_complete = true end
    existing.partial_adopting = nil
  end
  return existing
end

local function drain_pending_reindexes(index)
  if not index or index.status == "indexing" then return false end
  local drained = false
  local pending_dirs = index.pending_reindex_dirs
  if pending_dirs and next(pending_dirs) ~= nil then
    index.pending_reindex_dirs = {}
    drained = true
    for dir, pending in pairs(pending_dirs) do
      if symbol_index.mark_directory_dirty then
        if type(pending) == "table" then
          symbol_index.mark_directory_dirty(dir, pending.reason or "queued-during-indexing", { force = pending.force })
        else
          symbol_index.mark_directory_dirty(dir, pending or "queued-during-indexing")
        end
      end
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
        for dir in pairs(changed_dirs) do
          if symbol_index.mark_directory_dirty then
            symbol_index.mark_directory_dirty(dir, "project-watch")
          end
        end
        safe_yield(0.25)
      end
    end
    index.watch_running = false
    log_quiet("Tree-sitter Project index: stopped filesystem watcher for %s", tostring(root))
  end)
  return true
end

local function project_index_languages_payload()
  local out = {}
  for _, language in ipairs(registry.get_languages() or {}) do
    if language.query_sources and language.query_sources.outline then
      out[#out + 1] = {
        id = language.id,
        grammar = language.grammar,
        files = language.files,
        headers = language.headers,
        query_sources = language.query_sources,
        parse_timeout_ms = language.parse_timeout_ms,
        outline_match_limit = language.outline_match_limit,
        outline_max_captures = language.outline_max_captures,
        outline_query_timeout_ms = language.outline_query_timeout_ms,
        usages_match_limit = language.usages_match_limit,
        usages_max_captures = language.usages_max_captures,
        usages_query_timeout_ms = language.usages_query_timeout_ms,
        locals_match_limit = language.locals_match_limit,
        locals_max_captures = language.locals_max_captures,
        locals_query_timeout_ms = language.locals_query_timeout_ms,
      }
    end
  end
  return out
end

local function project_index_exclusions_payload()
  local excluded = {}
  for _, entry in ipairs(project_paths_module().entries()) do
    if entry.path and entry.symbols == false then
      excluded[#excluded + 1] = { path = entry.path }
    end
  end
  return excluded
end

local function apply_entry_metadata(index, entry)
  for _, symbol in ipairs(entry.symbols or {}) do
    refresh_project_path_metadata(index, symbol, "symbols")
  end
  for _, list in pairs(entry.usages_by_name or {}) do
    for _, usage in ipairs(list) do
      refresh_project_path_metadata(index, usage, "usages")
    end
  end
end

local function current_worker_message(index, message)
  return index
     and message
     and message.generation == index.generation
     and message.project_paths_generation == index.project_paths_generation
end

local function cleanup_worker_artifact(message)
  local artifact = message and message.payload and message.payload.artifact
  local path = artifact and artifact.path
  if path then pcall(os.remove, path) end
end

local function load_worker_chunk_payload(index, message)
  local payload = message.payload or {}
  local artifact = payload.artifact
  if not (artifact and artifact.path) then return payload end
  local load_started = now()
  local loader, err = loadfile(artifact.path)
  if not loader then
    cleanup_worker_artifact(message)
    log_quiet("Tree-sitter Project index: failed to load chunk artifact %s: %s", tostring(artifact.path), tostring(err))
    return { files = {}, diagnostics = payload.diagnostics or {} }
  end
  local ok, artifact_payload = pcall(loader)
  cleanup_worker_artifact(message)
  local load_ms = elapsed_ms(load_started)
  add_ui_metric(index, "artifact_load_ms", load_ms)
  max_ui_metric(index, "artifact_load_max_ms", load_ms)
  inc_ui_metric(index, "artifacts_loaded", 1)
  add_worker_pool_frame_metric("treesitter_project_artifact_load_ms", load_ms)
  max_worker_pool_frame_metric("treesitter_project_artifact_load_max_ms", load_ms)
  inc_worker_pool_frame_metric("treesitter_project_artifacts_loaded", 1)
  if not ok or type(artifact_payload) ~= "table" then
    log_quiet("Tree-sitter Project index: invalid chunk artifact %s: %s", tostring(artifact.path), tostring(artifact_payload))
    return { files = {}, diagnostics = payload.diagnostics or {} }
  end
  artifact_payload.diagnostics = artifact_payload.diagnostics or payload.diagnostics or {}
  return artifact_payload
end

local function apply_worker_chunk(index, message)
  if not current_worker_message(index, message) then cleanup_worker_artifact(message); return end
  local adoption_started = now()
  local payload = load_worker_chunk_payload(index, message)
  local chunk_diag = payload.diagnostics or {}
  inc_ui_metric(index, "chunks_adopted", 1)
  inc_ui_metric(index, "chunk_files_adopted", chunk_diag.files or #(payload.files or {}))
  inc_ui_metric(index, "chunk_records_adopted", chunk_diag.records or 0)
  max_ui_metric(index, "chunk_files_adopted_max", chunk_diag.files or #(payload.files or {}))
  max_ui_metric(index, "chunk_records_adopted_max", chunk_diag.records or 0)
  inc_worker_pool_frame_metric("treesitter_project_chunk_adoption_chunks", 1)
  add_worker_pool_frame_metric("treesitter_project_chunk_adoption_files", chunk_diag.files or #(payload.files or {}))
  add_worker_pool_frame_metric("treesitter_project_chunk_adoption_records", chunk_diag.records or 0)
  max_worker_pool_frame_metric("treesitter_project_chunk_adoption_max_files", chunk_diag.files or #(payload.files or {}))
  max_worker_pool_frame_metric("treesitter_project_chunk_adoption_max_records", chunk_diag.records or 0)
  local changed = false
  local metadata_ms = 0
  local replace_ms = 0
  for _, file in ipairs(payload.files or {}) do
    local path = file.path and common.normalize_path(file.path)
    if path then
      file.path = path
      local metadata_started = now()
      apply_entry_metadata(index, file)
      metadata_ms = metadata_ms + elapsed_ms(metadata_started)
      local replace_started = now()
      if file.partial then
        merge_partial_file_entry(index, path, file.fingerprint, file)
      else
        replace_file_entry(index, path, file.fingerprint, file)
      end
      replace_ms = replace_ms + elapsed_ms(replace_started)
      index.worker_seen_paths = index.worker_seen_paths or {}
      index.worker_seen_paths[path] = true
      if index.worker_adopted_paths then index.worker_adopted_paths[path] = true end
      changed = true
    end
  end
  add_ui_metric(index, "chunk_metadata_ms", metadata_ms)
  max_ui_metric(index, "chunk_metadata_max_ms", metadata_ms)
  add_ui_metric(index, "chunk_replace_ms", replace_ms)
  max_ui_metric(index, "chunk_replace_max_ms", replace_ms)
  add_worker_pool_frame_metric("treesitter_project_chunk_metadata_ms", metadata_ms)
  add_worker_pool_frame_metric("treesitter_project_chunk_replace_ms", replace_ms)
  max_worker_pool_frame_metric("treesitter_project_chunk_metadata_max_ms", metadata_ms)
  max_worker_pool_frame_metric("treesitter_project_chunk_replace_max_ms", replace_ms)
  if changed then
    local aggregate_started = now()
    mark_aggregate_dirty(index)
    local rebuilt = false
    if index.status ~= "indexing" then
      rebuilt = maybe_rebuild_dirty_aggregates(index, false)
    else
      inc_ui_metric(index, "chunk_aggregate_rebuilds_deferred", 1)
      inc_worker_pool_frame_metric("treesitter_project_chunk_aggregate_deferred", 1)
    end
    local aggregate_check_ms = elapsed_ms(aggregate_started)
    add_ui_metric(index, "chunk_aggregate_check_ms", aggregate_check_ms)
    max_ui_metric(index, "chunk_aggregate_check_max_ms", aggregate_check_ms)
    add_worker_pool_frame_metric("treesitter_project_chunk_aggregate_check_ms", aggregate_check_ms)
    max_worker_pool_frame_metric("treesitter_project_chunk_aggregate_check_max_ms", aggregate_check_ms)
    if rebuilt then inc_worker_pool_frame_metric("treesitter_project_chunk_aggregate_rebuilt", 1) end
    core.redraw = true
    inc_worker_pool_frame_metric("treesitter_project_chunk_redraws", 1)
  end
  local duration = elapsed_ms(adoption_started)
  add_ui_metric(index, "chunk_adoption_ms", duration)
  max_ui_metric(index, "chunk_adoption_max_ms", duration)
  add_worker_pool_frame_metric("treesitter_project_chunk_adoption_ms", duration)
  max_worker_pool_frame_metric("treesitter_project_chunk_adoption_max_ms", duration)
end

local function prune_worker_unseen(index)
  local seen = index.worker_seen_paths or {}
  local pruned = false
  for path in pairs(index.by_path or {}) do
    if not seen[path] then
      index.by_path[path] = nil
      pruned = true
    end
  end
  if pruned then mark_aggregate_dirty(index) end
  return pruned
end

local function finish_worker_scan(index, message, status)
  if not current_worker_message(index, message) then return end
  if status == "ready" then
    local prune_started = now()
    prune_worker_unseen(index)
    local prune_ms = elapsed_ms(prune_started)
    add_ui_metric(index, "final_prune_ms", prune_ms)
    max_ui_metric(index, "final_prune_max_ms", prune_ms)
    add_worker_pool_frame_metric("treesitter_project_final_prune_ms", prune_ms)
    max_worker_pool_frame_metric("treesitter_project_final_prune_max_ms", prune_ms)
    if index.aggregate_dirty then
      inc_ui_metric(index, "final_aggregate_rebuilds_deferred", 1)
      inc_worker_pool_frame_metric("treesitter_project_final_aggregate_deferred", 1)
    end
    index.status = "ready"
    index.symbol_status = "ready"
    index.usage_status = "ready"
    index.reason = nil
  else
    maybe_rebuild_dirty_aggregates(index, true)
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
  core.redraw = true
  if status == "ready" then
    local diagnostics = index.diagnostics or {}
    local worker = diagnostics.worker or {}
    local ui = diagnostics.ui or {}
    log_quiet("Tree-sitter Project index: worker indexed %d symbol(s), %d usage(s)%s under %s in %.1fms",
      #index.symbols, index.usage_count or 0, index.usage_truncated and " (truncated)" or "",
      index.root, ((index.finished_at or system.get_time()) - (index.started_at or system.get_time())) * 1000)
    log_quiet("Tree-sitter indexing baseline: root=%s phase=%s worker=%s job=%s files scanned=%d indexed=%d skipped=%d parse_calls=%d chunks=%d worker_ms=%.1f read_ms=%.1f parse_ms=%.1f outline_query_ms=%.1f usage_query_ms=%.1f symbol_record_ms=%.1f usage_record_ms=%.1f send_wait_ms=%.1f ui_adopt_ms=%.1f aggregate_rebuild_ms=%.1f aggregate_rebuilds=%d max_chunk_adopt_ms=%.1f metadata_cache_hits=%d metadata_cache_misses=%d aggregate_deferred=%d",
      tostring(index.root), tostring(worker.phase or message.phase), tostring(worker.worker_id), tostring(worker.job_id),
      tonumber(worker.files_scanned or index.files_scanned or 0) or 0,
      tonumber(worker.files_indexed or index.files_indexed or 0) or 0,
      tonumber(worker.files_skipped or 0) or 0,
      tonumber(worker.parse_calls or 0) or 0,
      tonumber(worker.chunks_sent or ui.chunks_adopted or 0) or 0,
      tonumber(worker.total_ms or 0) or 0,
      tonumber(worker.file_read_ms or 0) or 0,
      tonumber(worker.parse_ms or 0) or 0,
      tonumber(worker.outline_query_ms or 0) or 0,
      tonumber(worker.usage_query_ms or 0) or 0,
      tonumber(worker.symbol_record_ms or 0) or 0,
      tonumber(worker.usage_record_ms or 0) or 0,
      tonumber(worker.chunk_send_wait_ms or 0) or 0,
      tonumber(ui.chunk_adoption_ms or 0) or 0,
      tonumber(ui.aggregate_rebuild_ms or 0) or 0,
      tonumber(ui.aggregate_rebuilds or 0) or 0,
      tonumber(ui.chunk_adoption_max_ms or 0) or 0,
      tonumber(ui.project_path_metadata_cache_hits or 0) or 0,
      tonumber(ui.project_path_metadata_cache_misses or 0) or 0,
      tonumber(ui.chunk_aggregate_rebuilds_deferred or 0) or 0)
    local phases = diagnostics.phases or {}
    local symbols_worker = phases.symbols and phases.symbols.worker or {}
    local usages_worker = phases.usages and phases.usages.worker or {}
    if phases.symbols or phases.usages then
      local total_parse_calls = (tonumber(symbols_worker.parse_calls or 0) or 0) + (tonumber(usages_worker.parse_calls or 0) or 0)
      local total_query_ms = (tonumber(symbols_worker.outline_query_ms or 0) or 0) + (tonumber(symbols_worker.usage_query_ms or 0) or 0)
        + (tonumber(usages_worker.outline_query_ms or 0) or 0) + (tonumber(usages_worker.usage_query_ms or 0) or 0)
      log_quiet("Tree-sitter indexing baseline phases: root=%s symbols_worker_ms=%.1f usages_worker_ms=%.1f symbols_parse_calls=%d usages_parse_calls=%d total_parse_calls=%d total_read_ms=%.1f total_parse_ms=%.1f total_query_ms=%.1f total_send_wait_ms=%.1f ui_adopt_ms=%.1f aggregate_rebuild_ms=%.1f aggregate_rebuilds=%d metadata_cache_hits=%d metadata_cache_misses=%d aggregate_deferred=%d",
        tostring(index.root),
        tonumber(symbols_worker.total_ms or 0) or 0,
        tonumber(usages_worker.total_ms or 0) or 0,
        tonumber(symbols_worker.parse_calls or 0) or 0,
        tonumber(usages_worker.parse_calls or 0) or 0,
        total_parse_calls,
        (tonumber(symbols_worker.file_read_ms or 0) or 0) + (tonumber(usages_worker.file_read_ms or 0) or 0),
        (tonumber(symbols_worker.parse_ms or 0) or 0) + (tonumber(usages_worker.parse_ms or 0) or 0),
        total_query_ms,
        (tonumber(symbols_worker.chunk_send_wait_ms or 0) or 0) + (tonumber(usages_worker.chunk_send_wait_ms or 0) or 0),
        tonumber(ui.chunk_adoption_ms or 0) or 0,
        tonumber(ui.aggregate_rebuild_ms or 0) or 0,
        tonumber(ui.aggregate_rebuilds or 0) or 0,
        tonumber(ui.project_path_metadata_cache_hits or 0) or 0,
        tonumber(ui.project_path_metadata_cache_misses or 0) or 0,
        tonumber(ui.chunk_aggregate_rebuilds_deferred or 0) or 0)
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

local function cancel_index_work(index)
  if not index then return false end
  local cancelled = false
  if index.worker_handle then
    cancelled = worker_pool.system():cancel(index.worker_handle) or cancelled
    index.worker_handle = nil
  end
  if index.worker_run and index.worker_run.scheduler then
    cancelled = (index.worker_run.scheduler:cancel_all() > 0) or cancelled
  end
  index.worker_run = nil
  return cancelled
end

local function add_worker_diagnostics(index, phase, diagnostics, role)
  if not diagnostics then return end
  index.diagnostics = index.diagnostics or { ui = {}, phases = {} }
  index.diagnostics.phases = index.diagnostics.phases or {}
  local phase_entry = index.diagnostics.phases[phase] or { worker = {}, ui = {} }
  local worker = phase_entry.worker or {}
  worker.worker_jobs = (worker.worker_jobs or 0) + 1
  if role == "coordinator" then
    worker.coordinator_jobs = (worker.coordinator_jobs or 0) + 1
  elseif role == "sharded" then
    worker.shard_jobs = (worker.shard_jobs or 0) + 1
  end

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
  worker.worker_id = role or worker.worker_id or "sharded"
  worker.job_id = role or worker.job_id or "sharded"
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

local function complete_symbol_phase(index, generation, opts, message)
  if not current_worker_message(index, message) then return end
  local prune_started = now()
  prune_worker_unseen(index)
  local prune_ms = elapsed_ms(prune_started)
  add_ui_metric(index, "symbols_final_prune_ms", prune_ms)
  max_ui_metric(index, "symbols_final_prune_max_ms", prune_ms)
  add_worker_pool_frame_metric("treesitter_project_symbols_final_prune_ms", prune_ms)
  if index.aggregate_dirty then
    inc_ui_metric(index, "symbols_final_aggregate_rebuilds_deferred", 1)
    inc_worker_pool_frame_metric("treesitter_project_symbols_final_aggregate_deferred", 1)
  end
  index.symbol_status = "ready"
  index.usage_status = "indexing"
  index.worker_handle = nil
  index.worker_run = nil
  index.worker_seen_paths = nil
  core.redraw = true
  core.add_thread(function()
    safe_yield(0)
    if index.generation == generation and index.status == "indexing" and index.usage_status == "indexing" then
      submit_worker_scan(index, generation, common.merge(opts, { reason = "usages" }), "usages")
    end
  end)
end

local function finish_sharded_phase(index, run, status, message)
  if not current_run_message(index, run, message) then return end
  run.terminal = true
  index.worker_run = nil
  if status == "ready" and run.phase == "symbols" then
    complete_symbol_phase(index, run.generation, run.opts or {}, message)
  else
    finish_worker_scan(index, message, status)
  end
end

local function maybe_finish_sharded_phase(index, run, message)
  if not current_run_message(index, run, message) or run.terminal then return end
  if not run.coordinator_done then return end
  if run.pending_batches and #run.pending_batches > 0 then return end
  if run.completed_shards + run.failed_shards + run.cancelled_shards < run.total_shards then return end
  if run.failed_shards > 0 then
    finish_sharded_phase(index, run, "failed", message)
  elseif run.cancelled_shards > 0 or run.cancelled then
    finish_sharded_phase(index, run, "cancelled", message)
  else
    finish_sharded_phase(index, run, "ready", message)
  end
end

local function default_index_artifact_dir()
  local base = USERDIR or (system and system.absolute_path and system.absolute_path(".") or ".")
  return common.normalize_path(base .. PATHSEP .. "treesitter-index-artifacts")
end

local query_artifact_sequence = 0
local query_artifact_stale_cleanup_done = false

local function default_query_artifact_base_dir()
  local base = USERDIR or (system and system.absolute_path and system.absolute_path(".") or ".")
  return common.normalize_path(base .. PATHSEP .. "treesitter-query-artifacts")
end

local function default_query_artifact_dir()
  local pid = tostring(system and system.get_process_id and system.get_process_id() or 0)
  return common.normalize_path(default_query_artifact_base_dir() .. PATHSEP .. "session-" .. pid)
end

local function cleanup_stale_default_query_artifacts(current_dir)
  if query_artifact_stale_cleanup_done then return end
  query_artifact_stale_cleanup_done = true
  local base = default_query_artifact_base_dir()
  local names = system.list_dir(base) or {}
  for _, name in ipairs(names) do
    local path = common.normalize_path(base .. PATHSEP .. name)
    if not current_dir or not common.path_equals(path, current_dir) then
      local info = system.get_file_info(path)
      if info and info.type == "dir" then
        common.rm(path, true)
      elseif info and info.type == "file" and tostring(name):match("^treesitter%-.+%-query%-.+%.lua$") then
        pcall(os.remove, path)
      end
    end
  end
end

local function write_query_artifact(kind, payload, opts)
  opts = opts or {}
  local dir = opts.query_artifact_dir or default_query_artifact_dir()
  if not opts.query_artifact_dir then cleanup_stale_default_query_artifacts(dir) end
  local ok, err = common.mkdirp(dir)
  if not ok and err ~= "path exists" then return nil, err or "mkdir-failed" end
  query_artifact_sequence = query_artifact_sequence + 1
  local path = common.normalize_path(dir .. PATHSEP .. string.format(
    "treesitter-%s-query-%s-%06d.lua",
    tostring(kind or "query"),
    tostring(system and system.get_process_id and system.get_process_id() or 0),
    query_artifact_sequence
  ))
  local fp, open_err = io.open(path, "wb")
  if not fp then return nil, open_err or "open-failed" end
  local content = "return " .. common.serialize(payload)
  local wrote, write_err = fp:write(content)
  local closed, close_err = fp:close()
  if not wrote or not closed then
    os.remove(path)
    return nil, write_err or close_err or "write-failed"
  end
  return { path = path, bytes = #content }
end

local function cleanup_query_artifact(artifact)
  if artifact and artifact.path then pcall(os.remove, artifact.path) end
end

cleanup_index_query_artifacts = function(index)
  if not index then return end
  for _, artifact in pairs(index.query_artifacts or {}) do
    if type(artifact) == "table" and artifact.path then pcall(os.remove, artifact.path) end
  end
  index.query_artifacts = {}
end

invalidate_index_query_artifacts = function(index)
  cleanup_index_query_artifacts(index)
end

local function persistent_query_artifact_path_exists(artifact)
  return artifact and artifact.path and system.get_file_info(artifact.path) ~= nil
end

local function make_index_payload(index, opts, phase)
  opts = opts or {}
  return {
    roots = { { path = index.root } },
    excluded = project_index_exclusions_payload(),
    ignore_files = config.ignore_files,
    languages = project_index_languages_payload(),
    include_usages = phase ~= "symbols",
    project_usage_cap = index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP,
    max_file_bytes = MAX_FILE_BYTES,
    chunk_files = opts.chunk_files or 8,
    chunk_records = opts.chunk_records or DEFAULT_WORKER_CHUNK_RECORDS,
    max_usage_captures_per_file = opts.max_usage_captures_per_file or DEFAULT_MAX_CAPTURES,
    artifact_chunks = opts.artifact_chunks ~= false,
    artifact_dir = opts.artifact_dir or default_index_artifact_dir(),
  }
end

local function submit_sharded_scan(index, generation, opts, phase)
  opts = opts or {}
  phase = phase or "symbols"
  cancel_index_work(index)
  index.status = "indexing"
  if phase == "symbols" then
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
  local previous_phases = phase == "symbols" and {} or ((index.diagnostics and index.diagnostics.phases) or {})
  index.diagnostics = {
    ui = {},
    phases = previous_phases,
    phase = phase,
    generation = generation,
    project_paths_generation = index.project_paths_generation,
    root = index.root,
  }
  if index.watcher then refresh_watches_for_dir(index, index.root) end

  local scheduler = IndexScheduler.new({
    pool = worker_pool.system(),
    max_running = opts.max_running_index_shards,
  })
  local run = {
    generation = generation,
    project_paths_generation = index.project_paths_generation,
    phase = phase,
    opts = opts,
    scheduler = scheduler,
    total_shards = 0,
    completed_shards = 0,
    failed_shards = 0,
    cancelled_shards = 0,
    coordinator_done = false,
    pending_batches = {},
    shard_budgets = {},
    usage_budget_remaining = index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP,
    usage_truncated = false,
  }
  index.worker_run = run
  index.worker_handle = nil

  local base_payload = make_index_payload(index, opts, phase)
  local pump_shards
  local function defer_pump(message)
    core.add_thread(function()
      safe_yield(0)
      if current_run_message(index, run, message) and not run.terminal then
        pump_shards()
        maybe_finish_sharded_phase(index, run, message)
      end
    end)
  end

  local function submit_shard(batch)
    if run.terminal or run.cancelled then return end
    run.total_shards = run.total_shards + 1
    local shard_id = run.total_shards
    local include_usages = phase ~= "symbols"
    local shard_budget = 0
    if include_usages then
      local default_shard_budget = math.max(DEFAULT_SHARD_USAGE_BUDGET, (tonumber(opts.batch_files or DEFAULT_INDEX_BATCH_FILES) or DEFAULT_INDEX_BATCH_FILES) * 256)
      local per_shard_cap = tonumber(opts.shard_usage_budget or default_shard_budget) or default_shard_budget
      shard_budget = math.max(0, math.min(run.usage_budget_remaining or 0, per_shard_cap))
      run.usage_budget_remaining = math.max(0, (run.usage_budget_remaining or 0) - shard_budget)
      run.shard_budgets[shard_id] = shard_budget
    end
    local payload = common.merge(base_payload, {
      root = batch.root or index.root,
      files = batch.files or {},
      include_usages = include_usages,
      project_usage_cap = include_usages and shard_budget or 0,
      shard_id = shard_id,
    })
    local handle
    handle = scheduler:submit({
      kind = "treesitter_project_index",
      priority = "background",
      generation = generation,
      project_paths_generation = index.project_paths_generation,
      phase = phase,
      payload = payload,
      is_stale = function(message)
        return not current_run_message(index, run, message)
      end,
      on_stale = cleanup_worker_artifact,
      on_progress = function(message)
        if not current_run_message(index, run, message) then return end
        local p = message.payload or {}
        index.files_scanned = math.max(index.files_scanned or 0, (run.coordinator_files_scanned or 0))
        index.files_indexed = (run.accepted_files_indexed or 0) + (p.files_indexed or 0)
        core.redraw = true
      end,
      on_result = function(message)
        if not current_run_message(index, run, message) then return end
        if message.type == "chunk" then
          apply_worker_chunk(index, message)
        elseif message.type == "final" then
          local p = message.payload or {}
          run.accepted_files_indexed = (run.accepted_files_indexed or 0) + (p.files_indexed or 0)
          run.accepted_files_scanned = (run.accepted_files_scanned or 0) + (p.files_scanned or 0)
          index.files_indexed = run.accepted_files_indexed
          index.files_total = run.accepted_files_indexed
          if phase ~= "symbols" then
            local reserved = run.shard_budgets[shard_id] or 0
            local used = math.max(0, tonumber(p.usage_budget_used or p.usage_count or 0) or 0)
            if used < reserved then
              run.usage_budget_remaining = (run.usage_budget_remaining or 0) + (reserved - used)
              run.shard_budgets[shard_id] = used
            end
            run.usage_truncated = run.usage_truncated or (p.usage_truncated and true or false)
            index.usage_truncated = run.usage_truncated
            index.usage_truncated_reason = run.usage_truncated and "project-usage-cap" or nil
          end
          add_worker_diagnostics(index, phase, p.diagnostics, "sharded")
        end
      end,
      on_error = function(message)
        if not current_run_message(index, run, message) then return end
        run.failed_shards = run.failed_shards + 1
        scheduler:cancel_all()
        finish_sharded_phase(index, run, "failed", message)
      end,
      on_cancelled = function(message)
        if not current_run_message(index, run, message) then return end
        run.cancelled_shards = run.cancelled_shards + 1
        if phase ~= "symbols" and message.payload and message.payload.before_start then
          local reserved = run.shard_budgets[shard_id] or 0
          run.usage_budget_remaining = (run.usage_budget_remaining or 0) + reserved
          run.shard_budgets[shard_id] = 0
        end
        defer_pump(message)
        maybe_finish_sharded_phase(index, run, message)
      end,
      on_complete = function(message)
        if not current_run_message(index, run, message) then return end
        run.completed_shards = run.completed_shards + 1
        defer_pump(message)
        maybe_finish_sharded_phase(index, run, message)
      end,
    })
    return handle
  end

  pump_shards = function()
    while not run.terminal
      and #run.pending_batches > 0
      and scheduler:outstanding_count() < scheduler.max_running
    do
      submit_shard(table.remove(run.pending_batches, 1))
    end
  end

  scheduler:submit({
    kind = "treesitter_project_index",
    priority = "background",
    generation = generation,
    project_paths_generation = index.project_paths_generation,
    phase = phase,
    payload = common.merge(base_payload, {
      mode = "walk",
      batch_files = opts.batch_files or DEFAULT_INDEX_BATCH_FILES,
      batch_bytes = opts.batch_bytes or DEFAULT_INDEX_BATCH_BYTES,
      include_usages = false,
    }),
    is_stale = function(message)
      return not current_run_message(index, run, message)
    end,
    on_stale = cleanup_worker_artifact,
    on_progress = function(message)
      if not current_run_message(index, run, message) then return end
      local p = message.payload or {}
      run.coordinator_files_scanned = p.files_scanned or run.coordinator_files_scanned or 0
      index.files_scanned = p.files_scanned or index.files_scanned
      core.redraw = true
    end,
    on_result = function(message)
      if not current_run_message(index, run, message) then return end
      if message.type == "chunk" then
        local p = message.payload or {}
        for _, batch in ipairs(p.batches or {}) do run.pending_batches[#run.pending_batches + 1] = batch end
        pump_shards()
      elseif message.type == "final" then
        local p = message.payload or {}
        run.coordinator_files_scanned = p.files_scanned or run.coordinator_files_scanned or 0
        index.files_scanned = p.files_scanned or index.files_scanned
        add_worker_diagnostics(index, phase, p.diagnostics, "coordinator")
      end
    end,
    on_error = function(message)
      if not current_run_message(index, run, message) then return end
      run.failed_shards = run.failed_shards + 1
      scheduler:cancel_all()
      finish_sharded_phase(index, run, "failed", message)
    end,
    on_cancelled = function(message)
      if not current_run_message(index, run, message) then return end
      run.coordinator_done = true
      run.cancelled_shards = run.cancelled_shards + 1
      defer_pump(message)
      maybe_finish_sharded_phase(index, run, message)
    end,
    on_complete = function(message)
      if not current_run_message(index, run, message) then return end
      run.coordinator_done = true
      defer_pump(message)
      maybe_finish_sharded_phase(index, run, message)
    end,
  })

  log_quiet("Tree-sitter Project index: submitted sharded worker phase=%s generation=%d project_paths_generation=%d root=%s max_running=%d",
    tostring(phase), generation, index.project_paths_generation, tostring(index.root), scheduler.max_running or 0)
end

submit_worker_scan = function(index, generation, opts, phase)
  opts = opts or {}
  phase = phase or "symbols"
  if opts.sharded ~= false then
    submit_sharded_scan(index, generation, opts, phase)
    return
  end
  cancel_index_work(index)
  index.status = "indexing"
  if phase == "symbols" then
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
  local previous_phases = phase == "symbols" and {} or ((index.diagnostics and index.diagnostics.phases) or {})
  index.diagnostics = {
    ui = {},
    phases = previous_phases,
    phase = phase,
    generation = generation,
    project_paths_generation = index.project_paths_generation,
    root = index.root,
  }
  if index.watcher then refresh_watches_for_dir(index, index.root) end

  local handle, err = worker_pool.system():submit({
    kind = "treesitter_project_index",
    priority = "background",
    generation = generation,
    project_paths_generation = index.project_paths_generation,
    phase = phase,
    payload = {
      roots = { { path = index.root } },
      excluded = project_index_exclusions_payload(),
      ignore_files = config.ignore_files,
      languages = project_index_languages_payload(),
      include_usages = phase ~= "symbols",
      project_usage_cap = index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP,
      max_file_bytes = MAX_FILE_BYTES,
      chunk_files = opts.chunk_files or 8,
      chunk_records = opts.chunk_records or DEFAULT_WORKER_CHUNK_RECORDS,
      max_usage_captures_per_file = opts.max_usage_captures_per_file or DEFAULT_MAX_CAPTURES,
    },
    is_stale = function(message)
      return not current_worker_message(index, message)
    end,
    on_stale = cleanup_worker_artifact,
    on_progress = function(message)
      if not current_worker_message(index, message) then return end
      local p = message.payload or {}
      index.files_scanned = p.files_scanned or index.files_scanned
      index.files_indexed = p.files_indexed or index.files_indexed
      core.redraw = true
    end,
    on_result = function(message)
      if message.type == "chunk" then
        apply_worker_chunk(index, message)
      elseif message.type == "final" and current_worker_message(index, message) then
        local p = message.payload or {}
        index.files_scanned = p.files_scanned or index.files_scanned
        index.files_indexed = p.files_indexed or index.files_indexed
        index.files_total = p.files_indexed or index.files_total
        if message.phase ~= "symbols" and p.usage_truncated ~= nil then
          index.usage_truncated = p.usage_truncated and true or false
          index.usage_truncated_reason = p.usage_truncated and "project-usage-cap" or nil
        end
        if p.diagnostics then
          index.diagnostics = index.diagnostics or { ui = {}, phases = {} }
          index.diagnostics.phases = index.diagnostics.phases or {}
          index.diagnostics.worker = p.diagnostics
          index.diagnostics.phases[message.phase or phase] = {
            worker = p.diagnostics,
            ui = common.merge({}, index.diagnostics.ui or {}),
          }
        end
      end
    end,
    on_error = function(message)
      finish_worker_scan(index, message, "failed")
    end,
    on_cancelled = function(message)
      finish_worker_scan(index, message, "cancelled")
    end,
    on_complete = function(message)
      if not current_worker_message(index, message) then return end
      if message.phase == "symbols" then
        local prune_started = now()
        prune_worker_unseen(index)
        local prune_ms = elapsed_ms(prune_started)
        add_ui_metric(index, "symbols_final_prune_ms", prune_ms)
        max_ui_metric(index, "symbols_final_prune_max_ms", prune_ms)
        add_worker_pool_frame_metric("treesitter_project_symbols_final_prune_ms", prune_ms)
        if index.aggregate_dirty then
          inc_ui_metric(index, "symbols_final_aggregate_rebuilds_deferred", 1)
          inc_worker_pool_frame_metric("treesitter_project_symbols_final_aggregate_deferred", 1)
        end
        index.symbol_status = "ready"
        index.usage_status = "indexing"
        index.worker_handle = nil
        index.worker_seen_paths = nil
        core.redraw = true
        core.add_thread(function()
          safe_yield(0)
          if index.generation == generation and index.status == "indexing" and index.usage_status == "indexing" then
            submit_worker_scan(index, generation, common.merge(opts, { reason = "usages" }), "usages")
          end
        end)
      else
        finish_worker_scan(index, message, "ready")
      end
    end,
  })
  if not handle then
    index.status = "failed"
    index.symbol_status = "failed"
    index.usage_status = "failed"
    index.reason = err or "worker-submit-failed"
    index.finished_at = system.get_time()
    log_quiet("Tree-sitter Project index: failed to submit worker for %s: %s", tostring(index.root), tostring(err))
  else
    index.worker_handle = handle
    log_quiet("Tree-sitter Project index: submitted worker phase=%s generation=%d project_paths_generation=%d root=%s",
      tostring(phase), generation, index.project_paths_generation, tostring(index.root))
  end
end

function symbol_index.ensure_scan(root, opts)
  opts = opts or {}
  local index = index_for_root(root)
  start_project_watcher(index)
  if index.status == "indexing" and not opts.force then return index end
  if index.status == "ready" and not opts.force then
    if symbol_index.update_open_document then
      for _, doc in pairs(core.docs or {}) do
        local path = doc and (doc.abs_filename or doc.filename)
        path = path and common.normalize_path(path)
        if path and common.path_belongs_to(path, index.root) then
          symbol_index.update_open_document(doc, "ensure-ready")
        end
      end
    end
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
    refresh_after_seconds = opts.refresh_after_seconds,
    sharded = opts.sharded,
    batch_files = opts.batch_files,
    batch_bytes = opts.batch_bytes,
    max_running_index_shards = opts.max_running_index_shards,
    shard_usage_budget = opts.shard_usage_budget,
    chunk_files = opts.chunk_files,
    chunk_records = opts.chunk_records,
    max_usage_captures_per_file = opts.max_usage_captures_per_file,
    artifact_chunks = opts.artifact_chunks,
    artifact_dir = opts.artifact_dir,
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
    invalidate_index_query_artifacts(index)
  else
    for _, index in pairs(indexes) do
      cancel_index_work(index)
      index.status = "idle"
      index.symbol_status = "idle"
      index.usage_status = "idle"
      index.generation = index.generation + 1
      invalidate_index_query_artifacts(index)
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

local function overlay_paths(index)
  local paths = {}
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

local function combined_symbols(index, kind)
  kind = kind or "symbols"
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
  and cache.symbols_table == index.symbols then
    inc_ui_metric(index, "combined_symbols_cache_hits", 1)
    return cache.symbols
  end

  inc_ui_metric(index, "combined_symbols_cache_misses", 1)
  local overlay = index.open_docs or {}
  local out = {}
  for _, symbol in ipairs(index.symbols or {}) do
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
    symbols_table = index.symbols,
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

local function combined_symbols_from_entries(index, kind)
  kind = kind or "symbols"
  if refresh_open_document_overlays then refresh_open_document_overlays(index) end
  local overlay = index.open_docs or {}
  local paths = overlay_paths(index)
  local out = {}
  for _, entry in pairs(index.by_path or {}) do
    for _, symbol in ipairs(entry.symbols or {}) do
      if not paths[symbol.path] and project_path_allows(symbol.path, kind) then
        out[#out + 1] = refresh_project_path_metadata(index, copy_item(symbol), kind)
      end
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
  inc_ui_metric(index, "direct_symbol_queries", 1)
  add_ui_metric(index, "direct_symbol_query_items", #out)
  return out
end

local function combined_usages_for_name_from_entries(index, name)
  if refresh_open_document_overlays then refresh_open_document_overlays(index) end
  local overlay = index.open_docs or {}
  local paths = overlay_paths(index)
  local out = {}
  for _, entry in pairs(index.by_path or {}) do
    for _, usage in ipairs((entry.usages_by_name or {})[name] or {}) do
      if not paths[usage.path] and not project_paths_module().is_excluded(usage.path, "usages") then
        out[#out + 1] = refresh_project_path_metadata(index, usage, "usages")
      end
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
  inc_ui_metric(index, "direct_usage_queries", 1)
  add_ui_metric(index, "direct_usage_query_items", #out)
  return out
end

local function filtered_symbols(symbols, query, limit)
  local items = {}
  for _, symbol in ipairs(symbols or {}) do items[#items + 1] = symbol end
  query = tostring(query or "")
  if query ~= "" then items = common.fuzzy_match(items, query, false) end
  limit = tonumber(limit) or DEFAULT_QUERY_LIMIT
  local out = {}
  for i = 1, math.min(limit, #items) do out[i] = items[i] end
  return out, #items > #out
end

local function refresh_current_core_docs_for_index(index)
  if not index or not symbol_index.update_open_document then return end
  for _, doc in pairs(core.docs or {}) do
    local path = doc and (doc.abs_filename or doc.filename)
    path = path and common.normalize_path(path)
    if path and common.path_belongs_to(path, index.root) then
      symbol_index.update_open_document(doc, "query-refresh")
    end
  end
end

local function merge_status(current, next_status)
  if current == "pending" or next_status == "pending" then return "pending" end
  if current == "stale" or next_status == "stale" then return "stale" end
  return "fresh"
end

function symbol_index.workspace_symbols(query, opts)
  opts = opts or {}
  local roots = project_path_roots("symbols", opts)
  local all_symbols, per_root = {}, {}
  local status = "fresh"
  local reason
  local any_usable = false
  local has_more = false

  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    local root_status = "pending"
    if index.symbol_status == "ready" then
      refresh_current_core_docs_for_index(index)
      local source = index.aggregate_dirty
        and combined_symbols_from_entries(index, opts.kind or "symbols")
        or combined_symbols(index, opts.kind or "symbols")
      for _, symbol in ipairs(source) do all_symbols[#all_symbols + 1] = symbol end
      root_status = "fresh"
      any_usable = true
    elseif (#(index.symbols or {}) > 0 or next(index.open_docs or {}) ~= nil) and opts.allow_stale then
      for _, symbol in ipairs(combined_symbols(index, opts.kind or "symbols")) do all_symbols[#all_symbols + 1] = symbol end
      root_status = "stale"
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
      any_usable = true
    else
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
    end
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = { root = root, status = root_status, index = index }
  end

  if any_usable and status ~= "fresh" and not opts.allow_stale then
    return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  end
  if any_usable then
    sort_symbols(all_symbols)
    local results
    results, has_more = filtered_symbols(all_symbols, query, opts.limit)
    return results, status == "fresh" and nil or (reason or "indexing"), status == "fresh" and "fresh" or "stale", {
      has_more = has_more,
      roots = per_root,
      index = #per_root == 1 and per_root[1].index or nil,
    }
  end
  return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
end

local function filter_usages(usages, opts)
  opts = opts or {}
  local include_declaration = opts.include_declaration ~= false
  local out = {}
  local has_more = false
  local limit = tonumber(opts.limit) or DEFAULT_QUERY_LIMIT
  for _, usage in ipairs(usages or {}) do
    if include_declaration or not usage.is_declaration then
      if #out < limit then
        out[#out + 1] = usage
      else
        has_more = true
        break
      end
    end
  end
  return out, has_more
end

local function workspace_symbol_snapshot(query, opts)
  opts = opts or {}
  local roots = project_path_roots("symbols", opts)
  local query_project_paths_generation = project_paths_module().generation()
  local max_snapshot_symbols = tonumber(opts.max_snapshot_symbols or DEFAULT_ASYNC_SYMBOL_SNAPSHOT_LIMIT) or DEFAULT_ASYNC_SYMBOL_SNAPSHOT_LIMIT
  local all_symbols, per_root = {}, {}
  local status = "fresh"
  local reason
  local any_usable = false

  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    local root_status = "pending"
    if index.symbol_status == "ready" then
      refresh_current_core_docs_for_index(index)
      local source = index.aggregate_dirty
        and combined_symbols_from_entries(index, opts.kind or "symbols")
        or combined_symbols(index, opts.kind or "symbols")
      for _, symbol in ipairs(source) do
        if #all_symbols >= max_snapshot_symbols then
          return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
        end
        all_symbols[#all_symbols + 1] = symbol
      end
      root_status = "fresh"
      any_usable = true
    elseif (#(index.symbols or {}) > 0 or next(index.open_docs or {}) ~= nil) and opts.allow_stale then
      for _, symbol in ipairs(combined_symbols(index, opts.kind or "symbols")) do
        if #all_symbols >= max_snapshot_symbols then
          return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
        end
        all_symbols[#all_symbols + 1] = symbol
      end
      root_status = "stale"
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
      any_usable = true
    else
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
    end
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = {
      root = root,
      status = root_status,
      index = index,
      generation = index.generation,
      project_paths_generation = index.project_paths_generation,
      query_project_paths_generation = query_project_paths_generation,
    }
  end

  if not any_usable then
    return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  end
  if status ~= "fresh" and not opts.allow_stale then
    return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  end
  sort_symbols(all_symbols)
  return all_symbols, status == "fresh" and nil or (reason or "indexing"), status == "fresh" and "fresh" or "stale", {
    roots = per_root,
    index = #per_root == 1 and per_root[1].index or nil,
  }
end

local function persistent_symbol_query_artifact(index, kind, opts)
  opts = opts or {}
  if opts.disable_persistent_query_artifacts then return nil, "disabled" end
  if not index or index.aggregate_dirty then return nil, "aggregate-dirty" end
  kind = kind or "symbols"
  local project_paths_generation = project_paths_module().generation()
  local key = table.concat({ "symbols", kind, tostring(index.generation), tostring(project_paths_generation) }, "\0")
  index.query_artifacts = index.query_artifacts or {}
  local cached = index.query_artifacts[key]
  if cached
  and cached.generation == index.generation
  and cached.project_paths_generation == project_paths_generation
  and cached.kind == kind
  and persistent_query_artifact_path_exists(cached)
  then
    inc_ui_metric(index, "persistent_symbol_query_artifact_hits", 1)
    return cached
  end

  local symbols = {}
  for _, symbol in ipairs(index.symbols or {}) do
    if project_path_allows(symbol.path, kind) then
      local item = refresh_project_path_metadata(index, copy_item(symbol), kind)
      item.search_text = tostring(item.text or item.name or "")
      symbols[#symbols + 1] = item
    end
  end
  local artifact, err = write_query_artifact("symbols-index", { symbols = symbols }, opts)
  if not artifact then return nil, err or "artifact-write-failed" end
  artifact.generation = index.generation
  artifact.project_paths_generation = project_paths_generation
  artifact.kind = kind
  artifact.count = #symbols
  index.query_artifacts[key] = artifact
  inc_ui_metric(index, "persistent_symbol_query_artifact_builds", 1)
  add_ui_metric(index, "persistent_symbol_query_artifact_items", #symbols)
  return artifact
end

local function persistent_usage_query_artifact(index, name, opts)
  opts = opts or {}
  if opts.disable_persistent_query_artifacts then return nil, "disabled" end
  if not index or index.aggregate_dirty then return nil, "aggregate-dirty" end
  name = tostring(name or "")
  local project_paths_generation = project_paths_module().generation()
  local key = table.concat({ "usages", name, tostring(index.generation), tostring(project_paths_generation) }, "\0")
  index.query_artifacts = index.query_artifacts or {}
  local cached = index.query_artifacts[key]
  if cached
  and cached.generation == index.generation
  and cached.project_paths_generation == project_paths_generation
  and cached.name == name
  and persistent_query_artifact_path_exists(cached)
  then
    inc_ui_metric(index, "persistent_usage_query_artifact_hits", 1)
    return cached
  end

  local usages = {}
  for _, usage in ipairs((index.usages_by_name or {})[name] or {}) do
    if not project_paths_module().is_excluded(usage.path, "usages") then
      usages[#usages + 1] = refresh_project_path_metadata(index, copy_item(usage), "usages")
    end
  end
  sort_usages(usages)
  local artifact, err = write_query_artifact("usages-index", { usages = usages }, opts)
  if not artifact then return nil, err or "artifact-write-failed" end
  artifact.generation = index.generation
  artifact.project_paths_generation = project_paths_generation
  artifact.name = name
  artifact.count = #usages
  index.query_artifacts[key] = artifact
  inc_ui_metric(index, "persistent_usage_query_artifact_builds", 1)
  add_ui_metric(index, "persistent_usage_query_artifact_items", #usages)
  return artifact
end

local function append_overlay_symbols(index, kind, out, max_count)
  local count = #(out or {})
  for _, entry in pairs(index.open_docs or {}) do
    if overlay_entry_current(entry) then
      for _, symbol in ipairs(entry.symbols or {}) do
        if project_path_allows(symbol.path, kind) then
          count = count + 1
          if count > max_count then return nil, "overlay-too-large" end
          local item = refresh_project_path_metadata(index, copy_item(symbol), kind)
          item.search_text = tostring(item.text or item.name or "")
          out[#out + 1] = item
        end
      end
    end
  end
  return true
end

local function append_overlay_usages(index, name, out, max_count)
  local count = #(out or {})
  for _, entry in pairs(index.open_docs or {}) do
    if overlay_entry_current(entry) then
      for _, usage in ipairs((entry.usages_by_name or {})[name] or {}) do
        if not project_paths_module().is_excluded(usage.path, "usages") then
          count = count + 1
          if count > max_count then return nil, "overlay-too-large" end
          out[#out + 1] = refresh_project_path_metadata(index, copy_item(usage), "usages")
        end
      end
    end
  end
  return true
end

local function workspace_symbol_artifact_payload(query, opts)
  opts = opts or {}
  local roots = project_path_roots("symbols", opts)
  local query_project_paths_generation = project_paths_module().generation()
  local artifact_payload = {
    query = query,
    limit = opts.limit or DEFAULT_QUERY_LIMIT,
    index_artifacts = {},
    extra_symbols = {},
    suppressed_paths = {},
  }
  local per_root = {}
  local status = "fresh"
  local reason
  local any_usable = false
  local max_overlay = tonumber(opts.max_overlay_symbols or DEFAULT_ASYNC_OVERLAY_SNAPSHOT_LIMIT) or DEFAULT_ASYNC_OVERLAY_SNAPSHOT_LIMIT

  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    local root_status = "pending"
    if index.symbol_status == "ready" and not index.aggregate_dirty then
      refresh_current_core_docs_for_index(index)
      local suppressed = overlay_paths(index)
      for path in pairs(suppressed) do artifact_payload.suppressed_paths[#artifact_payload.suppressed_paths + 1] = path end
      local ok, overlay_err = append_overlay_symbols(index, opts.kind or "symbols", artifact_payload.extra_symbols, max_overlay)
      if not ok then return nil, overlay_err, "unavailable", { roots = per_root, index = index } end
      local artifact, artifact_err = persistent_symbol_query_artifact(index, opts.kind or "symbols", opts)
      if not artifact then return nil, artifact_err or "artifact-unavailable", "unavailable", { roots = per_root, index = index } end
      artifact_payload.index_artifacts[#artifact_payload.index_artifacts + 1] = artifact
      root_status = "fresh"
      any_usable = true
    elseif opts.allow_stale and #(index.symbols or {}) > 0 and not index.aggregate_dirty then
      local artifact, artifact_err = persistent_symbol_query_artifact(index, opts.kind or "symbols", opts)
      if artifact then
        artifact_payload.index_artifacts[#artifact_payload.index_artifacts + 1] = artifact
        root_status = "stale"
        reason = reason or "indexing"
        any_usable = true
      else
        reason = reason or artifact_err or "indexing"
      end
    else
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
    end
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = {
      root = root,
      status = root_status,
      index = index,
      generation = index.generation,
      project_paths_generation = index.project_paths_generation,
      query_project_paths_generation = query_project_paths_generation,
    }
  end

  local meta = { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  if not any_usable then return nil, reason or "indexing", "pending", meta end
  if status ~= "fresh" and not opts.allow_stale then return nil, reason or "indexing", "pending", meta end
  return artifact_payload, status == "fresh" and nil or (reason or "indexing"), status == "fresh" and "fresh" or "stale", meta
end

local function workspace_usage_artifact_payload(name, opts)
  opts = opts or {}
  name = tostring(name or "")
  if name == "" then return { usages = {}, limit = opts.limit or DEFAULT_QUERY_LIMIT }, "no-symbol", "fresh", { has_more = false } end
  local roots = project_path_roots("usages", opts)
  local query_project_paths_generation = project_paths_module().generation()
  local artifact_payload = {
    include_declaration = opts.include_declaration,
    limit = opts.limit or DEFAULT_QUERY_LIMIT,
    index_artifacts = {},
    extra_usages = {},
    suppressed_paths = {},
  }
  local per_root = {}
  local status = "fresh"
  local reason
  local any_usable = false
  local usage_truncated = false
  local usage_truncated_reason
  local max_overlay = tonumber(opts.max_overlay_usages or DEFAULT_ASYNC_OVERLAY_SNAPSHOT_LIMIT) or DEFAULT_ASYNC_OVERLAY_SNAPSHOT_LIMIT

  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    local root_status = "pending"
    if index.usage_status == "ready" and not index.aggregate_dirty then
      refresh_current_core_docs_for_index(index)
      local suppressed = overlay_paths(index)
      for path in pairs(suppressed) do artifact_payload.suppressed_paths[#artifact_payload.suppressed_paths + 1] = path end
      local ok, overlay_err = append_overlay_usages(index, name, artifact_payload.extra_usages, max_overlay)
      if not ok then return nil, overlay_err, "unavailable", { roots = per_root, index = index } end
      local artifact, artifact_err = persistent_usage_query_artifact(index, name, opts)
      if not artifact then return nil, artifact_err or "artifact-unavailable", "unavailable", { roots = per_root, index = index } end
      artifact_payload.index_artifacts[#artifact_payload.index_artifacts + 1] = artifact
      root_status = "fresh"
      any_usable = true
    elseif opts.allow_stale and ((index.usages_by_name or {})[name]) and not index.aggregate_dirty then
      local artifact, artifact_err = persistent_usage_query_artifact(index, name, opts)
      if artifact then
        artifact_payload.index_artifacts[#artifact_payload.index_artifacts + 1] = artifact
        root_status = "stale"
        reason = reason or "indexing"
        any_usable = true
      else
        reason = reason or artifact_err or "indexing"
      end
    else
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
    end
    usage_truncated = usage_truncated or index.usage_truncated or false
    usage_truncated_reason = usage_truncated_reason or index.usage_truncated_reason
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = {
      root = root,
      status = root_status,
      index = index,
      generation = index.generation,
      project_paths_generation = index.project_paths_generation,
      query_project_paths_generation = query_project_paths_generation,
    }
  end

  local meta = {
    roots = per_root,
    index = #per_root == 1 and per_root[1].index or nil,
    usage_truncated = usage_truncated,
    usage_truncated_reason = usage_truncated_reason,
  }
  if not any_usable then return nil, reason or "indexing", "pending", meta end
  if status ~= "fresh" and not opts.allow_stale then return nil, reason or "indexing", "pending", meta end
  return artifact_payload, status == "fresh" and nil or (reason or "indexing"), status == "fresh" and "fresh" or "stale", meta
end

local function async_snapshot_stale_reason(meta)
  for _, root_meta in ipairs((meta and meta.roots) or {}) do
    local index = root_meta.index
    if not index then return "missing-index" end
    if root_meta.generation ~= nil and index.generation ~= root_meta.generation then
      return string.format("generation-changed:%s:%s", tostring(root_meta.generation), tostring(index.generation))
    end
    if root_meta.query_project_paths_generation ~= nil
      and project_paths_module().generation() ~= root_meta.query_project_paths_generation
    then
      return string.format("project-paths-generation-changed:%s:%s", tostring(root_meta.query_project_paths_generation), tostring(project_paths_module().generation()))
    end
    if root_meta.project_paths_generation ~= nil
      and index.project_paths_generation ~= root_meta.project_paths_generation
      and index.status ~= "indexing"
    then
      return string.format("index-project-paths-generation-changed:%s:%s", tostring(root_meta.project_paths_generation), tostring(index.project_paths_generation))
    end
  end
  return nil
end

function symbol_index.workspace_symbols_async(query, opts)
  opts = opts or {}
  local symbols, reason, status, meta = workspace_symbol_snapshot(query, opts)
  local query_payload
  local artifact
  local artifact_err
  if status == "fresh" or status == "stale" then
    local compact_symbols = {}
    for _, symbol in ipairs(symbols or {}) do
      local item = copy_item(symbol)
      item.search_text = tostring(symbol.text or symbol.name or "")
      compact_symbols[#compact_symbols + 1] = item
    end
    query_payload = {
      query = query,
      symbols = compact_symbols,
      limit = opts.limit or DEFAULT_QUERY_LIMIT,
    }
    artifact, artifact_err = write_query_artifact("symbols", query_payload, opts)
  elseif reason == "snapshot-too-large" and not opts.disable_persistent_query_artifacts then
    query_payload, reason, status, meta = workspace_symbol_artifact_payload(query, opts)
  end
  if status ~= "fresh" and status ~= "stale" then return nil, reason, status, meta end

  local request = {
    status = "pending",
    reason = reason,
    source_status = status,
    results = nil,
    meta = meta,
  }
  local handle
  if artifact then
    request.query_artifact = artifact
  elseif artifact_err then
    log_quiet("Tree-sitter Project symbol query: using channel payload after artifact write failed: %s", tostring(artifact_err))
  end
  handle = worker_pool.system():submit({
    kind = "treesitter_symbol_query",
    priority = "background",
    payload = artifact and { artifact = artifact } or query_payload,
    on_result = function(message)
      if message.type ~= "result" then return end
      local p = message.payload or {}
      request.results = p.symbols or {}
      request.has_more = p.has_more and true or false
      request.diagnostics = p.diagnostics
    end,
    on_complete = function()
      cleanup_query_artifact(request.query_artifact)
      request.query_artifact = nil
      local stale_reason = async_snapshot_stale_reason(meta)
      if not stale_reason then
        request.status = request.source_status or "fresh"
      else
        request.status = "stale-cancelled"
        request.reason = stale_reason
        request.results = nil
      end
      request.done = true
    end,
    on_error = function(message)
      cleanup_query_artifact(request.query_artifact)
      request.query_artifact = nil
      request.status = "unavailable"
      request.reason = message and (message.error or (message.payload and message.payload.reason)) or "query-failed"
      request.done = true
    end,
    on_cancelled = function()
      cleanup_query_artifact(request.query_artifact)
      request.query_artifact = nil
      request.status = "cancelled"
      request.reason = "cancelled"
      request.done = true
    end,
  })
  if not handle then
    cleanup_query_artifact(artifact)
    return nil, "submit-failed", "unavailable", meta
  end
  request.handle = handle
  function request:cancel()
    cleanup_query_artifact(self.query_artifact)
    self.query_artifact = nil
    if self.handle then return worker_pool.system():cancel(self.handle) end
    return false
  end
  return request, nil, "pending", meta
end

function symbol_index.query_symbols_async(query, opts)
  return symbol_index.workspace_symbols_async(query, opts)
end

local function workspace_usage_snapshot(name, opts)
  opts = opts or {}
  name = tostring(name or "")
  if name == "" then return {}, "no-symbol", "fresh", { has_more = false } end
  local roots = project_path_roots("usages", opts)
  local query_project_paths_generation = project_paths_module().generation()
  local max_snapshot_usages = tonumber(opts.max_snapshot_usages or DEFAULT_ASYNC_USAGE_SNAPSHOT_LIMIT) or DEFAULT_ASYNC_USAGE_SNAPSHOT_LIMIT
  local all_usages, per_root = {}, {}
  local status = "fresh"
  local reason
  local any_usable = false
  local usage_truncated = false
  local usage_truncated_reason

  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, scan_options_from_query(opts))
    local root_status = "pending"
    if index.usage_status == "ready" then
      refresh_current_core_docs_for_index(index)
      local source = index.aggregate_dirty
        and combined_usages_for_name_from_entries(index, name)
        or combined_usages_for_name(index, name)
      for _, usage in ipairs(source) do
        if #all_usages >= max_snapshot_usages then
          return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
        end
        all_usages[#all_usages + 1] = usage
      end
      root_status = "fresh"
      any_usable = true
    elseif opts.allow_stale and ((index.usages_by_name or {})[name] or next(index.open_docs or {}) ~= nil) then
      for _, usage in ipairs(combined_usages_for_name(index, name)) do
        if #all_usages >= max_snapshot_usages then
          return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
        end
        all_usages[#all_usages + 1] = usage
      end
      root_status = "stale"
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
      any_usable = true
    else
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
    end
    usage_truncated = usage_truncated or index.usage_truncated or false
    usage_truncated_reason = usage_truncated_reason or index.usage_truncated_reason
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = {
      root = root,
      status = root_status,
      index = index,
      generation = index.generation,
      project_paths_generation = index.project_paths_generation,
      query_project_paths_generation = query_project_paths_generation,
    }
  end

  local meta = {
    roots = per_root,
    index = #per_root == 1 and per_root[1].index or nil,
    usage_truncated = usage_truncated,
    usage_truncated_reason = usage_truncated_reason,
  }
  if not any_usable then return nil, reason or "indexing", "pending", meta end
  if status ~= "fresh" and not opts.allow_stale then return nil, reason or "indexing", "pending", meta end
  return all_usages, status == "fresh" and nil or (reason or "indexing"), status == "fresh" and "fresh" or "stale", meta
end

function symbol_index.workspace_usages_async(name, opts)
  opts = opts or {}
  local usages, reason, status, meta = workspace_usage_snapshot(name, opts)
  local query_payload
  local artifact
  local artifact_err
  if status == "fresh" or status == "stale" then
    local compact_usages = {}
    for _, usage in ipairs(usages or {}) do compact_usages[#compact_usages + 1] = copy_item(usage) end
    query_payload = {
      usages = compact_usages,
      include_declaration = opts.include_declaration,
      limit = opts.limit or DEFAULT_QUERY_LIMIT,
    }
    artifact, artifact_err = write_query_artifact("usages", query_payload, opts)
  elseif reason == "snapshot-too-large" and not opts.disable_persistent_query_artifacts then
    query_payload, reason, status, meta = workspace_usage_artifact_payload(name, opts)
  end
  if status ~= "fresh" and status ~= "stale" then return nil, reason, status, meta end

  local request = {
    status = "pending",
    reason = reason,
    source_status = status,
    results = nil,
    meta = meta,
  }
  if artifact then
    request.query_artifact = artifact
  elseif artifact_err then
    log_quiet("Tree-sitter Project usage query: using channel payload after artifact write failed: %s", tostring(artifact_err))
  end
  local handle = worker_pool.system():submit({
    kind = "treesitter_usage_query",
    priority = "background",
    payload = artifact and { artifact = artifact } or query_payload,
    on_result = function(message)
      if message.type ~= "result" then return end
      local p = message.payload or {}
      request.results = p.usages or {}
      request.has_more = p.has_more and true or false
      request.diagnostics = p.diagnostics
    end,
    on_complete = function()
      cleanup_query_artifact(request.query_artifact)
      request.query_artifact = nil
      local stale_reason = async_snapshot_stale_reason(meta)
      if not stale_reason then
        request.status = request.source_status or "fresh"
      else
        request.status = "stale-cancelled"
        request.reason = stale_reason
        request.results = nil
      end
      request.done = true
    end,
    on_error = function(message)
      cleanup_query_artifact(request.query_artifact)
      request.query_artifact = nil
      request.status = "unavailable"
      request.reason = message and (message.error or (message.payload and message.payload.reason)) or "query-failed"
      request.done = true
    end,
    on_cancelled = function()
      cleanup_query_artifact(request.query_artifact)
      request.query_artifact = nil
      request.status = "cancelled"
      request.reason = "cancelled"
      request.done = true
    end,
  })
  if not handle then
    cleanup_query_artifact(artifact)
    return nil, "submit-failed", "unavailable", meta
  end
  request.handle = handle
  function request:cancel()
    cleanup_query_artifact(self.query_artifact)
    self.query_artifact = nil
    if self.handle then return worker_pool.system():cancel(self.handle) end
    return false
  end
  return request, nil, "pending", meta
end

function symbol_index.workspace_usages(name, opts)
  opts = opts or {}
  name = tostring(name or "")
  if name == "" then return {}, "no-symbol", "fresh", { has_more = false } end
  local roots = project_path_roots("usages", opts)
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
    if index.usage_status == "ready" then
      refresh_current_core_docs_for_index(index)
      local source = index.aggregate_dirty
        and combined_usages_for_name_from_entries(index, name)
        or combined_usages_for_name(index, name)
      for _, usage in ipairs(source) do all_usages[#all_usages + 1] = usage end
      root_status = "fresh"
      any_usable = true
    elseif opts.allow_stale and ((index.usages_by_name or {})[name] or next(index.open_docs or {}) ~= nil) then
      for _, usage in ipairs(combined_usages_for_name(index, name)) do all_usages[#all_usages + 1] = usage end
      root_status = "stale"
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
      any_usable = true
    else
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
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
    sort_usages(all_usages)
    local results
    results, has_more = filter_usages(all_usages, opts)
    has_more = has_more or usage_truncated
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

local function open_doc_entry_for(index, doc, path)
  local ts = doc and doc.treesitter
  if not ts or ts.status ~= "ready" or not ts.native then
    return nil, "not-ready"
  end
  local language = ts.language
  if not language then return nil, "missing-language" end
  local lines = doc_lines(doc)
  if not lines then return nil, "missing-lines" end
  local relpath = common.relative_path(index.root, path):gsub("\\", "/")
  local fake_doc = {
    lines = lines,
    abs_filename = path,
    filename = relpath,
    treesitter = ts,
    get_name = function() return relpath end,
    get_change_id = function() return doc.get_change_id and doc:get_change_id() or 0 end,
  }
  local symbols = extract_symbols_from_doc(fake_doc, path, relpath, language)
  local usage_query = ts.queries and (ts.queries.usages or ts.queries.locals)
  if not usage_query then usage_query = compile_usage_query(language) end
  local usages_by_name, usage_count = {}, 0
  if usage_query then
    usages_by_name, usage_count = extract_usages_from_state(ts.native, usage_query, path, relpath, lines, language)
    if not usages_by_name then usages_by_name, usage_count = {}, 0 end
  end
  return {
    doc = doc,
    change_id = doc.get_change_id and doc:get_change_id() or 0,
    symbols = symbols,
    usages_by_name = usages_by_name,
    usage_count = usage_count,
  }
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
        local entry = open_doc_entry_for(index, doc, path)
        if entry then
          index.open_docs[path] = entry
          changed = true
        end
      end
    end
  end
  for path, entry in pairs(index.open_docs or {}) do
    if not seen[path] or not entry.doc then
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
        local entry, err = open_doc_entry_for(index, doc, path)
        if entry then
          index.open_docs[path] = entry
          updated = true
          bump_overlay_generation(index)
        else
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
        index.open_docs[overlay_path] = nil
        cleared = true
        index_cleared = true
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

local function reindex_file_for_index(index, path, opts)
  opts = opts or {}
  if not index or not path or not common.path_belongs_to(path, index.root) then return false, "outside-project" end
  local info = system.get_file_info(path)
  local changed = false

  if not info or info.type ~= "file" then
    if index.by_path[path] then
      index.by_path[path] = nil
      changed = true
    end
    if index.open_docs[path] then
      index.open_docs[path] = nil
      changed = true
    end
    if changed then rebuild_disk_aggregates(index) end
    return changed, info and "not-file" or "missing"
  end

  local language = registry.get(path)
  if not language or not language.query_sources or not language.query_sources.outline then
    if index.by_path[path] then
      index.by_path[path] = nil
      changed = true
      rebuild_disk_aggregates(index)
    end
    index.open_docs[path] = nil
    return changed, "unsupported"
  end

  local fingerprint = file_fingerprint(path, info, language)
  local cached = index.by_path[path]
  if not opts.force and cached and cached.fingerprint == fingerprint then return false, "fresh" end

  local relpath = common.relative_path(index.root, path):gsub("\\", "/")
  local entry, err = parse_file_index(path, relpath, info, language, { include_usages = true })
  if entry then
    replace_file_entry(index, path, fingerprint, entry)
    changed = true
  else
    replace_file_entry(index, path, fingerprint, { symbols = {}, usages_by_name = {}, usage_count = 0 })
    changed = true
    log_quiet("Tree-sitter Project index: skipped targeted reindex for %s: %s", tostring(relpath), tostring(err))
  end

  index.open_docs[path] = nil
  rebuild_disk_aggregates(index)
  return changed, err
end

local function reindex_directory_for_index(index, dir, opts)
  opts = opts or {}
  if not index or not dir then return false, "no-directory" end
  if not (common.path_equals(dir, index.root) or common.path_belongs_to(dir, index.root)) then
    return false, "outside-project"
  end

  local changed = false
  local info = system.get_file_info(dir)
  if not info or info.type ~= "dir" then
    prune_missing_watches(index, dir)
    for path in pairs(index.by_path or {}) do
      if common.path_equals(path, dir) or common.path_belongs_to(path, dir) then
        index.by_path[path] = nil
        changed = true
      end
    end
    for path in pairs(index.open_docs or {}) do
      if common.path_equals(path, dir) or common.path_belongs_to(path, dir) then
        index.open_docs[path] = nil
        changed = true
      end
    end
    if changed then rebuild_disk_aggregates(index) end
    return changed, info and "not-directory" or "missing"
  end

  if index.watcher then refresh_watches_for_dir(index, dir) end

  local project = Project(index.root)
  local present_files = {}
  local stack = { dir }
  local yielded = 0
  while #stack > 0 do
    local current = table.remove(stack)
    local names, err = system.list_dir(current)
    if not names then return changed, err or "list-failed" end
    for _, name in ipairs(names) do
      local path = common.normalize_path(current .. PATHSEP .. name)
      local child = project:get_file_info(path)
      if child and child.type == "dir" then
        stack[#stack + 1] = path
      elseif child and child.type == "file" then
        child.filename = path
        present_files[path] = true
        local child_changed = reindex_file_for_index(index, path, common.merge(opts, { force = opts.force ~= false }))
        changed = child_changed or changed
      end
    end
    yielded = yielded + 1
    if yielded >= DEFAULT_SCAN_YIELD_FILES * 16 then
      yielded = 0
      safe_yield(0)
    end
  end

  for path in pairs(index.by_path or {}) do
    if (common.path_equals(path, dir) or common.path_belongs_to(path, dir)) and not present_files[path] then
      index.by_path[path] = nil
      index.open_docs[path] = nil
      changed = true
    end
  end

  if changed then rebuild_disk_aggregates(index) end
  return changed
end

local function finish_targeted_worker_reindex(index, message, status)
  if not current_worker_message(index, message) then return end
  if status == "ready" and index.worker_targeted_paths then
    for path in pairs(index.worker_targeted_paths) do
      if not (index.worker_adopted_paths and index.worker_adopted_paths[path]) then
        replace_file_entry(index, path, nil, { symbols = {}, usages_by_name = {}, usage_count = 0 })
        mark_aggregate_dirty(index)
      end
    end
  end
  if status == "ready" and index.worker_targeted_dir then
    local dir = index.worker_targeted_dir
    for path in pairs(index.by_path or {}) do
      if (common.path_equals(path, dir) or common.path_belongs_to(path, dir))
      and not (index.worker_adopted_paths and index.worker_adopted_paths[path]) then
        index.by_path[path] = nil
        index.open_docs[path] = nil
        mark_aggregate_dirty(index)
      end
    end
  end
  maybe_rebuild_dirty_aggregates(index, true)
  index.status = status
  if status == "ready" then
    index.symbol_status = "ready"
    index.usage_status = "ready"
    index.reason = nil
  else
    index.symbol_status = status
    index.usage_status = status
    index.reason = message.error or (message.payload and message.payload.reason) or status
  end
  index.worker_handle = nil
  index.worker_seen_paths = nil
  index.worker_adopted_paths = nil
  index.worker_targeted_paths = nil
  index.worker_targeted_dir = nil
  index.finished_at = system.get_time()
  core.redraw = true
  if status == "ready" then drain_pending_reindexes(index) end
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
  if not info or info.type ~= "file" then
    local changed = false
    if index.by_path[path] then
      index.by_path[path] = nil
      changed = true
    end
    if index.open_docs[path] then
      index.open_docs[path] = nil
      changed = true
    end
    if changed then rebuild_disk_aggregates(index) end
    return true, info and "not-file" or "missing"
  end

  local language = registry.get(path)
  if not language or not language.query_sources or not language.query_sources.outline then
    local changed = false
    if index.by_path[path] then
      index.by_path[path] = nil
      changed = true
    end
    if index.open_docs[path] then
      index.open_docs[path] = nil
      changed = true
    end
    if changed then rebuild_disk_aggregates(index) end
    return true, "unsupported"
  end

  local fingerprint = file_fingerprint(path, info, language)
  local cached = index.by_path[path]
  if not opts.force and cached and cached.fingerprint == fingerprint then return true, "fresh" end

  cancel_index_work(index)
  index.generation = (index.generation or 0) + 1
  index.project_paths_generation = project_paths_module().generation()
  local generation = index.generation
  local project_paths_generation = index.project_paths_generation
  index.status = "indexing"
  index.symbol_status = "indexing"
  index.usage_status = "indexing"
  index.reason = opts.reason or "file-dirty"
  index.started_at = system.get_time()
  index.finished_at = nil
  index.worker_seen_paths = { [path] = true }
  index.worker_adopted_paths = {}
  index.worker_targeted_paths = { [path] = true }
  index.worker_targeted_dir = nil
  index.diagnostics = {
    ui = {},
    phases = {},
    phase = "targeted",
    generation = generation,
    project_paths_generation = project_paths_generation,
    root = index.root,
  }

  local handle, err = worker_pool.system():submit({
    kind = "treesitter_project_index",
    priority = "background",
    generation = generation,
    project_paths_generation = project_paths_generation,
    phase = "targeted",
    payload = {
      root = index.root,
      root_path = index.root,
      files = {
        {
          path = path,
          root = index.root,
          info = serializable_file_info(info),
          language_id = language.id,
        },
      },
      excluded = project_index_exclusions_payload(),
      ignore_files = config.ignore_files,
      languages = project_index_languages_payload(),
      include_usages = true,
      project_usage_cap = index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP,
      max_file_bytes = MAX_FILE_BYTES,
      chunk_files = 1,
      chunk_records = opts.chunk_records or DEFAULT_WORKER_CHUNK_RECORDS,
      max_usage_captures_per_file = opts.max_usage_captures_per_file or DEFAULT_MAX_CAPTURES,
      artifact_chunks = false,
      native_index_jobs = opts.native_index_jobs,
      native_result_capture_chunk = opts.native_result_capture_chunk,
    },
    is_stale = function(message)
      return not current_worker_message(index, message)
    end,
    on_result = function(message)
      if message.type == "chunk" then
        apply_worker_chunk(index, message)
      elseif message.type == "final" and current_worker_message(index, message) then
        local p = message.payload or {}
        index.files_scanned = p.files_scanned or index.files_scanned
        index.files_indexed = p.files_indexed or index.files_indexed
        if p.diagnostics then
          index.diagnostics = index.diagnostics or { ui = {}, phases = {} }
          index.diagnostics.worker = p.diagnostics
          index.diagnostics.phases = index.diagnostics.phases or {}
          index.diagnostics.phases.targeted = {
            worker = p.diagnostics,
            ui = common.merge({}, index.diagnostics.ui or {}),
          }
        end
      end
    end,
    on_error = function(message)
      finish_targeted_worker_reindex(index, message, "failed")
    end,
    on_cancelled = function(message)
      finish_targeted_worker_reindex(index, message, "cancelled")
    end,
    on_complete = function(message)
      finish_targeted_worker_reindex(index, message, "ready")
    end,
  })

  if not handle then
    index.status = "failed"
    index.symbol_status = "failed"
    index.usage_status = "failed"
    index.reason = err or "worker-submit-failed"
    index.worker_handle = nil
    return false, err or "worker-submit-failed"
  end
  index.worker_handle = handle
  log_quiet("Tree-sitter Project index: submitted targeted worker reindex for %s under %s (%s)",
    tostring(path), tostring(index.root), tostring(opts.reason or "file-dirty"))
  return true, "scheduled"
end

local function submit_targeted_directory_reindex(index, dir, opts)
  opts = opts or {}
  if not index or not dir then return false, "no-index" end
  if not (common.path_equals(dir, index.root) or common.path_belongs_to(dir, index.root)) then
    return false, "outside-project"
  end

  local info = system.get_file_info(dir)
  if not info or info.type ~= "dir" then
    prune_missing_watches(index, dir)
    local changed = false
    for path in pairs(index.by_path or {}) do
      if common.path_equals(path, dir) or common.path_belongs_to(path, dir) then
        index.by_path[path] = nil
        changed = true
      end
    end
    for path in pairs(index.open_docs or {}) do
      if common.path_equals(path, dir) or common.path_belongs_to(path, dir) then
        index.open_docs[path] = nil
        changed = true
      end
    end
    if changed then rebuild_disk_aggregates(index) end
    return true, info and "not-directory" or "missing"
  end

  if index.watcher then refresh_watches_for_dir(index, dir) end
  cancel_index_work(index)
  index.generation = (index.generation or 0) + 1
  index.project_paths_generation = project_paths_module().generation()
  local generation = index.generation
  local project_paths_generation = index.project_paths_generation
  index.status = "indexing"
  index.symbol_status = "indexing"
  index.usage_status = "indexing"
  index.reason = opts.reason or "directory-dirty"
  index.started_at = system.get_time()
  index.finished_at = nil
  index.worker_seen_paths = {}
  index.worker_adopted_paths = {}
  index.worker_targeted_paths = nil
  index.worker_targeted_dir = dir
  index.diagnostics = {
    ui = {},
    phases = {},
    phase = "targeted-directory",
    generation = generation,
    project_paths_generation = project_paths_generation,
    root = index.root,
  }

  local handle, err = worker_pool.system():submit({
    kind = "treesitter_project_index",
    priority = "background",
    generation = generation,
    project_paths_generation = project_paths_generation,
    phase = "targeted-directory",
    payload = {
      roots = { { path = dir, root_path = index.root } },
      root = index.root,
      root_path = index.root,
      excluded = project_index_exclusions_payload(),
      ignore_files = config.ignore_files,
      languages = project_index_languages_payload(),
      include_usages = true,
      project_usage_cap = index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP,
      max_file_bytes = MAX_FILE_BYTES,
      chunk_files = opts.chunk_files or 8,
      chunk_records = opts.chunk_records or DEFAULT_WORKER_CHUNK_RECORDS,
      max_usage_captures_per_file = opts.max_usage_captures_per_file or DEFAULT_MAX_CAPTURES,
      artifact_chunks = opts.artifact_chunks == true,
      artifact_dir = opts.artifact_dir or default_index_artifact_dir(),
      native_index_jobs = opts.native_index_jobs,
      native_result_capture_chunk = opts.native_result_capture_chunk,
    },
    is_stale = function(message)
      return not current_worker_message(index, message)
    end,
    on_stale = cleanup_worker_artifact,
    on_result = function(message)
      if message.type == "chunk" then
        apply_worker_chunk(index, message)
      elseif message.type == "final" and current_worker_message(index, message) then
        local p = message.payload or {}
        index.files_scanned = p.files_scanned or index.files_scanned
        index.files_indexed = p.files_indexed or index.files_indexed
        if p.diagnostics then
          index.diagnostics = index.diagnostics or { ui = {}, phases = {} }
          index.diagnostics.worker = p.diagnostics
          index.diagnostics.phases = index.diagnostics.phases or {}
          index.diagnostics.phases["targeted-directory"] = {
            worker = p.diagnostics,
            ui = common.merge({}, index.diagnostics.ui or {}),
          }
        end
      end
    end,
    on_error = function(message)
      finish_targeted_worker_reindex(index, message, "failed")
    end,
    on_cancelled = function(message)
      finish_targeted_worker_reindex(index, message, "cancelled")
    end,
    on_complete = function(message)
      finish_targeted_worker_reindex(index, message, "ready")
    end,
  })

  if not handle then
    index.status = "failed"
    index.symbol_status = "failed"
    index.usage_status = "failed"
    index.reason = err or "worker-submit-failed"
    index.worker_handle = nil
    return false, err or "worker-submit-failed"
  end
  index.worker_handle = handle
  log_quiet("Tree-sitter Project index: submitted targeted directory worker reindex for %s under %s (%s)",
    tostring(dir), tostring(index.root), tostring(opts.reason or "directory-dirty"))
  return true, "scheduled"
end

local function run_reindex_file(path, opts)
  opts = opts or {}
  local changed = false
  local matched = false
  for _, index in pairs(indexes) do
    if common.path_belongs_to(path, index.root) then
      matched = true
      local generation = index.generation
      if index.status == "idle" then
        symbol_index.ensure_scan(index.root, { force = true })
      elseif index.status == "indexing" then
        index.pending_reindex_paths = index.pending_reindex_paths or {}
        index.pending_reindex_paths[path] = opts.reason or "queued-during-indexing"
        index.symbol_status = "indexing"
        index.usage_status = "indexing"
        log_quiet("Tree-sitter Project index: queued targeted reindex for %s under %s while indexing (%s)",
          tostring(path), tostring(index.root), tostring(index.pending_reindex_paths[path]))
        changed = true
      else
        index.generation = index.generation + 1
        generation = index.generation
        index.status = "indexing"
        index.symbol_status = "indexing"
        index.usage_status = "indexing"
        index.reason = opts.reason or "file-dirty"
        index.started_at = system.get_time()
        index.finished_at = nil

        local ok, result, detail = pcall(reindex_file_for_index, index, path, opts)
        if generation == index.generation then
          index.status = "ready"
          index.symbol_status = "ready"
          index.usage_status = "ready"
          index.reason = nil
          index.finished_at = system.get_time()
          core.redraw = true
          drain_pending_reindexes(index)
        end
        if ok then
          changed = result or changed
          log_quiet("Tree-sitter Project index: targeted reindex %s under %s changed=%s reason=%s detail=%s",
            tostring(path), tostring(index.root), tostring(result), tostring(opts.reason or "file-dirty"), tostring(detail))
        else
          log_quiet("Tree-sitter Project index: targeted reindex failed for %s under %s: %s", tostring(path), tostring(index.root), tostring(result))
        end
      end
    end
  end
  return matched and changed, matched and nil or "no-index"
end

function symbol_index.reindex_file(path, opts)
  opts = opts or {}
  path = path and common.normalize_path(path)
  if not path then return false, "no-path" end
  if opts.sync then return run_reindex_file(path, opts) end
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
          symbol_index.ensure_scan(index.root, {
            force = true,
            reason = opts.reason or "file-dirty",
          })
          log_quiet("Tree-sitter Project index: targeted worker reindex for %s under %s fell back to full refresh: %s",
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

local function run_reindex_directory(dir, opts)
  opts = opts or {}
  local changed = false
  local matched = false
  for _, index in pairs(indexes) do
    if common.path_equals(dir, index.root) or common.path_belongs_to(dir, index.root) then
      matched = true
      local generation = index.generation
      if index.status == "idle" then
        symbol_index.ensure_scan(index.root, { force = true })
      elseif index.status == "indexing" then
        index.pending_reindex_dirs = index.pending_reindex_dirs or {}
        index.pending_reindex_dirs[dir] = {
          reason = opts.reason or "directory-dirty",
          force = opts.force,
        }
        index.symbol_status = "indexing"
        index.usage_status = "indexing"
        log_quiet("Tree-sitter Project index: queued directory reindex for %s under %s while indexing (%s)",
          tostring(dir), tostring(index.root), tostring(index.pending_reindex_dirs[dir].reason))
        changed = true
      else
        index.generation = index.generation + 1
        generation = index.generation
        index.status = "indexing"
        index.symbol_status = "indexing"
        index.usage_status = "indexing"
        index.reason = opts.reason or "directory-dirty"
        index.started_at = system.get_time()
        index.finished_at = nil

        local ok, result, detail = pcall(reindex_directory_for_index, index, dir, opts)
        if generation == index.generation then
          index.status = "ready"
          index.symbol_status = "ready"
          index.usage_status = "ready"
          index.reason = nil
          index.finished_at = system.get_time()
          core.redraw = true
          drain_pending_reindexes(index)
        end
        if ok then
          changed = result or changed
          log_quiet("Tree-sitter Project index: directory reindex %s under %s changed=%s reason=%s detail=%s",
            tostring(dir), tostring(index.root), tostring(result), tostring(opts.reason or "directory-dirty"), tostring(detail))
        else
          log_quiet("Tree-sitter Project index: directory reindex failed for %s under %s: %s", tostring(dir), tostring(index.root), tostring(result))
        end
      end
    end
  end
  return matched and changed, matched and nil or "no-index"
end

function symbol_index.mark_directory_dirty(dir, reason, opts)
  opts = opts or {}
  dir = dir and common.normalize_path(dir)
  if not dir then return false, "no-directory" end
  opts = common.merge(opts, { reason = reason or opts.reason or "directory-dirty" })
  if opts.sync then return run_reindex_directory(dir, opts) end
  local matched = false
  for _, index in pairs(indexes) do
    if common.path_equals(dir, index.root) or common.path_belongs_to(dir, index.root) then
      matched = true
      if index.status == "indexing" then
        index.pending_reindex_dirs = index.pending_reindex_dirs or {}
        index.pending_reindex_dirs[dir] = {
          reason = opts.reason or "directory-dirty",
          force = opts.force,
        }
        log_quiet("Tree-sitter Project index: coalesced dirty directory refresh for %s under %s while worker indexing (%s)",
          tostring(dir), tostring(index.root), tostring(index.pending_reindex_dirs[dir].reason))
      else
        local submitted, submit_reason = submit_targeted_directory_reindex(index, dir, opts)
        if not submitted then
          symbol_index.ensure_scan(index.root, {
            force = true,
            reason = opts.reason or "directory-dirty",
          })
          log_quiet("Tree-sitter Project index: targeted directory worker reindex for %s under %s fell back to full refresh: %s",
            tostring(dir), tostring(index.root), tostring(submit_reason))
        else
          log_quiet("Tree-sitter Project index: scheduled targeted directory worker reindex for dirty directory %s under %s (%s)",
            tostring(dir), tostring(index.root), tostring(submit_reason or opts.reason or "directory-dirty"))
        end
      end
    end
  end
  return matched, matched and nil or "no-index"
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
  local results, has_more = filtered_symbols(symbols, query, opts.limit)
  return results, nil, "fresh", { has_more = has_more }
end

function symbol_index.status(root)
  return index_for_root(root)
end

function symbol_index.reset_for_tests()
  for _, index in pairs(indexes) do
    cancel_index_work(index)
    cleanup_index_query_artifacts(index)
    index.generation = (index.generation or 0) + 1
    index.watch_generation = (index.watch_generation or 0) + 1
    index.watch_running = false
    index.watcher = nil
    index.watched_dirs = {}
  end
  indexes = {}
  open_documents = setmetatable({}, { __mode = "v" })
  query_cache = {}
end

return symbol_index
