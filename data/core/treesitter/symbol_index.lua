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
local AdoptionQueue = require "core.treesitter.adoption_queue"
local ArtifactSession = require "core.treesitter.artifact_session"
local artifact_codec = require "core.treesitter.artifact_codec"
local fuzzy_ok, native_fuzzy = pcall(require, "fuzzy")
if not fuzzy_ok then native_fuzzy = nil end

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
local DEFAULT_WORKER_CHUNK_RECORDS = 512
local DEFAULT_WORKER_CHUNK_BYTES = 256 * 1024
local DEFAULT_AGGREGATE_CHUNK_RECORDS = 512
local DEFAULT_AGGREGATE_CHUNK_BYTES = 256 * 1024
local DEFAULT_ADOPTION_SLICE_RECORDS = 512
local DEFAULT_ADOPTION_SLICE_BYTES = 256 * 1024
local DEFAULT_ASYNC_SYMBOL_SNAPSHOT_LIMIT = 5000
local DEFAULT_ASYNC_USAGE_SNAPSHOT_LIMIT = 5000
local DEFAULT_SYNC_QUERY_ITEM_LIMIT = 5000
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

local function enqueue_adoption(index, item)
  if not index then return false, "no-index" end
  index.adoption_queue = index.adoption_queue or AdoptionQueue.new({
    max_item_bytes = DEFAULT_AGGREGATE_CHUNK_BYTES,
    max_item_records = DEFAULT_AGGREGATE_CHUNK_RECORDS,
  })
  local ok, err = index.adoption_queue:enqueue(item)
  if not ok then
    inc_ui_metric(index, "adoption_items_rejected", 1)
    log_quiet("Tree-sitter Project adoption: rejected item under %s: %s", tostring(index.root), tostring(err))
    return false, err
  end
  inc_ui_metric(index, "adoption_items_enqueued", 1)
  add_ui_metric(index, "adoption_bytes_enqueued", item.bytes or 0)
  add_ui_metric(index, "adoption_records_enqueued", item.records or 0)
  max_ui_metric(index, "adoption_queue_depth_max", index.adoption_queue:count())
  if not index.adoption_pump_running then
    index.adoption_pump_running = true
    core.add_thread(function()
      while index.adoption_queue and index.adoption_queue:count() > 0 do
        local started = now()
        max_ui_metric(index, "adoption_queue_oldest_age_max_ms", index.adoption_queue:oldest_age() * 1000)
        local result = index.adoption_queue:step({
          max_bytes = DEFAULT_ADOPTION_SLICE_BYTES,
          max_records = DEFAULT_ADOPTION_SLICE_RECORDS,
        })
        local duration = elapsed_ms(started)
        inc_ui_metric(index, "adoption_pump_slices", 1)
        add_ui_metric(index, "adoption_pump_ms", duration)
        max_ui_metric(index, "adoption_pump_max_ms", duration)
        add_ui_metric(index, "adoption_pump_bytes", result.bytes or 0)
        add_ui_metric(index, "adoption_pump_records", result.records or 0)
        add_ui_metric(index, "adoption_items_discarded", result.discarded or 0)
        inc_worker_pool_frame_metric("treesitter_project_adoption_pump_slices", 1)
        add_worker_pool_frame_metric("treesitter_project_adoption_pump_ms", duration)
        max_worker_pool_frame_metric("treesitter_project_adoption_pump_max_ms", duration)
        add_worker_pool_frame_metric("treesitter_project_adoption_pump_bytes", result.bytes or 0)
        add_worker_pool_frame_metric("treesitter_project_adoption_pump_records", result.records or 0)
        max_worker_pool_frame_metric("treesitter_project_adoption_queue_depth", result.remaining or 0)
        if result.adopted == 0 and result.discarded == 0 then
          log_quiet("Tree-sitter Project adoption: queue stalled under %s", tostring(index.root))
          break
        end
        core.redraw = true
        safe_yield(0)
      end
      index.adoption_pump_running = false
    end)
  end
  return true
end

local function reset_adoption_queue(index)
  if not index then return end
  index.adoption_queue = AdoptionQueue.new({
    max_item_bytes = DEFAULT_AGGREGATE_CHUNK_BYTES,
    max_item_records = DEFAULT_AGGREGATE_CHUNK_RECORDS,
  })
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
    aggregate_dirty = false,
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
    item.prefix_span = display.prefix_span
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
      metadata.prefix_span = display.prefix_span
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
  item.prefix_span = metadata.prefix_span
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

local invalidate_index_query_artifacts
local cleanup_index_query_artifacts

local function sorted_insert(list, item, less)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if less(item, list[mid]) then
      hi = mid
    else
      lo = mid + 1
    end
  end
  table.insert(list, lo, item)
end

local function remove_path_from_disk_aggregates(index, path)
  if not (index and path) then return 0, 0 end
  local removed_symbols = 0
  local symbols = index.symbols or {}
  local write = 1
  for read = 1, #symbols do
    local symbol = symbols[read]
    if symbol and symbol.path == path then
      removed_symbols = removed_symbols + 1
    else
      symbols[write] = symbol
      write = write + 1
    end
  end
  for i = write, #symbols do symbols[i] = nil end

  local removed_usages = 0
  for name, list in pairs(index.usages_by_name or {}) do
    local out = 1
    for read = 1, #list do
      local usage = list[read]
      if usage and usage.path == path then
        removed_usages = removed_usages + 1
      else
        list[out] = usage
        out = out + 1
      end
    end
    for i = out, #list do list[i] = nil end
    if #list == 0 then index.usages_by_name[name] = nil end
  end
  index.usage_count = math.max(0, (index.usage_count or 0) - removed_usages)
  return removed_symbols, removed_usages
end

local function insert_entry_into_disk_aggregates(index, entry)
  if not (index and entry) then return false end
  local cap = tonumber(index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP) or DEFAULT_PROJECT_USAGE_CAP
  if entry.usage_complete == false or index.usage_truncated then return false, "usage-truncated" end
  index.symbols = index.symbols or {}
  index.usages_by_name = index.usages_by_name or {}
  for _, symbol in ipairs(entry.symbols or {}) do sorted_insert(index.symbols, symbol, symbol_less) end
  for name, list in pairs(entry.usages_by_name or {}) do
    local out = index.usages_by_name[name]
    if not out then
      out = {}
      index.usages_by_name[name] = out
    end
    for _, usage in ipairs(list) do
      if (index.usage_count or 0) >= cap then return false, "usage-cap" end
      sorted_insert(out, usage, usage_less)
      index.usage_count = (index.usage_count or 0) + 1
    end
  end
  return true
end

local function apply_incremental_file_aggregate(index, path, entry)
  if not (index and path and entry) or index.aggregate_dirty then return false, "aggregate-dirty" end
  local started = now()
  if index.usage_truncated or entry.usage_complete == false then return false, "usage-truncated" end
  remove_path_from_disk_aggregates(index, path)
  local ok, err = insert_entry_into_disk_aggregates(index, entry)
  if not ok then return false, err end
  invalidate_combined_symbols_cache(index)
  invalidate_index_query_artifacts(index)
  local duration = elapsed_ms(started)
  inc_ui_metric(index, "incremental_aggregate_updates", 1)
  add_ui_metric(index, "incremental_aggregate_ms", duration)
  max_ui_metric(index, "incremental_aggregate_max_ms", duration)
  add_worker_pool_frame_metric("treesitter_project_incremental_aggregate_ms", duration)
  max_worker_pool_frame_metric("treesitter_project_incremental_aggregate_max_ms", duration)
  return true
end

local function mark_aggregate_dirty(index)
  if not index then return end
  index.aggregate_dirty = true
  invalidate_combined_symbols_cache(index)
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

local function cleanup_worker_artifacts(artifacts)
  for _, artifact in ipairs(artifacts or {}) do
    local path = type(artifact) == "table" and artifact.path or artifact
    if path then pcall(os.remove, path) end
  end
end

local function inline_worker_chunk_payload(message)
  local payload = message.payload or {}
  if payload.artifact then
    log_quiet("Tree-sitter Project index: rejected artifact chunk without a compact manifest: %s",
      tostring(payload.artifact.path))
    return { files = {}, diagnostics = payload.diagnostics or {} }
  end
  return payload
end

local function reset_pending_aggregate(index, message)
  index.pending_aggregate = {
    generation = message.generation,
    project_paths_generation = message.project_paths_generation,
    phase = message.phase,
    symbols = {},
    usages_by_name = {},
    usage_count = 0,
    usage_truncated = false,
    usage_truncated_reason = nil,
  }
  return index.pending_aggregate
end

local function apply_worker_aggregate_chunk(index, message)
  if not current_worker_message(index, message) then return end
  local payload = message.payload or {}
  local adoption_started = now()
  local pending = index.pending_aggregate
  if payload.reset or not pending
    or pending.generation ~= message.generation
    or pending.project_paths_generation ~= message.project_paths_generation
    or pending.phase ~= message.phase
  then
    pending = reset_pending_aggregate(index, message)
  end
  for _, symbol in ipairs(payload.symbols or {}) do pending.symbols[#pending.symbols + 1] = symbol end
  for name, list in pairs(payload.usages_by_name or {}) do
    local out = pending.usages_by_name[name]
    if not out then
      out = {}
      pending.usages_by_name[name] = out
    end
    for _, usage in ipairs(list) do out[#out + 1] = usage end
  end
  pending.usage_count = (pending.usage_count or 0) + (payload.usage_count or count_usages(payload.usages_by_name))
  if payload.usage_truncated ~= nil then pending.usage_truncated = payload.usage_truncated and true or false end
  if payload.usage_truncated_reason ~= nil then pending.usage_truncated_reason = payload.usage_truncated_reason end
  local duration = elapsed_ms(adoption_started)
  add_ui_metric(index, "aggregate_chunk_adoption_ms", duration)
  max_ui_metric(index, "aggregate_chunk_adoption_max_ms", duration)
  inc_ui_metric(index, "aggregate_chunks_adopted", 1)
  add_worker_pool_frame_metric("treesitter_project_aggregate_chunk_adoption_ms", duration)
  max_worker_pool_frame_metric("treesitter_project_aggregate_chunk_adoption_max_ms", duration)
  inc_worker_pool_frame_metric("treesitter_project_aggregate_chunks_adopted", 1)
end

local function finish_pending_aggregate(index, message)
  if not current_worker_message(index, message) then return false end
  local pending = index.pending_aggregate
  if not pending
    or pending.generation ~= message.generation
    or pending.project_paths_generation ~= message.project_paths_generation
    or pending.phase ~= message.phase
  then
    return false
  end
  local started = now()
  index.symbols = pending.symbols or {}
  index.usages_by_name = pending.usages_by_name or {}
  index.usage_count = pending.usage_count or count_usages(index.usages_by_name)
  index.usage_truncated = pending.usage_truncated and true or false
  index.usage_truncated_reason = pending.usage_truncated_reason
  index.pending_aggregate = nil
  index.aggregate_dirty = false
  invalidate_combined_symbols_cache(index)
  invalidate_index_query_artifacts(index)
  local duration = elapsed_ms(started)
  inc_ui_metric(index, "worker_aggregate_adoptions", 1)
  add_ui_metric(index, "worker_aggregate_adoption_ms", duration)
  max_ui_metric(index, "worker_aggregate_adoption_max_ms", duration)
  inc_worker_pool_frame_metric("treesitter_project_worker_aggregate_adoptions", 1)
  add_worker_pool_frame_metric("treesitter_project_worker_aggregate_adoption_ms", duration)
  max_worker_pool_frame_metric("treesitter_project_worker_aggregate_adoption_max_ms", duration)
  return true
end

local function apply_worker_manifest_chunk(index, message)
  if not current_worker_message(index, message) then cleanup_worker_artifact(message); return end
  local adoption_started = now()
  local payload = message.payload or {}
  local chunk_diag = payload.diagnostics or {}
  local changed = false
  for _, item in ipairs(payload.manifest or {}) do
    local path = item.path and common.normalize_path(item.path)
    if path then
      local existing = index.by_path and index.by_path[path]
      local entry = { fingerprint = item.fingerprint }
      if item.usage_complete ~= nil then
        entry.usage_complete = item.usage_complete and true or false
      elseif existing and existing.fingerprint == item.fingerprint then
        entry.usage_complete = existing.usage_complete
      end
      index.by_path[path] = entry
      index.worker_seen_paths = index.worker_seen_paths or {}
      index.worker_seen_paths[path] = true
      if index.worker_adopted_paths then index.worker_adopted_paths[path] = true end
      changed = true
    end
  end
  inc_ui_metric(index, "chunks_adopted", 1)
  inc_ui_metric(index, "manifest_chunks_adopted", 1)
  inc_ui_metric(index, "manifest_files_adopted", #(payload.manifest or {}))
  add_ui_metric(index, "chunk_records_deferred", chunk_diag.records or 0)
  inc_worker_pool_frame_metric("treesitter_project_manifest_chunks_adopted", 1)
  add_worker_pool_frame_metric("treesitter_project_manifest_files_adopted", #(payload.manifest or {}))
  if changed then
    mark_aggregate_dirty(index)
    core.redraw = true
  end
  local duration = elapsed_ms(adoption_started)
  add_ui_metric(index, "manifest_adoption_ms", duration)
  max_ui_metric(index, "manifest_adoption_max_ms", duration)
  add_worker_pool_frame_metric("treesitter_project_manifest_adoption_ms", duration)
  max_worker_pool_frame_metric("treesitter_project_manifest_adoption_max_ms", duration)
end

local function apply_worker_chunk(index, message)
  if not current_worker_message(index, message) then cleanup_worker_artifact(message); return end
  local raw_payload = message.payload or {}
  if raw_payload.artifact and raw_payload.manifest then
    apply_worker_manifest_chunk(index, message)
    return
  end
  local adoption_started = now()
  local payload = inline_worker_chunk_payload(message)
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
    local rebuilt = false
    local defer_for_incremental_target = index.worker_targeted_paths and not index.worker_targeted_dir
    if defer_for_incremental_target then
      inc_ui_metric(index, "chunk_aggregate_incremental_deferred", 1)
      inc_worker_pool_frame_metric("treesitter_project_chunk_aggregate_incremental_deferred", 1)
    else
      mark_aggregate_dirty(index)
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
    local native_wrapper_ms = math.max(0,
      (tonumber(worker.native_index_text_ms) or 0) - (tonumber(worker.native_total_ms) or 0))
    log_quiet("Tree-sitter indexing profile: root=%s cumulative_worker_ms=%.1f native_wrapper_ms=%.1f native_total_ms=%.1f native_prepare_input_ms=%.1f native_parser_setup_ms=%.1f native_parse_ms=%.1f native_project_record_ms=%.1f outline_compile_ms=%.1f outline_query_ms=%.1f outline_line_index_ms=%.1f usage_compile_ms=%.1f usage_query_ms=%.1f usage_line_index_ms=%.1f query_cache_hits=%d query_cache_misses=%d parser_reuses=%d line_indexes_skipped=%d native_other_ms=%.1f native_submit_ms=%.1f native_drain_ms=%.1f native_adapt_ms=%.1f line_split_ms=%.1f directory_walk_ms=%.1f artifact_mkdir_ms=%.1f artifact_write_ms=%.1f symbol_record_ms=%.1f usage_record_ms=%.1f chunk_send_wait_ms=%.1f bytes_read=%d outline_captures=%d usage_captures=%d",
      tostring(index.root),
      tonumber(worker.total_ms or 0) or 0,
      native_wrapper_ms,
      tonumber(worker.native_total_ms or 0) or 0,
      tonumber(worker.native_prepare_input_ms or 0) or 0,
      tonumber(worker.native_parser_setup_ms or 0) or 0,
      tonumber(worker.parse_ms or 0) or 0,
      tonumber(worker.native_project_record_ms or 0) or 0,
      tonumber(worker.outline_query_compile_ms or 0) or 0,
      tonumber(worker.outline_query_ms or 0) or 0,
      tonumber(worker.outline_line_index_ms or 0) or 0,
      tonumber(worker.usage_query_compile_ms or 0) or 0,
      tonumber(worker.usage_query_ms or 0) or 0,
      tonumber(worker.usage_line_index_ms or 0) or 0,
      tonumber(worker.query_cache_hits or 0) or 0,
      tonumber(worker.query_cache_misses or 0) or 0,
      tonumber(worker.parser_reuses or 0) or 0,
      tonumber(worker.line_indexes_skipped or 0) or 0,
      tonumber(worker.native_other_ms or 0) or 0,
      tonumber(worker.native_index_submit_ms or 0) or 0,
      tonumber(worker.native_index_drain_ms or 0) or 0,
      tonumber(worker.native_index_result_adapt_ms or 0) or 0,
      tonumber(worker.line_split_ms or 0) or 0,
      tonumber(worker.directory_walk_ms or 0) or 0,
      tonumber(worker.artifact_mkdir_ms or 0) or 0,
      tonumber(worker.artifact_write_ms or 0) or 0,
      tonumber(worker.symbol_record_ms or 0) or 0,
      tonumber(worker.usage_record_ms or 0) or 0,
      tonumber(worker.chunk_send_wait_ms or 0) or 0,
      tonumber(worker.bytes_read or 0) or 0,
      tonumber(worker.outline_captures or 0) or 0,
      tonumber(worker.usage_captures or 0) or 0)
    log_quiet("Tree-sitter aggregate profile: root=%s coordinator_ms=%.1f shards_ms=%.1f aggregate_total_ms=%.1f load_ms=%.1f append_ms=%.1f symbol_sort_ms=%.1f usage_sort_ms=%.1f symbol_artifact_ms=%.1f usage_artifact_ms=%.1f artifact_encode_ms=%.1f artifact_write_ms=%.1f emit_reset_ms=%.1f emit_symbols_ms=%.1f emit_usages_ms=%.1f emit_serialize_ms=%.1f emit_send_wait_ms=%.1f emit_chunks=%d emit_records=%d serialized_size_calls=%d serialized_size_bytes=%d artifacts_loaded=%d files_loaded=%d query_artifacts_written=%d query_artifact_bytes=%d",
      tostring(index.root),
      tonumber(worker.coordinator_total_ms or 0) or 0,
      tonumber(worker.sharded_total_ms or 0) or 0,
      tonumber(worker.aggregate_total_ms or 0) or 0,
      tonumber(worker.aggregate_load_ms or 0) or 0,
      tonumber(worker.aggregate_append_ms or 0) or 0,
      tonumber(worker.aggregate_symbol_sort_ms or 0) or 0,
      tonumber(worker.aggregate_usage_sort_ms or 0) or 0,
      tonumber(worker.aggregate_symbol_query_artifact_ms or 0) or 0,
      tonumber(worker.aggregate_usage_query_artifact_ms or 0) or 0,
      tonumber(worker.aggregate_query_artifact_encode_ms or 0) or 0,
      tonumber(worker.aggregate_query_artifact_file_write_ms or 0) or 0,
      tonumber(worker.aggregate_emit_reset_ms or 0) or 0,
      tonumber(worker.aggregate_emit_symbols_ms or 0) or 0,
      tonumber(worker.aggregate_emit_usages_ms or 0) or 0,
      tonumber(worker.aggregate_emit_serialize_ms or 0) or 0,
      tonumber(worker.aggregate_emit_send_wait_ms or 0) or 0,
      tonumber(worker.aggregate_emit_chunks or 0) or 0,
      tonumber(worker.aggregate_emit_records or 0) or 0,
      tonumber(worker.aggregate_serialized_size_calls or 0) or 0,
      tonumber(worker.aggregate_serialized_size_bytes or 0) or 0,
      tonumber(worker.aggregate_artifacts_loaded or 0) or 0,
      tonumber(worker.aggregate_files_loaded or 0) or 0,
      tonumber(worker.aggregate_query_artifacts_written or 0) or 0,
      tonumber(worker.aggregate_query_artifact_bytes or 0) or 0)
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
local default_query_artifact_dir

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
  if index.worker_run and index.worker_run.aggregate_handle then
    cancelled = worker_pool.system():cancel(index.worker_run.aggregate_handle) or cancelled
  end
  if index.worker_run and index.worker_run.aggregate_artifacts then
    cleanup_worker_artifacts(index.worker_run.aggregate_artifacts)
  end
  if index.worker_aggregate_artifacts then
    cleanup_worker_artifacts(index.worker_aggregate_artifacts)
    index.worker_aggregate_artifacts = nil
  end
  index.pending_aggregate = nil
  reset_adoption_queue(index)
  index.worker_base_aggregate = nil
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
  elseif role == "aggregate" then
    worker.aggregate_jobs = (worker.aggregate_jobs or 0) + 1
  end

  for key, value in pairs(diagnostics) do
    if type(value) == "number" then
      if role and key ~= "worker_id" and key ~= "job_id" then
        local role_key = tostring(role) .. "_" .. tostring(key)
        if tostring(key):match("_max$") or key == "files_scanned" then
          worker[role_key] = math.max(worker[role_key] or 0, value)
        else
          worker[role_key] = (worker[role_key] or 0) + value
        end
      end
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

local function symbol_query_artifact_key(index, kind)
  local project_paths_generation = project_paths_module().generation()
  return table.concat({ "symbols", kind or "symbols", tostring(index.generation), tostring(project_paths_generation) }, "\0"), project_paths_generation
end

local function store_symbol_query_artifact(index, kind, artifact)
  if not (index and artifact and (artifact.path or artifact.chunks)) then return end
  local key, project_paths_generation = symbol_query_artifact_key(index, kind or "symbols")
  index.query_artifacts = index.query_artifacts or {}
  artifact.generation = index.generation
  artifact.project_paths_generation = project_paths_generation
  artifact.kind = kind or "symbols"
  index.query_artifacts[key] = artifact
end

local function usage_query_artifact_key(index)
  local project_paths_generation = project_paths_module().generation()
  return table.concat({ "usages-all", tostring(index.generation), tostring(project_paths_generation) }, "\0"), project_paths_generation
end

local function store_usage_query_artifact(index, artifact)
  if not (index and artifact and (artifact.path or artifact.chunks)) then return end
  local key, project_paths_generation = usage_query_artifact_key(index)
  index.query_artifacts = index.query_artifacts or {}
  artifact.generation = index.generation
  artifact.project_paths_generation = project_paths_generation
  artifact.all_usages = true
  index.query_artifacts[key] = artifact
end

local function submit_worker_aggregate(index, run, message, on_done)
  if not current_run_message(index, run, message) then return false end
  local artifacts = run.aggregate_artifacts or {}
  if #artifacts == 0 then return false, "no-artifacts" end
  reset_pending_aggregate(index, message)
  local handle, err = worker_pool.system():submit({
    kind = "treesitter_project_aggregate",
    priority = "background",
    generation = run.generation,
    project_paths_generation = run.project_paths_generation,
    phase = run.phase,
    payload = {
      artifacts = artifacts,
      include_usages = run.phase ~= "symbols",
      project_usage_cap = index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP,
      chunk_records = (run.opts and run.opts.aggregate_chunk_records) or DEFAULT_AGGREGATE_CHUNK_RECORDS,
      chunk_bytes = (run.opts and run.opts.aggregate_chunk_bytes) or DEFAULT_AGGREGATE_CHUNK_BYTES,
      query_artifact_chunk_records = (run.opts and run.opts.query_artifact_chunk_records) or DEFAULT_AGGREGATE_CHUNK_RECORDS,
      query_artifact_chunk_bytes = (run.opts and run.opts.query_artifact_chunk_bytes) or DEFAULT_AGGREGATE_CHUNK_BYTES,
      remove_artifacts = true,
      query_artifact_dir = default_query_artifact_dir(),
      replacement_dir = run.replacement_dir,
      base_symbol_artifact = run.base_symbol_artifact,
      base_usage_artifact = run.base_usage_artifact,
      base_usage_truncated = run.base_usage_truncated,
      base_usage_truncated_reason = run.base_usage_truncated_reason,
    },
    is_stale = function(aggregate_message)
      return not current_run_message(index, run, aggregate_message)
    end,
    on_stale = function()
      cleanup_worker_artifacts(artifacts)
    end,
    on_result = function(aggregate_message)
      if not current_run_message(index, run, aggregate_message) then return end
      if aggregate_message.type == "chunk" and (aggregate_message.payload or {}).kind == "aggregate" then
        local p = aggregate_message.payload or {}
        local queued, queue_err = enqueue_adoption(index, {
          bytes = p.serialized_bytes or 0,
          records = p.records or 0,
          stale = function() return not current_run_message(index, run, aggregate_message) end,
          adopt = function() apply_worker_aggregate_chunk(index, aggregate_message) end,
        })
        if not queued then
          index.reason = queue_err or "aggregate-adoption-rejected"
        end
      elseif aggregate_message.type == "final" then
        local p = aggregate_message.payload or {}
        if p.diagnostics then add_worker_diagnostics(index, run.phase, p.diagnostics, "aggregate") end
      end
    end,
    on_error = function(aggregate_message)
      cleanup_worker_artifacts(artifacts)
      reset_adoption_queue(index)
      index.pending_aggregate = nil
      if on_done then on_done(false, aggregate_message) end
    end,
    on_cancelled = function(aggregate_message)
      cleanup_worker_artifacts(artifacts)
      reset_adoption_queue(index)
      index.pending_aggregate = nil
      if on_done then on_done(false, aggregate_message) end
    end,
    on_complete = function(aggregate_message)
      if not current_run_message(index, run, aggregate_message) then return end
      local queued, queue_err = enqueue_adoption(index, {
        bytes = 0,
        records = 0,
        stale = function() return not current_run_message(index, run, aggregate_message) end,
        adopt = function()
          finish_pending_aggregate(index, aggregate_message)
          local p = aggregate_message.payload or {}
          store_symbol_query_artifact(index, "symbols", p.symbol_query_artifact)
          store_usage_query_artifact(index, p.usage_query_artifact)
          run.aggregate_artifacts = {}
          if on_done then on_done(true, aggregate_message) end
        end,
      })
      if not queued then
        cleanup_worker_artifacts(artifacts)
        index.pending_aggregate = nil
        if on_done then on_done(false, { error = queue_err or "aggregate-adoption-rejected" }) end
      end
    end,
  })
  if not handle then
    cleanup_worker_artifacts(artifacts)
    index.pending_aggregate = nil
    return false, err or "aggregate-submit-failed"
  end
  run.aggregate_handle = handle
  return true
end

local function finish_sharded_phase(index, run, status, message)
  if not current_run_message(index, run, message) then return end
  run.terminal = true
  if status == "ready" and run.aggregate_artifacts and #run.aggregate_artifacts > 0 then
    local submitted = submit_worker_aggregate(index, run, message, function(ok, aggregate_message)
      index.worker_run = nil
      finish_worker_scan(index, aggregate_message or message, ok and "ready" or "failed")
    end)
    if submitted then return end
    index.worker_run = nil
    finish_worker_scan(index, message, "failed")
  else
    index.worker_run = nil
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

local artifact_session

local function current_artifact_session()
  if artifact_session then return artifact_session end
  local base = USERDIR or (system and system.absolute_path and system.absolute_path(".") or ".")
  artifact_session = ArtifactSession.new({
    base_dir = common.normalize_path(base .. PATHSEP .. "treesitter-artifacts"),
    legacy_dirs = {
      common.normalize_path(base .. PATHSEP .. "treesitter-index-artifacts"),
      common.normalize_path(base .. PATHSEP .. "treesitter-query-artifacts"),
    },
  })
  local result = artifact_session:initialize()
  log_quiet("Tree-sitter artifacts: initialized %s removed_sessions=%d removed_legacy=%d failures=%d",
    tostring(artifact_session.root), tonumber(result.removed_sessions or 0),
    tonumber(result.removed_legacy or 0), tonumber(result.failures or 0))
  return artifact_session
end

local function default_index_artifact_dir()
  return current_artifact_session():index_dir()
end

local query_artifact_sequence = 0

default_query_artifact_dir = function()
  return current_artifact_session():query_dir()
end

local function write_query_artifact(kind, payload, opts)
  opts = opts or {}
  local dir = opts.query_artifact_dir or default_query_artifact_dir()
  local ok, err = common.mkdirp(dir)
  if not ok and err ~= "path exists" then return nil, err or "mkdir-failed" end
  query_artifact_sequence = query_artifact_sequence + 1
  local path = common.normalize_path(dir .. PATHSEP .. string.format(
    "treesitter-%s-query-%s-%06d.bin",
    tostring(kind or "query"),
    tostring(system and system.get_process_id and system.get_process_id() or 0),
    query_artifact_sequence
  ))
  local fp, open_err = io.open(path, "wb")
  if not fp then return nil, open_err or "open-failed" end
  local content = artifact_codec.encode(payload)
  local wrote, write_err = fp:write(content)
  local closed, close_err = fp:close()
  if not wrote or not closed then
    os.remove(path)
    return nil, write_err or close_err or "write-failed"
  end
  return { path = path, bytes = #content }
end

local function cleanup_query_artifact(artifact)
  if not artifact then return end
  if artifact.path then pcall(os.remove, artifact.path) end
  for _, chunk in ipairs(artifact.chunks or {}) do cleanup_query_artifact(chunk) end
end

cleanup_index_query_artifacts = function(index)
  if not index then return end
  for _, artifact in pairs(index.query_artifacts or {}) do
    if type(artifact) == "table" then cleanup_query_artifact(artifact) end
  end
  index.query_artifacts = {}
end

invalidate_index_query_artifacts = function(index)
  cleanup_index_query_artifacts(index)
end

local function persistent_query_artifact_path_exists(artifact)
  if not artifact then return false end
  if artifact.chunks then
    if #artifact.chunks == 0 then return false end
    for _, chunk in ipairs(artifact.chunks) do
      if not persistent_query_artifact_path_exists(chunk) then return false end
    end
    return true
  end
  return artifact.path and system.get_file_info(artifact.path) ~= nil
end

local function combined_chunk_artifact(chunks, count, bytes)
  if #chunks == 1 then
    chunks[1].count = count
    return chunks[1]
  end
  return { chunks = chunks, count = count, bytes = bytes, chunked = true }
end

local function write_chunked_query_artifact(kind, field, items, map_item, opts)
  opts = opts or {}
  local chunk_records = math.max(1, math.floor(tonumber(opts.query_artifact_chunk_records or DEFAULT_AGGREGATE_CHUNK_RECORDS) or DEFAULT_AGGREGATE_CHUNK_RECORDS))
  local chunks = {}
  local chunk = {}
  local count = 0
  local bytes = 0

  local function cleanup_chunks()
    for _, artifact in ipairs(chunks) do cleanup_query_artifact(artifact) end
  end

  local function flush(force)
    if #chunk == 0 and not force then return true end
    local artifact, err = write_query_artifact(kind, { [field] = chunk }, opts)
    if not artifact then
      cleanup_chunks()
      return nil, err
    end
    chunks[#chunks + 1] = artifact
    bytes = bytes + (tonumber(artifact.bytes or 0) or 0)
    chunk = {}
    return true
  end

  for _, item in ipairs(items or {}) do
    local mapped = map_item and map_item(item) or item
    if mapped then
      chunk[#chunk + 1] = mapped
      count = count + 1
      if #chunk >= chunk_records then
        local ok, err = flush(false)
        if not ok then return nil, err end
      end
    end
  end

  local ok, err = flush(count == 0)
  if not ok then return nil, err end
  return combined_chunk_artifact(chunks, count, bytes)
end

local function write_chunked_usages_by_name_query_artifact(kind, usages_by_name, map_usage, opts)
  opts = opts or {}
  local chunk_records = math.max(1, math.floor(tonumber(opts.query_artifact_chunk_records or DEFAULT_AGGREGATE_CHUNK_RECORDS) or DEFAULT_AGGREGATE_CHUNK_RECORDS))
  local chunks = {}
  local current = {}
  local records = 0
  local count = 0
  local bytes = 0

  local function cleanup_chunks()
    for _, artifact in ipairs(chunks) do cleanup_query_artifact(artifact) end
  end

  local function flush(force)
    if records == 0 and not force then return true end
    local artifact, err = write_query_artifact(kind, { usages_by_name = current }, opts)
    if not artifact then
      cleanup_chunks()
      return nil, err
    end
    chunks[#chunks + 1] = artifact
    bytes = bytes + (tonumber(artifact.bytes or 0) or 0)
    current = {}
    records = 0
    return true
  end

  local names = {}
  for name in pairs(usages_by_name or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    for _, usage in ipairs(usages_by_name[name] or {}) do
      local mapped = map_usage and map_usage(name, usage) or usage
      if mapped then
        local out = current[name]
        if not out then
          out = {}
          current[name] = out
        end
        out[#out + 1] = mapped
        records = records + 1
        count = count + 1
        if records >= chunk_records then
          local ok, err = flush(false)
          if not ok then return nil, err end
        end
      end
    end
  end

  local ok, err = flush(count == 0)
  if not ok then return nil, err end
  return combined_chunk_artifact(chunks, count, bytes)
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
    chunk_bytes = opts.chunk_bytes or DEFAULT_WORKER_CHUNK_BYTES,
    max_usage_captures_per_file = opts.max_usage_captures_per_file or DEFAULT_MAX_CAPTURES,
    artifact_chunks = opts.artifact_chunks ~= false,
    artifact_dir = opts.artifact_dir or default_index_artifact_dir(),
  }
end

local function submit_sharded_scan(index, generation, opts, phase)
  opts = opts or {}
  phase = phase or "combined"
  cancel_index_work(index)
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
    aggregate_artifacts = {},
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
          local artifact = message.payload and message.payload.artifact
          if artifact and artifact.path then run.aggregate_artifacts[#run.aggregate_artifacts + 1] = artifact end
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
  phase = phase or "combined"
  submit_sharded_scan(index, generation, opts, phase)
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
    -- roots can take minutes to reindex; treating a query as a refresh trigger
    -- invalidates the usable ready aggregate and makes fuzzy/reference pickers
    -- show "indexing"/"aggregate-dirty" instead of searching the existing index.
    refresh_after_seconds = opts.refresh_after_seconds ~= nil and opts.refresh_after_seconds or 0,
    batch_files = opts.batch_files,
    batch_bytes = opts.batch_bytes,
    max_running_index_shards = opts.max_running_index_shards,
    shard_usage_budget = opts.shard_usage_budget,
    chunk_files = opts.chunk_files,
    chunk_records = opts.chunk_records,
    chunk_bytes = opts.chunk_bytes,
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

local function filtered_symbols(symbols, query, limit)
  symbols = symbols or {}
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
    local root_status = "pending"
    if index.symbol_status == "ready" then
      refresh_current_core_docs_for_index(index)
      if has_pending_open_doc_overlay(index) then
        reason = reason or "overlay-indexing"
      elseif index.aggregate_dirty then
        reason = reason or "aggregate-dirty"
      elseif query_text ~= "" and #(index.symbols or {}) > sync_limit and not opts.allow_large_sync_query then
        reason = reason or "query-too-large"
      else
        local suppressed = overlay_paths(index)
        local kind = opts.kind or "symbols"
        local source
        if kind == "symbols" and next(suppressed) == nil then
          source = index.symbols or {}
        else
          if query_text ~= "" and #(index.symbols or {}) > sync_limit and not opts.allow_large_sync_query then
            reason = reason or "query-too-large"
          else
            source = combined_symbols(index, kind)
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
    elseif (#(index.symbols or {}) > 0 or next(index.open_docs or {}) ~= nil) and opts.allow_stale then
      if index.aggregate_dirty then
        reason = reason or "aggregate-dirty"
      elseif query_text ~= "" and #(index.symbols or {}) > sync_limit and not opts.allow_large_sync_query then
        reason = reason or "query-too-large"
      else
        local source = combined_symbols(index, opts.kind or "symbols")
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
      reason = reason or (index.aggregate_dirty and "aggregate-dirty" or "indexing")
    end
    status = merge_status(status, root_status)
    per_root[#per_root + 1] = { root = root, status = root_status, index = index }
  end

  if any_usable and status ~= "fresh" and not opts.allow_stale then
    return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  end
  if any_usable then
    if #per_root > 1 then sort_symbols(all_symbols) end
    local results
    results, has_more = filtered_symbols(all_symbols, query, opts.limit)
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
      if index.aggregate_dirty then
        reason = reason or "aggregate-dirty"
      elseif has_pending_open_doc_overlay(index) then
        reason = reason or "overlay-indexing"
      elseif #(index.symbols or {}) >= max_snapshot_symbols then
        return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
      else
        local source = combined_symbols(index, opts.kind or "symbols")
        for _, symbol in ipairs(source) do
        if #all_symbols >= max_snapshot_symbols then
          return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
        end
          all_symbols[#all_symbols + 1] = symbol
        end
        root_status = "fresh"
        any_usable = true
      end
    elseif (#(index.symbols or {}) > 0 or next(index.open_docs or {}) ~= nil) and opts.allow_stale then
      if index.aggregate_dirty then
        reason = reason or "aggregate-dirty"
      elseif #(index.symbols or {}) >= max_snapshot_symbols then
        return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
      else
        for _, symbol in ipairs(combined_symbols(index, opts.kind or "symbols")) do
        if #all_symbols >= max_snapshot_symbols then
          return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
        end
          all_symbols[#all_symbols + 1] = symbol
        end
        root_status = "stale"
        reason = reason or "indexing"
        any_usable = true
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

  if not any_usable then
    return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  end
  if status ~= "fresh" and not opts.allow_stale then
    return nil, reason or "indexing", "pending", { roots = per_root, index = #per_root == 1 and per_root[1].index or nil }
  end
  if #per_root > 1 then sort_symbols(all_symbols) end
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
  local key, project_paths_generation = symbol_query_artifact_key(index, kind)
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

  local started = now()
  local artifact, err = write_chunked_query_artifact("symbols-index", "symbols", index.symbols or {}, function(symbol)
    if not project_path_allows(symbol.path, kind) then return nil end
    local item = refresh_project_path_metadata(index, copy_item(symbol), kind)
    item.search_text = tostring(item.text or item.name or "")
    return item
  end, opts)
  if not artifact then return nil, err or "artifact-write-failed" end
  artifact.generation = index.generation
  artifact.project_paths_generation = project_paths_generation
  artifact.kind = kind
  artifact.count = artifact.count or 0
  index.query_artifacts[key] = artifact
  local count = tonumber(artifact.count or 0) or 0
  local duration = elapsed_ms(started)
  inc_ui_metric(index, "persistent_symbol_query_artifact_builds", 1)
  add_ui_metric(index, "persistent_symbol_query_artifact_items", count)
  add_ui_metric(index, "persistent_symbol_query_artifact_ms", duration)
  max_ui_metric(index, "persistent_symbol_query_artifact_max_ms", duration)
  if #(index.symbols or {}) > DEFAULT_ASYNC_SYMBOL_SNAPSHOT_LIMIT then
    local chunk_count = artifact.chunks and #artifact.chunks or 1
    log_quiet("Tree-sitter Project symbol query: built missing large symbol query artifact for %s items=%d chunks=%d in %.1fms", tostring(index.root), count, chunk_count, duration)
  end
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

  local source = (index.usages_by_name or {})[name] or {}
  if #source > DEFAULT_ASYNC_USAGE_SNAPSHOT_LIMIT then
    local all_key, all_project_paths_generation = usage_query_artifact_key(index)
    local all_cached = index.query_artifacts and index.query_artifacts[all_key]
    if all_cached
    and all_cached.generation == index.generation
    and all_cached.project_paths_generation == all_project_paths_generation
    and all_cached.all_usages
    and persistent_query_artifact_path_exists(all_cached)
    then
      inc_ui_metric(index, "persistent_usage_query_artifact_hits", 1)
      return all_cached
    end

    local started = now()
    local all_artifact, all_err = write_chunked_usages_by_name_query_artifact("usages-index", index.usages_by_name or {}, function(_, usage)
      if project_paths_module().is_excluded(usage.path, "usages") then return nil end
      return refresh_project_path_metadata(index, copy_item(usage), "usages")
    end, opts)
    if not all_artifact then return nil, all_err or "artifact-write-failed" end
    all_artifact.generation = index.generation
    all_artifact.project_paths_generation = all_project_paths_generation
    all_artifact.all_usages = true
    index.query_artifacts[all_key] = all_artifact
    local count = tonumber(all_artifact.count or 0) or 0
    local duration = elapsed_ms(started)
    inc_ui_metric(index, "persistent_usage_query_artifact_builds", 1)
    add_ui_metric(index, "persistent_usage_query_artifact_items", count)
    add_ui_metric(index, "persistent_usage_query_artifact_ms", duration)
    max_ui_metric(index, "persistent_usage_query_artifact_max_ms", duration)
    local chunk_count = all_artifact.chunks and #all_artifact.chunks or 1
    log_quiet("Tree-sitter Project usage query: built missing large usage query artifact for %s items=%d chunks=%d in %.1fms", tostring(index.root), count, chunk_count, duration)
    return all_artifact
  end

  local started = now()
  local artifact, err = write_chunked_query_artifact("usages-index", "usages", source, function(usage)
    if project_paths_module().is_excluded(usage.path, "usages") then return nil end
    return refresh_project_path_metadata(index, copy_item(usage), "usages")
  end, opts)
  if not artifact then return nil, err or "artifact-write-failed" end
  artifact.generation = index.generation
  artifact.project_paths_generation = project_paths_generation
  artifact.name = name
  artifact.count = artifact.count or 0
  index.query_artifacts[key] = artifact
  local count = tonumber(artifact.count or 0) or 0
  local duration = elapsed_ms(started)
  inc_ui_metric(index, "persistent_usage_query_artifact_builds", 1)
  add_ui_metric(index, "persistent_usage_query_artifact_items", count)
  add_ui_metric(index, "persistent_usage_query_artifact_ms", duration)
  max_ui_metric(index, "persistent_usage_query_artifact_max_ms", duration)
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
      if has_pending_open_doc_overlay(index) then
        reason = reason or "overlay-indexing"
      else
        local suppressed = overlay_paths(index)
        for path in pairs(suppressed) do artifact_payload.suppressed_paths[#artifact_payload.suppressed_paths + 1] = path end
        local ok, overlay_err = append_overlay_symbols(index, opts.kind or "symbols", artifact_payload.extra_symbols, max_overlay)
        if not ok then return nil, overlay_err, "unavailable", { roots = per_root, index = index } end
        local artifact, artifact_err = persistent_symbol_query_artifact(index, opts.kind or "symbols", opts)
        if not artifact then
          local artifact_status = artifact_err == "query-artifact-not-ready" and "pending" or "unavailable"
          return nil, artifact_err or "artifact-unavailable", artifact_status, { roots = per_root, index = index }
        end
        artifact_payload.index_artifacts[#artifact_payload.index_artifacts + 1] = artifact
        root_status = "fresh"
        any_usable = true
      end
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
    name = name,
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
      if has_pending_open_doc_overlay(index) then
        reason = reason or "overlay-indexing"
      else
        local suppressed = overlay_paths(index)
        for path in pairs(suppressed) do artifact_payload.suppressed_paths[#artifact_payload.suppressed_paths + 1] = path end
        local ok, overlay_err = append_overlay_usages(index, name, artifact_payload.extra_usages, max_overlay)
        if not ok then return nil, overlay_err, "unavailable", { roots = per_root, index = index } end
        local artifact, artifact_err = persistent_usage_query_artifact(index, name, opts)
        if not artifact then
          local artifact_status = artifact_err == "query-artifact-not-ready" and "pending" or "unavailable"
          return nil, artifact_err or "artifact-unavailable", artifact_status, { roots = per_root, index = index }
        end
        artifact_payload.index_artifacts[#artifact_payload.index_artifacts + 1] = artifact
        root_status = "fresh"
        any_usable = true
      end
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

local function refresh_async_result_metadata(meta, item, kind)
  if not (meta and item and item.path) then return item end
  for _, root_meta in ipairs(meta.roots or {}) do
    local index = root_meta.index
    if index and common.path_belongs_to(item.path, index.root) then
      return refresh_project_path_metadata(index, item, kind)
    end
  end
  if meta.index then return refresh_project_path_metadata(meta.index, item, kind) end
  return item
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
    priority = "interactive",
    payload = artifact and { artifact = artifact } or query_payload,
    on_result = function(message)
      if message.type ~= "result" then return end
      local p = message.payload or {}
      request.results = p.symbols or {}
      for i, symbol in ipairs(request.results) do
        request.results[i] = public_symbol(refresh_async_result_metadata(meta, symbol, opts.kind or "symbols"))
      end
      request.has_more = p.has_more and true or false
      request.diagnostics = p.diagnostics
    end,
    on_complete = function()
      cleanup_query_artifact(request.query_artifact)
      request.query_artifact = nil
      local stale_reason = async_snapshot_stale_reason(meta)
      local load_errors = request.diagnostics and tonumber(request.diagnostics.artifact_load_errors or 0) or 0
      if load_errors > 0 then
        request.status = "unavailable"
        request.reason = request.diagnostics.last_artifact_load_error or "artifact-load-failed"
        request.results = nil
      elseif not stale_reason then
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
      if index.aggregate_dirty then
        reason = reason or "aggregate-dirty"
      elseif has_pending_open_doc_overlay(index) then
        reason = reason or "overlay-indexing"
      elseif #((index.usages_by_name or {})[name] or {}) >= max_snapshot_usages then
        return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
      else
        local source = combined_usages_for_name(index, name)
        for _, usage in ipairs(source) do
          if #all_usages >= max_snapshot_usages then
            return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
          end
          all_usages[#all_usages + 1] = public_usage(name, usage)
        end
        root_status = "fresh"
        any_usable = true
      end
    elseif opts.allow_stale and ((index.usages_by_name or {})[name] or next(index.open_docs or {}) ~= nil) then
      if index.aggregate_dirty then
        reason = reason or "aggregate-dirty"
      elseif #((index.usages_by_name or {})[name] or {}) >= max_snapshot_usages then
        return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
      else
        for _, usage in ipairs(combined_usages_for_name(index, name)) do
          if #all_usages >= max_snapshot_usages then
            return nil, "snapshot-too-large", "unavailable", { roots = per_root, index = index }
          end
          all_usages[#all_usages + 1] = public_usage(name, usage)
        end
        root_status = "stale"
        reason = reason or "indexing"
        any_usable = true
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
    priority = "interactive",
    payload = artifact and { artifact = artifact } or query_payload,
    on_result = function(message)
      if message.type ~= "result" then return end
      local p = message.payload or {}
      request.results = p.usages or {}
      for i, usage in ipairs(request.results) do
        request.results[i] = public_usage(name, refresh_async_result_metadata(meta, usage, "usages"))
      end
      request.has_more = p.has_more and true or false
      request.diagnostics = p.diagnostics
    end,
    on_complete = function()
      cleanup_query_artifact(request.query_artifact)
      request.query_artifact = nil
      local stale_reason = async_snapshot_stale_reason(meta)
      local load_errors = request.diagnostics and tonumber(request.diagnostics.artifact_load_errors or 0) or 0
      if load_errors > 0 then
        request.status = "unavailable"
        request.reason = request.diagnostics.last_artifact_load_error or "artifact-load-failed"
        request.results = nil
      elseif not stale_reason then
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
    if index.usage_status == "ready" then
      refresh_current_core_docs_for_index(index)
      if has_pending_open_doc_overlay(index) then
        reason = reason or "overlay-indexing"
      elseif index.aggregate_dirty then
        reason = reason or "aggregate-dirty"
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
      if index.aggregate_dirty then
        reason = reason or "aggregate-dirty"
      elseif #((index.usages_by_name or {})[name] or {}) > sync_limit and not opts.allow_large_sync_query then
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
    if #per_root > 1 then sort_usages(all_usages) end
    local results
    results, has_more = filter_usages(all_usages, opts, name)
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

  local handle, err = worker_pool.system():submit({
    kind = "treesitter_project_index",
    priority = "interactive",
    generation = index.generation,
    project_paths_generation = project_paths_generation,
    phase = "open-doc-overlay",
    payload = {
      root = index.root,
      root_path = index.root,
      files = {
        {
          path = path,
          root = index.root,
          text = text,
          language_id = language.id,
          info = { type = "file", size = #text },
        },
      },
      excluded = project_index_exclusions_payload(),
      ignore_files = config.ignore_files,
      languages = project_index_languages_payload(),
      include_usages = true,
      project_usage_cap = index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP,
      max_file_bytes = MAX_FILE_BYTES,
      chunk_files = 1,
      chunk_records = DEFAULT_WORKER_CHUNK_RECORDS,
      max_usage_captures_per_file = DEFAULT_MAX_CAPTURES,
      artifact_chunks = false,
    },
    is_stale = function()
      return not current()
    end,
    on_result = function(message)
      if not current() or message.type ~= "chunk" then return end
      local file = message.payload and message.payload.files and message.payload.files[1]
      if not file then return end
      file.doc = doc
      file.change_id = change_id
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
  if status == "ready" and index.worker_targeted_paths and not index.worker_targeted_dir and not index.aggregate_dirty then
    for path in pairs(index.worker_targeted_paths) do
      local entry = index.by_path and index.by_path[path]
      local ok, err = apply_incremental_file_aggregate(index, path, entry)
      if not ok then
        mark_aggregate_dirty(index)
        log_quiet("Tree-sitter Project index: incremental aggregate update failed for %s: %s", tostring(path), tostring(err))
        break
      end
    end
  end

  local function finalize(final_status, final_message)
    index.status = final_status
    if final_status == "ready" then
      index.symbol_status = "ready"
      index.usage_status = "ready"
      index.reason = nil
    else
      index.symbol_status = final_status
      index.usage_status = final_status
      index.reason = final_message.error or (final_message.payload and final_message.payload.reason) or final_status
    end
    index.worker_handle = nil
    index.worker_seen_paths = nil
    index.worker_adopted_paths = nil
    index.worker_targeted_paths = nil
    index.worker_targeted_dir = nil
    index.worker_base_aggregate = nil
    index.worker_aggregate_artifacts = nil
    index.worker_run = nil
    index.finished_at = system.get_time()
    core.redraw = true
    if final_status == "ready" then drain_pending_reindexes(index) end
  end

  local artifacts = index.worker_aggregate_artifacts or {}
  if status == "ready" and #artifacts > 0 then
    local base = index.worker_base_aggregate or {}
    local run = {
      generation = message.generation,
      project_paths_generation = message.project_paths_generation,
      phase = message.phase,
      opts = {},
      aggregate_artifacts = artifacts,
      replacement_dir = index.worker_targeted_dir,
      base_symbol_artifact = base.symbol_artifact,
      base_usage_artifact = base.usage_artifact,
      base_usage_truncated = base.usage_truncated,
      base_usage_truncated_reason = base.usage_truncated_reason,
    }
    index.worker_run = run
    local submitted = submit_worker_aggregate(index, run, message, function(ok, aggregate_message)
      finalize(ok and "ready" or "failed", aggregate_message or message)
    end)
    if submitted then return end
    finalize("failed", message)
    return
  end

  if status == "ready" and index.aggregate_dirty then status = "failed" end
  finalize(status, message)
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
    if changed then
      remove_path_from_disk_aggregates(index, path)
      invalidate_combined_symbols_cache(index)
      invalidate_index_query_artifacts(index)
    end
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
    if changed then
      remove_path_from_disk_aggregates(index, path)
      invalidate_combined_symbols_cache(index)
      invalidate_index_query_artifacts(index)
    end
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
  index.worker_aggregate_artifacts = nil
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
      chunk_bytes = opts.chunk_bytes or DEFAULT_WORKER_CHUNK_BYTES,
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

local function current_aggregate_query_artifacts(index)
  if not index then return nil, "no-index" end
  local symbol_key = symbol_query_artifact_key(index, "symbols")
  local usage_key = usage_query_artifact_key(index)
  local symbol_artifact = index.query_artifacts and index.query_artifacts[symbol_key]
  local usage_artifact = index.query_artifacts and index.query_artifacts[usage_key]
  if not (symbol_artifact and persistent_query_artifact_path_exists(symbol_artifact)) then
    return nil, "missing-symbol-base-artifact"
  end
  if not (usage_artifact and usage_artifact.all_usages and persistent_query_artifact_path_exists(usage_artifact)) then
    return nil, "missing-usage-base-artifact"
  end
  return {
    symbol_artifact = symbol_artifact,
    usage_artifact = usage_artifact,
    usage_truncated = index.usage_truncated and true or false,
    usage_truncated_reason = index.usage_truncated_reason,
  }
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
    local removed_paths = {}
    for path in pairs(index.by_path or {}) do
      if common.path_equals(path, dir) or common.path_belongs_to(path, dir) then
        index.by_path[path] = nil
        removed_paths[#removed_paths + 1] = path
        changed = true
      end
    end
    for path in pairs(index.open_docs or {}) do
      if common.path_equals(path, dir) or common.path_belongs_to(path, dir) then
        index.open_docs[path] = nil
        changed = true
      end
    end
    if changed then
      for _, path in ipairs(removed_paths) do remove_path_from_disk_aggregates(index, path) end
      invalidate_combined_symbols_cache(index)
      invalidate_index_query_artifacts(index)
    end
    return true, info and "not-directory" or "missing"
  end

  local base_aggregate, base_reason = current_aggregate_query_artifacts(index)
  if not base_aggregate then
    log_quiet("Tree-sitter Project index: cannot merge targeted directory %s under %s: %s",
      tostring(dir), tostring(index.root), tostring(base_reason))
    return false, base_reason
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
  index.worker_base_aggregate = base_aggregate
  index.worker_aggregate_artifacts = {}
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
      chunk_bytes = opts.chunk_bytes or DEFAULT_WORKER_CHUNK_BYTES,
      max_usage_captures_per_file = opts.max_usage_captures_per_file or DEFAULT_MAX_CAPTURES,
      artifact_chunks = opts.artifact_chunks ~= false,
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
        local artifact = message.payload and message.payload.artifact
        if artifact and artifact.path then index.worker_aggregate_artifacts[#index.worker_aggregate_artifacts + 1] = artifact end
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

function symbol_index.mark_directory_dirty(dir, reason, opts)
  opts = opts or {}
  dir = dir and common.normalize_path(dir)
  if not dir then return false, "no-directory" end
  opts = common.merge(opts, { reason = reason or opts.reason or "directory-dirty" })
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
          index.status = "failed"
          index.symbol_status = "failed"
          index.usage_status = "failed"
          index.reason = submit_reason or "targeted-directory-submit-failed"
          index.finished_at = system.get_time()
          log_quiet("Tree-sitter Project index: targeted directory worker reindex for %s under %s failed: %s",
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

function symbol_index.cleanup_artifacts()
  if not artifact_session then return true end
  local ok = artifact_session:cleanup()
  log_quiet("Tree-sitter artifacts: shutdown cleanup root=%s ok=%s", tostring(artifact_session.root), tostring(ok))
  return ok
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
