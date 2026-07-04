local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local registry = require "core.treesitter.registry"
local outline = require "core.treesitter.outline"

local symbol_index = {}

local DEFAULT_PARSE_TIMEOUT_MS = 1000
local DEFAULT_SCAN_YIELD_FILES = 4
local DEFAULT_QUERY_LIMIT = 200
local DEFAULT_REFRESH_AFTER_SECONDS = 5
local DEFAULT_MATCH_LIMIT = 50000
local DEFAULT_MAX_CAPTURES = 50000
local DEFAULT_QUERY_TIMEOUT_MS = 20
local DEFAULT_PROJECT_USAGE_CAP = 750000
local MAX_FILE_BYTES = 2 * 1024 * 1024

local native_ok, native = nil, nil
local query_cache = {}
local indexes = {}
local open_documents = setmetatable({}, { __mode = "v" })

local function log_quiet(...)
  if core and core.log_quiet then core.log_quiet(...) end
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
    files_total = 0,
    files_scanned = 0,
    files_indexed = 0,
    reason = nil,
    started_at = nil,
    finished_at = nil,
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
    coroutine.yield(0.01)
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

local function usage_from_capture(path, relpath, lines, language, capture)
  local text = text_for_capture(lines, capture)
  if text == "" then return nil end
  local definition_kind = capture_kind(capture.capture)
  local line = lines[capture.start_line] or ""
  return {
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
  }
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

local function rebuild_disk_aggregates(index)
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

local function drain_pending_reindexes(index)
  if not index or index.status == "indexing" then return false end
  local drained = false
  local pending_dirs = index.pending_reindex_dirs
  if pending_dirs and next(pending_dirs) ~= nil then
    index.pending_reindex_dirs = {}
    drained = true
    for dir, reason in pairs(pending_dirs) do
      if symbol_index.mark_directory_dirty then
        symbol_index.mark_directory_dirty(dir, reason or "queued-during-indexing")
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

local function scan_index(index, generation)
  index.status = "indexing"
  index.symbol_status = "indexing"
  index.usage_status = "indexing"
  index.reason = nil
  index.started_at = system.get_time()
  index.finished_at = nil
  index.files_total = 0
  index.files_scanned = 0
  index.files_indexed = 0

  local project = Project(index.root)
  local supported_files = {}
  local seen_supported_paths = {}
  local yielded = 0
  for _, info in project:files() do
    if generation ~= index.generation then return end
    if info.type == "file" then
      local path = common.normalize_path(info.filename)
      local language = registry.get(path)
      if language and language.query_sources and language.query_sources.outline then
        local relpath = common.relative_path(index.root, path):gsub("\\", "/")
        local fingerprint = file_fingerprint(path, info, language)
        supported_files[#supported_files + 1] = {
          path = path,
          relpath = relpath,
          info = info,
          language = language,
          fingerprint = fingerprint,
        }
        seen_supported_paths[path] = true
      end
      index.files_scanned = index.files_scanned + 1
      yielded = yielded + 1
      if yielded >= DEFAULT_SCAN_YIELD_FILES * 8 then
        yielded = 0
        core.redraw = true
        coroutine.yield(0)
      end
    end
  end
  index.files_total = #supported_files

  if generation ~= index.generation then return end
  local changed = false
  local batch_changed = false
  local pruned = false
  for path in pairs(index.by_path) do
    if not seen_supported_paths[path] then
      index.by_path[path] = nil
      pruned = true
    end
  end

  yielded = 0
  for _, file in ipairs(supported_files) do
    if generation ~= index.generation then return end
    local cached = index.by_path[file.path]
    if not cached or cached.fingerprint ~= file.fingerprint then
      local entry, err = parse_file_index(file.path, file.relpath, file.info, file.language, { include_usages = false })
      if entry then
        replace_file_entry(index, file.path, file.fingerprint, entry)
        index.files_indexed = index.files_indexed + 1
        changed = true
        batch_changed = true
      else
        replace_file_entry(index, file.path, file.fingerprint, { symbols = {}, usages_by_name = {}, usage_count = 0, usage_complete = false })
        changed = true
        batch_changed = true
        log_quiet("Tree-sitter Project symbols: skipped %s: %s", tostring(file.relpath), tostring(err))
      end
    end
    yielded = yielded + 1
    if yielded >= DEFAULT_SCAN_YIELD_FILES then
      yielded = 0
      if batch_changed then
        rebuild_disk_aggregates(index)
        batch_changed = false
      end
      core.redraw = true
      coroutine.yield(0)
    end
  end

  if generation ~= index.generation then return end
  if changed or pruned or index.symbol_status ~= "ready" then rebuild_disk_aggregates(index) end
  index.symbol_status = "ready"
  core.redraw = true
  log_quiet("Tree-sitter Project symbols: ready with %d symbol(s) from %d supported file(s) under %s",
    #index.symbols, index.files_total, index.root)
  coroutine.yield(0)

  local usage_seen = 0
  local usage_cap = tonumber(index.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP) or DEFAULT_PROJECT_USAGE_CAP
  batch_changed = false
  yielded = 0
  for _, file in ipairs(supported_files) do
    if generation ~= index.generation then return end
    local cached = index.by_path[file.path]
    local cached_complete_enough = cached and cached.fingerprint == file.fingerprint
      and (cached.usage_complete ~= false or usage_seen >= usage_cap)
    if cached_complete_enough then
      usage_seen = usage_seen + (cached.usage_count or count_usages(cached.usages_by_name))
    else
      local include_usages = usage_seen < usage_cap
      local entry, err = parse_file_index(file.path, file.relpath, file.info, file.language, { include_usages = include_usages })
      if entry then
        replace_file_entry(index, file.path, file.fingerprint, entry)
        usage_seen = usage_seen + (entry.usage_count or 0)
        changed = true
        batch_changed = true
      else
        replace_file_entry(index, file.path, file.fingerprint, { symbols = cached and cached.symbols or {}, usages_by_name = {}, usage_count = 0, usage_complete = false })
        changed = true
        batch_changed = true
        log_quiet("Tree-sitter Project usages: skipped %s: %s", tostring(file.relpath), tostring(err))
      end
    end
    yielded = yielded + 1
    if yielded >= DEFAULT_SCAN_YIELD_FILES then
      yielded = 0
      if batch_changed then
        rebuild_disk_aggregates(index)
        batch_changed = false
      end
      core.redraw = true
      coroutine.yield(0)
    end
  end

  if generation ~= index.generation then return end
  if changed or pruned or index.status ~= "ready" then rebuild_disk_aggregates(index) end
  index.status = "ready"
  index.usage_status = "ready"
  index.reason = nil
  index.finished_at = system.get_time()
  core.redraw = true
  log_quiet("Tree-sitter Project index: indexed %d symbol(s), %d usage(s)%s from %d supported file(s) under %s in %.1fms",
    #index.symbols, index.usage_count or 0, index.usage_truncated and " (truncated)" or "",
    index.files_total, index.root, ((index.finished_at or system.get_time()) - (index.started_at or system.get_time())) * 1000)

  drain_pending_reindexes(index)
end

function symbol_index.ensure_scan(root, opts)
  opts = opts or {}
  local index = index_for_root(root)
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
  index.status = "indexing"
  index.symbol_status = "indexing"
  index.usage_status = "indexing"
  local generation = index.generation
  core.add_thread(function()
    scan_index(index, generation)
  end)
  return index
end

function symbol_index.start_project_indexing(opts)
  opts = opts or {}
  local roots = {}
  if opts.root or opts.project then
    roots[1] = normalize_root(opts.root or opts.project)
  else
    for _, project in ipairs(core.projects or {}) do
      if project and project.path then roots[#roots + 1] = normalize_root(project.path) end
    end
  end
  for _, root in ipairs(roots) do
    local index = symbol_index.ensure_scan(root, {
      force = opts.force,
      refresh_after_seconds = opts.refresh_after_seconds,
    })
    log_quiet("Tree-sitter Project index: scheduled %s indexing for %s status=%s", tostring(opts.reason or "project"), tostring(root), tostring(index.status))
  end
end

function symbol_index.invalidate(root)
  if root then
    local normalized = normalize_root(root)
    local index = index_for_root(normalized)
    index.status = "idle"
    index.symbol_status = "idle"
    index.usage_status = "idle"
    index.generation = index.generation + 1
  else
    for _, index in pairs(indexes) do
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
  return paths
end

overlay_entry_current = function(entry)
  if not entry or not entry.doc then return false end
  local doc = entry.doc
  local ts = doc.treesitter
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  return ts and ts.status == "ready" and entry.change_id == change_id
end

local function combined_symbols(index)
  if refresh_open_document_overlays then refresh_open_document_overlays(index) end
  local overlay = index.open_docs or {}
  local paths = overlay_paths(index)
  local out = {}
  for _, symbol in ipairs(index.symbols or {}) do
    if not paths[symbol.path] then out[#out + 1] = symbol end
  end
  for _, entry in pairs(overlay) do
    if overlay_entry_current(entry) then
      for _, symbol in ipairs(entry.symbols or {}) do out[#out + 1] = symbol end
    end
  end
  sort_symbols(out)
  return out
end

local function combined_usages_for_name(index, name)
  if refresh_open_document_overlays then refresh_open_document_overlays(index) end
  local overlay = index.open_docs or {}
  local paths = overlay_paths(index)
  local out = {}
  for _, usage in ipairs((index.usages_by_name or {})[name] or {}) do
    if not paths[usage.path] then out[#out + 1] = usage end
  end
  for _, entry in pairs(overlay) do
    if overlay_entry_current(entry) then
      for _, usage in ipairs((entry.usages_by_name or {})[name] or {}) do out[#out + 1] = usage end
    end
  end
  sort_usages(out)
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

function symbol_index.workspace_symbols(query, opts)
  opts = opts or {}
  local index = symbol_index.ensure_scan(opts.root, {
    force = opts.force,
    refresh_after_seconds = opts.refresh_after_seconds,
  })
  if index.symbol_status == "ready" then
    refresh_current_core_docs_for_index(index)
    local results, has_more = filtered_symbols(combined_symbols(index), query, opts.limit)
    return results, nil, "fresh", { has_more = has_more, index = index }
  end
  if (#(index.symbols or {}) > 0 or next(index.open_docs or {}) ~= nil) and opts.allow_stale then
    local results, has_more = filtered_symbols(combined_symbols(index), query, opts.limit)
    return results, "indexing", "stale", { has_more = has_more, index = index }
  end
  return nil, "indexing", "pending", { index = index }
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

function symbol_index.workspace_usages(name, opts)
  opts = opts or {}
  name = tostring(name or "")
  if name == "" then return {}, "no-symbol", "fresh", { has_more = false } end
  local index = symbol_index.ensure_scan(opts.root, {
    force = opts.force,
    refresh_after_seconds = opts.refresh_after_seconds,
  })
  if index.usage_status == "ready" then
    refresh_current_core_docs_for_index(index)
    local results, has_more = filter_usages(combined_usages_for_name(index, name), opts)
    has_more = has_more or index.usage_truncated or false
    return results, nil, "fresh", {
      has_more = has_more,
      index = index,
      usage_truncated = index.usage_truncated,
      usage_truncated_reason = index.usage_truncated_reason,
    }
  end
  if opts.allow_stale and ((index.usages_by_name or {})[name] or next(index.open_docs or {}) ~= nil) then
    local results, has_more = filter_usages(combined_usages_for_name(index, name), opts)
    return results, "indexing", "stale", { has_more = has_more, index = index }
  end
  return nil, "indexing", "pending", { index = index }
end

function symbol_index.workspace_references(name, opts)
  return symbol_index.workspace_usages(name, opts)
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
        else
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
    for overlay_path, entry in pairs(index.open_docs or {}) do
      if (path and overlay_path == path) or entry.doc == doc then
        index.open_docs[overlay_path] = nil
        cleared = true
      end
    end
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

  local names, err = system.list_dir(dir)
  if not names then return false, err or "list-failed" end

  local present_direct_files = {}
  for _, name in ipairs(names) do
    local path = common.normalize_path(dir .. PATHSEP .. name)
    local child = system.get_file_info(path)
    if child and child.type == "file" then
      present_direct_files[path] = true
      local child_changed = reindex_file_for_index(index, path, common.merge(opts, { force = true }))
      changed = child_changed or changed
    end
  end

  for path in pairs(index.by_path or {}) do
    if common.dirname(path) == dir and not present_direct_files[path] then
      index.by_path[path] = nil
      index.open_docs[path] = nil
      changed = true
    end
  end

  if changed then rebuild_disk_aggregates(index) end
  return changed
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
  core.add_thread(function()
    run_reindex_file(path, opts)
  end)
  return true
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
        index.pending_reindex_dirs[dir] = opts.reason or "directory-dirty"
        index.symbol_status = "indexing"
        index.usage_status = "indexing"
        log_quiet("Tree-sitter Project index: queued directory reindex for %s under %s while indexing (%s)",
          tostring(dir), tostring(index.root), tostring(index.pending_reindex_dirs[dir]))
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
  core.add_thread(function()
    run_reindex_directory(dir, opts)
  end)
  return true
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
    index.generation = (index.generation or 0) + 1
  end
  indexes = {}
  open_documents = setmetatable({}, { __mode = "v" })
  query_cache = {}
end

return symbol_index
