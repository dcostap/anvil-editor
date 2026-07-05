-- Worker-side Tree-sitter project indexing job.
--
-- Input is plain serializable data prepared by the UI side. This worker does
-- filesystem walking, file reads, native parse/query through treesitter.index_text,
-- and compact record construction off the UI thread.

local common = require "core.common"
local records = require "core.treesitter.project_index_records"
local native = require "treesitter"

local worker = {}

local DEFAULT_PARSE_TIMEOUT_MS = 1000
local DEFAULT_MATCH_LIMIT = 50000
local DEFAULT_MAX_CAPTURES = 50000
local DEFAULT_QUERY_TIMEOUT_MS = 20
local DEFAULT_MAX_FILE_BYTES = 2 * 1024 * 1024
local DEFAULT_PROGRESS_INTERVAL = 0.25
local DEFAULT_CHUNK_FILES = 16
local DEFAULT_CHUNK_RECORDS = 5000
local DEFAULT_PROJECT_USAGE_CAP = 750000

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function join_path(dir, name)
  if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then return dir .. name end
  return dir .. PATHSEP .. name
end

local function normalize(path)
  return common.normalize_path(path)
end

local function read_file_text(path, max_bytes)
  local info = system.get_file_info(path)
  if not info or info.type ~= "file" then return nil, "not-file", info end
  local size = tonumber(info.size) or 0
  if size > max_bytes then return nil, "too-large", info end
  local fp, err = io.open(path, "rb")
  if not fp then return nil, err or "open-failed", info end
  local text = fp:read("*a") or ""
  fp:close()
  if #text > max_bytes then return nil, "too-large", info end
  return text:gsub("\r\n", "\n"):gsub("\r", "\n"), nil, info
end

local function match_language(path, languages)
  local best_match = 0
  local best_language
  for i = #(languages or {}), 1, -1 do
    local language = languages[i]
    local s, e = common.match_pattern(path, language.files or {})
    if s and e - s > best_match then
      best_match = e - s
      best_language = language
    end
  end
  return best_language
end

local function query_kind(language)
  local sources = language and language.query_sources or {}
  if sources.usages then return "usages" end
  if sources.locals then return "locals" end
end

local function option(language, prefix, name, fallback)
  local value = language and language[prefix .. "_" .. name]
  if value == nil and prefix == "usages" then value = language and language["locals_" .. name] end
  return value or fallback
end

local function make_fingerprint(info, language)
  local sources = language and language.query_sources or {}
  local usage_kind = query_kind(language) or ""
  local usage_source = usage_kind ~= "" and sources[usage_kind] or ""
  local outline_source = sources.outline or ""
  return table.concat({
    tostring(info and info.size or ""),
    tostring(info and info.modified or ""),
    tostring(language and language.id or ""),
    tostring(language and language.grammar or ""),
    tostring(language and language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS),
    tostring(option(language, "outline", "match_limit", DEFAULT_MATCH_LIMIT)),
    tostring(option(language, "outline", "max_captures", DEFAULT_MAX_CAPTURES)),
    tostring(option(language, "outline", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS)),
    tostring(#outline_source),
    outline_source,
    tostring(usage_kind),
    tostring(option(language, "usages", "match_limit", DEFAULT_MATCH_LIMIT)),
    tostring(option(language, "usages", "max_captures", DEFAULT_MAX_CAPTURES)),
    tostring(option(language, "usages", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS)),
    tostring(#usage_source),
    usage_source,
  }, "\0")
end

local function excluded(path, rules)
  for _, rule in ipairs(rules or {}) do
    local rule_path = rule.path or rule[1]
    if rule_path and (common.path_equals(path, rule_path) or common.path_belongs_to(path, rule_path)) then return true end
  end
  return false
end

local function ignored_name(name, ignore_files)
  if not ignore_files then return false end
  return common.match_pattern(name, ignore_files) and true or false
end

local function should_descend(path, info, payload)
  if not info or info.type ~= "dir" then return false end
  if excluded(path, payload.excluded) then return false end
  if ignored_name(common.basename(path), payload.ignore_files) then return false end
  return true
end

local function elapsed_ms(started)
  return (now() - started) * 1000
end

local function add_metric(metrics, key, value)
  if not metrics then return end
  metrics[key] = (metrics[key] or 0) + (tonumber(value) or 0)
end

local function inc_metric(metrics, key, amount)
  if not metrics then return end
  metrics[key] = (metrics[key] or 0) + (amount or 1)
end

local function max_metric(metrics, key, value)
  if not metrics then return end
  value = tonumber(value) or 0
  if value > (metrics[key] or 0) then metrics[key] = value end
end

local function copy_native_metrics(metrics, result, prefix)
  local native_metrics = result and result.metrics or {}
  if native_metrics.parse_ms then add_metric(metrics, "parse_ms", native_metrics.parse_ms) end
  if native_metrics.outline_query_ms then add_metric(metrics, "outline_query_ms", native_metrics.outline_query_ms) end
  if native_metrics.usage_query_ms then add_metric(metrics, "usage_query_ms", native_metrics.usage_query_ms) end
  if native_metrics.parse_count then inc_metric(metrics, "parse_calls", native_metrics.parse_count) end
  local captures = result and result[prefix] and result[prefix].capture_count
  if captures then inc_metric(metrics, prefix .. "_captures", captures) end
end

local function file_record_count(file)
  return #(file.symbols or {}) + (file.usage_count or 0)
end

local function push_file(chunk, file)
  chunk[#chunk + 1] = file
  chunk.record_count = (chunk.record_count or 0) + file_record_count(file)
end

local function flush_chunk(ctx, payload, root, state, chunk, force)
  if #chunk == 0 then return true end
  if not force
    and #chunk < (payload.chunk_files or DEFAULT_CHUNK_FILES)
    and (chunk.record_count or 0) < (payload.chunk_records or DEFAULT_CHUNK_RECORDS)
  then
    return true
  end
  local files = {}
  local file_count = #chunk
  local record_count = chunk.record_count or 0
  for i = 1, #chunk do
    files[i] = chunk[i]
    chunk[i] = nil
  end
  chunk.record_count = 0
  local metrics = state and state.metrics
  inc_metric(metrics, "chunks_sent", 1)
  max_metric(metrics, "chunk_files_max", file_count)
  max_metric(metrics, "chunk_records_max", record_count)
  add_metric(metrics, "chunk_files_total", file_count)
  add_metric(metrics, "chunk_records_total", record_count)
  local send_started = now()
  local ok, err = ctx.send({
    type = "chunk",
    root = root.path or root,
    payload = {
      files = files,
      diagnostics = {
        files = file_count,
        records = record_count,
      },
    },
  })
  add_metric(metrics, "chunk_send_wait_ms", elapsed_ms(send_started))
  return ok, err
end

local function send_progress(ctx, state, payload, current, force)
  local interval = payload.progress_interval or DEFAULT_PROGRESS_INTERVAL
  local t = now()
  if not force and state.last_progress and t - state.last_progress < interval then return true end
  state.last_progress = t
  return ctx.send({
    type = "progress",
    payload = {
      files_scanned = state.files_scanned,
      files_indexed = state.files_indexed,
      files_skipped = state.files_skipped,
      current = current,
    },
  })
end

local function index_file(path, root_path, language, payload, info, usage_remaining, metrics)
  local max_bytes = payload.max_file_bytes or DEFAULT_MAX_FILE_BYTES
  local read_started = now()
  local text, err, file_info = read_file_text(path, max_bytes)
  add_metric(metrics, "file_read_ms", elapsed_ms(read_started))
  info = file_info or info
  if not text then return nil, err or "read-failed", info end
  inc_metric(metrics, "bytes_read", #text)
  if not native.has_language(language.grammar) then return nil, "missing-grammar", info end
  local sources = language.query_sources or {}
  if not sources.outline then return nil, "missing-outline-query", info end
  local usage_kind = payload.include_usages ~= false and query_kind(language) or nil
  local lines_started = now()
  local lines = records.lines_from_text(text)
  add_metric(metrics, "line_split_ms", elapsed_ms(lines_started))
  local result
  local native_started = now()
  result, err = native.index_text({
    language = language.grammar,
    lines = lines,
    outline_query = sources.outline,
    parse_timeout_ms = language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS,
    query_timeout_ms = option(language, "outline", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS),
    match_limit = option(language, "outline", "match_limit", DEFAULT_MATCH_LIMIT),
    max_captures = option(language, "outline", "max_captures", DEFAULT_MAX_CAPTURES),
  })
  add_metric(metrics, "native_index_text_ms", elapsed_ms(native_started))
  if not result then return nil, err or "index-text-failed", info end
  copy_native_metrics(metrics, result, "outline")

  local relpath = common.relative_path(root_path, path):gsub("\\", "/")
  local symbol_record_started = now()
  local symbols = records.symbols_from_captures(result.outline and result.outline.captures or {}, lines)
  add_metric(metrics, "symbol_record_ms", elapsed_ms(symbol_record_started))
  for _, symbol in ipairs(symbols) do
    symbol.path = path
    symbol.file = relpath
    symbol.relpath = relpath
    symbol.language_id = language.id
    symbol.text = symbol.name
  end

  local usages_by_name, usage_count = {}, 0
  local usage_complete = payload.include_usages ~= false
  if usage_kind then
    local language_usage_cap = option(language, "usages", "max_captures", DEFAULT_MAX_CAPTURES)
    local per_file_cap = payload.max_usage_captures_per_file or language_usage_cap
    local effective_cap = math.max(0, math.min(language_usage_cap, per_file_cap, usage_remaining or language_usage_cap))
    if effective_cap > 0 then
      local usage_native_started = now()
      local usage_result, usage_err = native.index_text({
        language = language.grammar,
        lines = lines,
        usage_query = sources[usage_kind],
        parse_timeout_ms = language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS,
        query_timeout_ms = option(language, "usages", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS),
        match_limit = option(language, "usages", "match_limit", DEFAULT_MATCH_LIMIT),
        max_captures = effective_cap,
      })
      add_metric(metrics, "native_index_text_ms", elapsed_ms(usage_native_started))
      if usage_result and usage_result.usage then
        copy_native_metrics(metrics, usage_result, "usage")
        local usage_record_started = now()
        usages_by_name, usage_count = records.usages_from_captures(usage_result.usage.captures, path, relpath, lines, language)
        add_metric(metrics, "usage_record_ms", elapsed_ms(usage_record_started))
        if usage_count >= effective_cap then usage_complete = false end
      else
        usage_complete = false
        if payload.log_skips then err = usage_err end
      end
    else
      usage_complete = false
    end
  end

  return {
    path = path,
    relpath = relpath,
    fingerprint = make_fingerprint(info, language),
    language_id = language.id,
    symbols = symbols,
    usages_by_name = usages_by_name,
    usage_count = usage_count,
    usage_complete = usage_complete,
  }, nil, info
end

local function walk(root, payload, ctx, state, chunk)
  local root_path = normalize(root.path or root)
  local stack = { root_path }
  while #stack > 0 do
    if ctx.cancelled() then return false, "cancelled" end
    local dir = table.remove(stack)
    inc_metric(state.metrics, "directories_walked", 1)
    local list_started = now()
    local entries = system.list_dir(dir) or {}
    add_metric(state.metrics, "directory_walk_ms", elapsed_ms(list_started))
    for _, name in ipairs(entries) do
      if ctx.cancelled() then return false, "cancelled" end
      local path = normalize(join_path(dir, name))
      local info_started = now()
      local info = system.get_file_info(path)
      add_metric(state.metrics, "directory_walk_ms", elapsed_ms(info_started))
      if info and info.type == "dir" then
        if should_descend(path, info, payload) then stack[#stack + 1] = path end
      elseif info and info.type == "file" and not excluded(path, payload.excluded) and not ignored_name(common.basename(path), payload.ignore_files) then
        state.files_scanned = state.files_scanned + 1
        inc_metric(state.metrics, "files_scanned", 1)
        local language = match_language(path, payload.languages)
        if language then
          local usage_cap = payload.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP
          local usage_remaining = math.max(0, usage_cap - state.usage_count)
          local file_result, err = index_file(path, root_path, language, payload, info, usage_remaining, state.metrics)
          if file_result then
            state.files_indexed = state.files_indexed + 1
            inc_metric(state.metrics, "files_indexed", 1)
            state.symbols_total = state.symbols_total + #(file_result.symbols or {})
            inc_metric(state.metrics, "symbols_emitted", #(file_result.symbols or {}))
            state.usage_count = state.usage_count + (file_result.usage_count or 0)
            inc_metric(state.metrics, "usages_emitted", file_result.usage_count or 0)
            if file_result.usage_complete == false then state.usage_truncated = true end
            if #chunk > 0 and (chunk.record_count or 0) + file_record_count(file_result) > (payload.chunk_records or DEFAULT_CHUNK_RECORDS) then
              flush_chunk(ctx, payload, root, state, chunk, true)
            end
            push_file(chunk, file_result)
            flush_chunk(ctx, payload, root, state, chunk, false)
          else
            state.files_skipped = state.files_skipped + 1
            inc_metric(state.metrics, "files_skipped", 1)
            if payload.log_skips then
              ctx.send({ type = "log", payload = { path = path, reason = err or "failed" } })
            end
          end
        end
        send_progress(ctx, state, payload, path, false)
      end
    end
  end
  return true
end

function worker.run(payload, ctx)
  local started = now()
  local state = {
    files_scanned = 0,
    files_indexed = 0,
    files_skipped = 0,
    symbols_total = 0,
    usage_count = 0,
    usage_truncated = false,
    metrics = {
      worker_id = ctx.worker_id,
      job_id = ctx.job_id,
      phase = ctx.phase,
      roots = {},
    },
  }
  local chunk = {}
  for _, root in ipairs(payload.roots or {}) do
    local root_started = now()
    local before_scanned = state.files_scanned
    local before_indexed = state.files_indexed
    local before_skipped = state.files_skipped
    local ok, reason = walk(root, payload, ctx, state, chunk)
    local root_metrics = {
      root = root.path or root,
      duration_ms = elapsed_ms(root_started),
      files_scanned = state.files_scanned - before_scanned,
      files_indexed = state.files_indexed - before_indexed,
      files_skipped = state.files_skipped - before_skipped,
    }
    state.metrics.roots[#state.metrics.roots + 1] = root_metrics
    add_metric(state.metrics, "root_scan_ms", root_metrics.duration_ms)
    if not ok then
      ctx.send({ type = "cancelled", payload = { reason = reason, files_scanned = state.files_scanned, diagnostics = state.metrics } })
      return
    end
    flush_chunk(ctx, payload, root, state, chunk, true)
  end
  state.metrics.total_ms = elapsed_ms(started)
  send_progress(ctx, state, payload, nil, true)
  ctx.send({
    type = "final",
    payload = {
      files_scanned = state.files_scanned,
      files_indexed = state.files_indexed,
      files_skipped = state.files_skipped,
      symbols_total = state.symbols_total,
      usage_count = state.usage_count,
      usage_truncated = state.usage_truncated,
      duration_ms = math.floor((now() - started) * 1000),
      diagnostics = state.metrics,
    },
  })
end

return worker
