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
local DEFAULT_BATCH_FILES = 64
local DEFAULT_BATCH_BYTES = 4 * 1024 * 1024

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
  if prefix == "outline" then
    if native_metrics.parse_ms then add_metric(metrics, "parse_ms", native_metrics.parse_ms) end
    if native_metrics.outline_query_ms then add_metric(metrics, "outline_query_ms", native_metrics.outline_query_ms) end
    if native_metrics.usage_query_ms then add_metric(metrics, "usage_query_ms", native_metrics.usage_query_ms) end
    if native_metrics.parse_count then inc_metric(metrics, "parse_calls", native_metrics.parse_count) end
  end
  local captures = result and result[prefix] and result[prefix].capture_count
  if captures then inc_metric(metrics, prefix .. "_captures", captures) end
end

local function query_status_ok(query_result)
  local status = query_result and query_result.status or "ready"
  return status == "ready" or status == "limit"
end

local function file_record_count(file)
  return #(file.symbols or {}) + (file.usage_count or 0)
end

local function usage_list_count(usages_by_name)
  local count = 0
  for _, list in pairs(usages_by_name or {}) do count = count + #list end
  return count
end

local function shallow_file_copy(file)
  local copy = {}
  for key, value in pairs(file or {}) do
    if key ~= "symbols" and key ~= "usages_by_name" and key ~= "usage_count" then
      copy[key] = value
    end
  end
  return copy
end

local function push_file(chunk, file)
  chunk[#chunk + 1] = file
  chunk.record_count = (chunk.record_count or 0) + file_record_count(file)
end

local function split_large_file(file, max_records)
  max_records = tonumber(max_records) or DEFAULT_CHUNK_RECORDS
  if max_records <= 0 or file_record_count(file) <= max_records then return { file } end

  local symbols = file.symbols or {}
  local usages_by_name = file.usages_by_name or {}
  local total_usages = usage_list_count(usages_by_name)
  if total_usages == 0 then
    local parts = {}
    for i = 1, #symbols, max_records do
      local part = shallow_file_copy(file)
      part.partial = true
      part.file_done = i + max_records > #symbols
      part.symbols = {}
      part.usages_by_name = {}
      part.usage_count = 0
      part.usage_complete = part.file_done and file.usage_complete or nil
      for j = i, math.min(#symbols, i + max_records - 1) do
        part.symbols[#part.symbols + 1] = symbols[j]
      end
      parts[#parts + 1] = part
    end
    return #parts > 0 and parts or { file }
  end

  local parts = {}
  local first = true
  local current
  local current_count

  local function new_part()
    local part = shallow_file_copy(file)
    part.partial = true
    part.file_done = false
    part.symbols = first and symbols or {}
    part.usages_by_name = {}
    part.usage_count = 0
    current = part
    current_count = #(part.symbols or {})
    first = false
  end

  local function flush(done)
    if not current then return end
    current.file_done = done and true or false
    current.usage_complete = done and file.usage_complete or nil
    parts[#parts + 1] = current
    current = nil
    current_count = 0
  end

  new_part()
  for name, list in pairs(usages_by_name) do
    for _, usage in ipairs(list) do
      if current_count >= max_records and current.usage_count > 0 then
        flush(false)
        new_part()
      end
      local out = current.usages_by_name[name]
      if not out then
        out = {}
        current.usages_by_name[name] = out
      end
      out[#out + 1] = usage
      current.usage_count = current.usage_count + 1
      current_count = current_count + 1
    end
  end
  flush(true)
  return parts
end

local flush_chunk

local function write_chunk_artifact(ctx, payload, state, files, diagnostics)
  local dir = payload.artifact_dir
  if not (payload.artifact_chunks and dir and dir ~= "") then return nil end
  local mkdir_started = now()
  local ok, err = common.mkdirp(dir)
  add_metric(state.metrics, "artifact_mkdir_ms", elapsed_ms(mkdir_started))
  if not ok and err ~= "path exists" then return nil, err or "mkdir-failed" end

  state.artifact_sequence = (state.artifact_sequence or 0) + 1
  local path = normalize(join_path(dir, string.format(
    "treesitter-index-%s-%s-%06d.lua",
    tostring(ctx.job_id or 0),
    tostring(ctx.worker_id or 0),
    state.artifact_sequence
  )))
  local artifact_payload = {
    files = files,
    diagnostics = diagnostics,
  }
  local write_started = now()
  local fp, open_err = io.open(path, "wb")
  if not fp then return nil, open_err or "open-failed" end
  local content = "return " .. common.serialize(artifact_payload)
  local wrote, write_err = fp:write(content)
  local closed, close_err = fp:close()
  add_metric(state.metrics, "artifact_write_ms", elapsed_ms(write_started))
  if not wrote or not closed then
    os.remove(path)
    return nil, write_err or close_err or "write-failed"
  end
  inc_metric(state.metrics, "artifacts_sent", 1)
  add_metric(state.metrics, "artifact_bytes", #content)
  max_metric(state.metrics, "artifact_bytes_max", #content)
  return {
    path = path,
    bytes = #content,
    files = diagnostics.files,
    records = diagnostics.records,
  }
end

local function push_file_bounded(ctx, payload, root, state, chunk, file)
  local parts = split_large_file(file, payload.chunk_records or DEFAULT_CHUNK_RECORDS)
  for _, part in ipairs(parts) do
    if #chunk > 0 and (chunk.record_count or 0) + file_record_count(part) > (payload.chunk_records or DEFAULT_CHUNK_RECORDS) then
      local ok, err = flush_chunk(ctx, payload, root, state, chunk, true)
      if not ok then return nil, err end
    end
    push_file(chunk, part)
    local ok, err = flush_chunk(ctx, payload, root, state, chunk, false)
    if not ok then return nil, err end
  end
  return true
end

flush_chunk = function(ctx, payload, root, state, chunk, force)
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
  local diagnostics = {
    files = file_count,
    records = record_count,
  }
  local chunk_payload = {
    files = files,
    diagnostics = diagnostics,
  }
  local artifact, artifact_err = write_chunk_artifact(ctx, payload, state, files, diagnostics)
  if artifact then
    chunk_payload = {
      artifact = artifact,
      diagnostics = diagnostics,
    }
  elseif payload.artifact_chunks then
    inc_metric(metrics, "artifact_write_failures", 1)
    if payload.log_skips then
      ctx.send({ type = "log", payload = { reason = artifact_err or "artifact-write-failed" } })
    end
  end

  local send_started = now()
  local ok, err = ctx.send({
    type = "chunk",
    root = root.path or root,
    payload = chunk_payload,
  })
  if not ok and chunk_payload.artifact and chunk_payload.artifact.path then
    os.remove(chunk_payload.artifact.path)
    inc_metric(metrics, "artifacts_removed_after_send_failure", 1)
  end
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

local function serializable_info(info)
  if not info then return nil end
  return {
    type = info.type,
    size = info.size,
    modified = info.modified,
  }
end

local function send_batch(ctx, payload, state, batch, force)
  if not batch or #batch.files == 0 then return true end
  local max_files = tonumber(payload.batch_files or DEFAULT_BATCH_FILES) or DEFAULT_BATCH_FILES
  local max_bytes = tonumber(payload.batch_bytes or DEFAULT_BATCH_BYTES) or DEFAULT_BATCH_BYTES
  if not force and #batch.files < max_files and batch.bytes < max_bytes then return true end

  local out = {
    root = batch.root,
    files = batch.files,
    diagnostics = {
      files = #batch.files,
      bytes = batch.bytes,
    },
  }
  inc_metric(state.metrics, "batches_sent", 1)
  max_metric(state.metrics, "batch_files_max", #batch.files)
  max_metric(state.metrics, "batch_bytes_max", batch.bytes)
  add_metric(state.metrics, "batch_files_total", #batch.files)
  add_metric(state.metrics, "batch_bytes_total", batch.bytes)
  batch.files = {}
  batch.bytes = 0
  return ctx.send({
    type = "chunk",
    payload = {
      batches = { out },
      diagnostics = {
        batches = 1,
        files = out.diagnostics.files,
        bytes = out.diagnostics.bytes,
      },
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
  local usage_effective_cap = 0
  if usage_kind then
    local language_usage_cap = option(language, "usages", "max_captures", DEFAULT_MAX_CAPTURES)
    local per_file_cap = payload.max_usage_captures_per_file or language_usage_cap
    usage_effective_cap = math.max(0, math.min(language_usage_cap, per_file_cap, usage_remaining or language_usage_cap))
  end

  local native_opts = {
    language = language.grammar,
    lines = lines,
    outline_query = sources.outline,
    parse_timeout_ms = language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS,
    query_timeout_ms = option(language, "outline", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS),
    match_limit = option(language, "outline", "match_limit", DEFAULT_MATCH_LIMIT),
    max_captures = option(language, "outline", "max_captures", DEFAULT_MAX_CAPTURES),
  }
  if usage_kind and usage_effective_cap > 0 then
    native_opts.usage_query = sources[usage_kind]
    native_opts.usage_query_timeout_ms = option(language, "usages", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS)
    native_opts.usage_match_limit = option(language, "usages", "match_limit", DEFAULT_MATCH_LIMIT)
    native_opts.usage_max_captures = usage_effective_cap
  end

  local result
  local native_started = now()
  result, err = native.index_text(native_opts)
  add_metric(metrics, "native_index_text_ms", elapsed_ms(native_started))
  if not result then return nil, err or "index-text-failed", info end
  copy_native_metrics(metrics, result, "outline")
  if result.usage then copy_native_metrics(metrics, result, "usage") end
  if not query_status_ok(result.outline) then
    return nil, (result.outline and result.outline.error) or "outline-query-failed", info
  end

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
    if usage_effective_cap > 0 and result.usage and query_status_ok(result.usage) then
      local usage_record_started = now()
      usages_by_name, usage_count = records.usages_from_captures(result.usage.captures, path, relpath, lines, language)
      add_metric(metrics, "usage_record_ms", elapsed_ms(usage_record_started))
      if usage_count >= usage_effective_cap or result.usage.status == "limit" then usage_complete = false end
    else
      usage_complete = false
      if payload.log_skips and result.usage then err = result.usage.error end
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
            local ok, flush_err = push_file_bounded(ctx, payload, root, state, chunk, file_result)
            if not ok then return false, flush_err end
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

local function walk_batches(root, payload, ctx, state)
  local root_path = normalize(root.path or root)
  local stack = { root_path }
  local batch = { root = root_path, files = {}, bytes = 0 }
  local max_files = tonumber(payload.batch_files or DEFAULT_BATCH_FILES) or DEFAULT_BATCH_FILES
  local max_bytes = tonumber(payload.batch_bytes or DEFAULT_BATCH_BYTES) or DEFAULT_BATCH_BYTES

  local function add_to_batch(path, info, language)
    local size = tonumber(info and info.size) or 0
    if #batch.files > 0 and (#batch.files >= max_files or batch.bytes + size > max_bytes) then
      local ok, err = send_batch(ctx, payload, state, batch, true)
      if not ok then return nil, err end
    end
    batch.files[#batch.files + 1] = {
      path = path,
      root = root_path,
      info = serializable_info(info),
      language_id = language.id,
    }
    batch.bytes = batch.bytes + size
    if size >= max_bytes then
      local ok, err = send_batch(ctx, payload, state, batch, true)
      if not ok then return nil, err end
    else
      local ok, err = send_batch(ctx, payload, state, batch, false)
      if not ok then return nil, err end
    end
    return true
  end

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
          local ok, err = add_to_batch(path, info, language)
          if not ok then return false, err end
        else
          state.files_skipped = state.files_skipped + 1
          inc_metric(state.metrics, "files_skipped", 1)
        end
        send_progress(ctx, state, payload, path, false)
      end
    end
  end
  return send_batch(ctx, payload, state, batch, true)
end

local function language_for_file(file, path, languages)
  if file.language then return file.language end
  if file.language_id then
    for _, language in ipairs(languages or {}) do
      if language.id == file.language_id then return language end
    end
  end
  return path and match_language(path, languages)
end

local function index_files(payload, ctx, state, chunk)
  local root_path = normalize(payload.root or payload.root_path or ((payload.roots or {})[1] and ((payload.roots or {})[1].path or (payload.roots or {})[1])) or ".")
  for _, file in ipairs(payload.files or {}) do
    if ctx.cancelled() then return false, "cancelled" end
    local path = file.path and normalize(file.path)
    local language = language_for_file(file, path, payload.languages)
    local file_root = normalize(file.root or root_path)
    if path and language and not excluded(path, payload.excluded) and not ignored_name(common.basename(path), payload.ignore_files) then
      state.files_scanned = state.files_scanned + 1
      inc_metric(state.metrics, "files_scanned", 1)
      local usage_cap = payload.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP
      local usage_remaining = math.max(0, usage_cap - state.usage_count)
      local file_result, err = index_file(path, file_root, language, payload, file.info, usage_remaining, state.metrics)
      if file_result then
        state.files_indexed = state.files_indexed + 1
        inc_metric(state.metrics, "files_indexed", 1)
        state.symbols_total = state.symbols_total + #(file_result.symbols or {})
        inc_metric(state.metrics, "symbols_emitted", #(file_result.symbols or {}))
        state.usage_count = state.usage_count + (file_result.usage_count or 0)
        inc_metric(state.metrics, "usages_emitted", file_result.usage_count or 0)
        if file_result.usage_complete == false then state.usage_truncated = true end
        local ok, flush_err = push_file_bounded(ctx, payload, { path = file_root }, state, chunk, file_result)
        if not ok then return false, flush_err end
      else
        state.files_skipped = state.files_skipped + 1
        inc_metric(state.metrics, "files_skipped", 1)
        if payload.log_skips then ctx.send({ type = "log", payload = { path = path, reason = err or "failed" } }) end
      end
      send_progress(ctx, state, payload, path, false)
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
  if payload.files then
    local ok, reason = index_files(payload, ctx, state, chunk)
    if not ok then
      ctx.send({ type = "cancelled", payload = { reason = reason, files_scanned = state.files_scanned, diagnostics = state.metrics } })
      return
    end
    flush_chunk(ctx, payload, { path = payload.root or payload.root_path or "." }, state, chunk, true)
  else
    for _, root in ipairs(payload.roots or {}) do
      local root_started = now()
      local before_scanned = state.files_scanned
      local before_indexed = state.files_indexed
      local before_skipped = state.files_skipped
      local ok, reason
      if payload.mode == "walk" then
        ok, reason = walk_batches(root, payload, ctx, state)
      else
        ok, reason = walk(root, payload, ctx, state, chunk)
      end
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
      if payload.mode ~= "walk" then flush_chunk(ctx, payload, root, state, chunk, true) end
    end
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
      usage_budget_used = state.usage_count,
      duration_ms = math.floor((now() - started) * 1000),
      diagnostics = state.metrics,
    },
  })
end

return worker
