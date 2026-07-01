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
local MAX_FILE_BYTES = 2 * 1024 * 1024

local native_ok, native = nil, nil
local query_cache = {}
local indexes = {}

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

local function index_for_root(root)
  root = normalize_root(root)
  local index = indexes[root]
  if not index then
    index = {
      root = root,
      generation = 0,
      status = "idle",
      symbols = {},
      by_path = {},
      files_total = 0,
      files_scanned = 0,
      files_indexed = 0,
      reason = nil,
      started_at = nil,
      finished_at = nil,
    }
    indexes[root] = index
  end
  return index
end

local function compile_outline_query(language)
  if not language or not language.query_sources or not language.query_sources.outline then
    return nil, "missing-query"
  end
  local n = ensure_native()
  if not n then return nil, "native-unavailable" end
  local key = tostring(language.grammar) .. "\0" .. tostring(language.query_sources.outline)
  if query_cache[key] ~= nil then return query_cache[key] or nil, query_cache[key] == false and "compile-failed" or nil end
  local query, err = n.compile_query(language.grammar, "outline", language.query_sources.outline)
  if not query then
    query_cache[key] = false
    log_quiet("Tree-sitter symbols: disabled outline query for %s: %s", tostring(language.id), tostring(err))
    return nil, err or "compile-failed"
  end
  query_cache[key] = query
  return query
end

local function file_fingerprint(_path, info, language)
  local outline_source = language and language.query_sources and language.query_sources.outline or ""
  return table.concat({
    tostring(info and info.size or ""),
    tostring(info and info.modified or ""),
    tostring(language and language.id or ""),
    tostring(language and language.grammar or ""),
    tostring(#outline_source),
    outline_source,
  }, "\0")
end

local function read_lines(path, info)
  local size = info and tonumber(info.size) or nil
  if size and size > MAX_FILE_BYTES then return nil, "too-large" end
  local fp, err = io.open(path, "rb")
  if not fp then return nil, err or "open-failed" end
  local text = fp:read("*a") or ""
  fp:close()
  if #text > MAX_FILE_BYTES then return nil, "too-large" end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  local pos = 1
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

local function parse_file_symbols(path, relpath, info, language)
  local n = ensure_native()
  if not n then return nil, "native-unavailable" end
  if not n.has_language or not n.has_language(language.grammar) then return nil, "missing-grammar" end
  local query, err = compile_outline_query(language)
  if not query then return nil, err or "missing-query" end
  local lines
  lines, err = read_lines(path, info)
  if not lines then return nil, err end

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
      queries = { outline = query },
      language = language,
      language_id = language.id,
      grammar = language.grammar,
      stale_unrenderable = false,
    },
    get_name = function() return relpath or path end,
    get_change_id = function() return 0 end,
  }
  local symbols = outline.get_document_outline(fake_doc) or {}
  state:close()
  for _, symbol in ipairs(symbols) do
    symbol.path = path
    symbol.file = relpath or path
    symbol.relpath = relpath or path
    symbol.language_id = language.id
    symbol.text = symbol.name
  end
  return symbols
end

local function sort_symbols(symbols)
  table.sort(symbols, function(a, b)
    local af, bf = tostring(a.relpath or a.path or ""), tostring(b.relpath or b.path or "")
    if af ~= bf then return af < bf end
    if (a.start_line or 0) ~= (b.start_line or 0) then return (a.start_line or 0) < (b.start_line or 0) end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
end

local function rebuild_symbols(index)
  local symbols = {}
  for _, entry in pairs(index.by_path or {}) do
    for _, symbol in ipairs(entry.symbols or {}) do symbols[#symbols + 1] = symbol end
  end
  sort_symbols(symbols)
  index.symbols = symbols
end

local function replace_file_symbols(index, path, fingerprint, symbols)
  index.by_path[path] = { fingerprint = fingerprint, symbols = symbols or {} }
end

local function scan_index(index, generation)
  index.status = "indexing"
  index.reason = nil
  index.started_at = system.get_time()
  index.finished_at = nil
  index.files_total = 0
  index.files_scanned = 0
  index.files_indexed = 0

  local project = Project(index.root)
  local yielded = 0
  local changed = false
  local seen_supported_paths = {}
  for _, info in project:files() do
    if generation ~= index.generation then return end
    local path = common.normalize_path(info.filename)
    if info.type == "file" then
      local language = registry.get(path)
      if language and language.query_sources and language.query_sources.outline then
        seen_supported_paths[path] = true
        index.files_total = index.files_total + 1
        local fingerprint = file_fingerprint(path, info, language)
        local cached = index.by_path[path]
        if not cached or cached.fingerprint ~= fingerprint then
          local relpath = common.relative_path(index.root, path):gsub("\\", "/")
          local symbols, err = parse_file_symbols(path, relpath, info, language)
          if symbols then
            replace_file_symbols(index, path, fingerprint, symbols)
            index.files_indexed = index.files_indexed + 1
            changed = true
          else
            replace_file_symbols(index, path, fingerprint, {})
            changed = true
            log_quiet("Tree-sitter symbols: skipped %s: %s", tostring(relpath), tostring(err))
          end
        end
      end
      index.files_scanned = index.files_scanned + 1
      yielded = yielded + 1
      if yielded >= DEFAULT_SCAN_YIELD_FILES then
        yielded = 0
        core.redraw = true
        coroutine.yield(0)
      end
    end
  end

  if generation ~= index.generation then return end
  local pruned = false
  for path in pairs(index.by_path) do
    if not seen_supported_paths[path] then
      index.by_path[path] = nil
      pruned = true
    end
  end
  if changed or pruned then rebuild_symbols(index) end
  index.status = "ready"
  index.reason = nil
  index.finished_at = system.get_time()
  core.redraw = true
  log_quiet("Tree-sitter symbols: indexed %d symbol(s) from %d supported file(s) under %s in %.1fms",
    #index.symbols, index.files_total, index.root, ((index.finished_at or system.get_time()) - (index.started_at or system.get_time())) * 1000)
end

function symbol_index.ensure_scan(root, opts)
  opts = opts or {}
  local index = index_for_root(root)
  if index.status == "indexing" and not opts.force then return index end
  if index.status == "ready" and not opts.force then
    local refresh_after = tonumber(opts.refresh_after_seconds or DEFAULT_REFRESH_AFTER_SECONDS)
    if refresh_after <= 0 or (index.finished_at and system.get_time() - index.finished_at < refresh_after) then
      return index
    end
  end
  index.generation = index.generation + 1
  index.status = "indexing"
  local generation = index.generation
  core.add_thread(function()
    scan_index(index, generation)
  end)
  return index
end

function symbol_index.invalidate(root)
  if root then
    local index = index_for_root(root)
    index.status = "idle"
    index.generation = index.generation + 1
  else
    for _, index in pairs(indexes) do
      index.status = "idle"
      index.generation = index.generation + 1
    end
  end
end

local function open_document_symbols(root)
  local out, paths = {}, {}
  root = normalize_root(root)
  for _, doc in ipairs(core.docs or {}) do
    local path = doc and (doc.abs_filename or doc.filename)
    path = path and common.normalize_path(path)
    if path and common.path_belongs_to(path, root) and doc.treesitter and doc.treesitter.status == "ready" then
      local relpath = common.relative_path(root, path):gsub("\\", "/")
      local symbols = outline.get_document_outline(doc) or {}
      if #symbols > 0 then paths[path] = true end
      for _, symbol in ipairs(symbols) do
        symbol.path = path
        symbol.file = relpath
        symbol.relpath = relpath
        symbol.language_id = doc.treesitter.language_id
        symbol.text = symbol.name
        out[#out + 1] = symbol
      end
    end
  end
  return out, paths
end

local function combined_symbols(index)
  local open_symbols, open_paths = open_document_symbols(index.root)
  if #open_symbols == 0 then return index.symbols end
  local out = {}
  for _, symbol in ipairs(index.symbols or {}) do
    if not open_paths[symbol.path] then out[#out + 1] = symbol end
  end
  for _, symbol in ipairs(open_symbols) do out[#out + 1] = symbol end
  table.sort(out, function(a, b)
    local af, bf = tostring(a.relpath or a.path or ""), tostring(b.relpath or b.path or "")
    if af ~= bf then return af < bf end
    if (a.start_line or 0) ~= (b.start_line or 0) then return (a.start_line or 0) < (b.start_line or 0) end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  return out
end

local function filtered_symbols(symbols, query, limit)
  local items = {}
  for _, symbol in ipairs(symbols or {}) do
    items[#items + 1] = symbol
  end
  query = tostring(query or "")
  if query ~= "" then items = common.fuzzy_match(items, query, false) end
  limit = tonumber(limit) or DEFAULT_QUERY_LIMIT
  local out = {}
  for i = 1, math.min(limit, #items) do out[i] = items[i] end
  return out, #items > #out
end

function symbol_index.workspace_symbols(query, opts)
  opts = opts or {}
  local index = symbol_index.ensure_scan(opts.root, {
    force = opts.force,
    refresh_after_seconds = opts.refresh_after_seconds,
  })
  if index.status == "ready" then
    local results, has_more = filtered_symbols(combined_symbols(index), query, opts.limit)
    return results, nil, "fresh", { has_more = has_more, index = index }
  end
  if (#index.symbols > 0 or #(open_document_symbols(index.root)) > 0) and opts.allow_stale then
    local results, has_more = filtered_symbols(combined_symbols(index), query, opts.limit)
    return results, "indexing", "stale", { has_more = has_more, index = index }
  end
  return nil, "indexing", "pending", { index = index }
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
  indexes = {}
  query_cache = {}
end

return symbol_index
