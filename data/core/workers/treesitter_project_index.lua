-- Worker-side Tree-sitter project indexing job.
--
-- Input is plain serializable data prepared by the UI side. This worker does
-- filesystem walking, file reads, native parse/query through treesitter.index_text,
-- and compact record construction off the UI thread.

local common = require "core.common"
local artifact_codec = require "core.treesitter.artifact_codec"
local records = require "core.treesitter.project_index_records"
local native_result_adapter = require "core.treesitter.native_index_adapter"
local native = require "treesitter"

local native_worker_pool_ok, native_worker_pool = pcall(require, "worker_pool_native")
if not native_worker_pool_ok then native_worker_pool = nil end

local worker = {}

local DEFAULT_PARSE_TIMEOUT_MS = 1000
local DEFAULT_MATCH_LIMIT = 50000
local DEFAULT_MAX_CAPTURES = 50000
local DEFAULT_QUERY_TIMEOUT_MS = 20
local DEFAULT_MAX_FILE_BYTES = 2 * 1024 * 1024
local DEFAULT_PROGRESS_INTERVAL = 0.25
local DEFAULT_CHUNK_FILES = 16
local DEFAULT_CHUNK_RECORDS = 512
local DEFAULT_CHUNK_BYTES = 256 * 1024
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
    if native_metrics.total_ms then add_metric(metrics, "native_total_ms", native_metrics.total_ms) end
    if native_metrics.prepare_input_ms then add_metric(metrics, "native_prepare_input_ms", native_metrics.prepare_input_ms) end
    if native_metrics.parser_setup_ms then add_metric(metrics, "native_parser_setup_ms", native_metrics.parser_setup_ms) end
    if native_metrics.outline_query_ms then add_metric(metrics, "outline_query_ms", native_metrics.outline_query_ms) end
    if native_metrics.outline_query_compile_ms then add_metric(metrics, "outline_query_compile_ms", native_metrics.outline_query_compile_ms) end
    if native_metrics.outline_line_index_ms then add_metric(metrics, "outline_line_index_ms", native_metrics.outline_line_index_ms) end
    if native_metrics.usage_query_ms then add_metric(metrics, "usage_query_ms", native_metrics.usage_query_ms) end
    if native_metrics.usage_query_compile_ms then add_metric(metrics, "usage_query_compile_ms", native_metrics.usage_query_compile_ms) end
    if native_metrics.usage_line_index_ms then add_metric(metrics, "usage_line_index_ms", native_metrics.usage_line_index_ms) end
    if native_metrics.query_cache_hits then add_metric(metrics, "query_cache_hits", native_metrics.query_cache_hits) end
    if native_metrics.query_cache_misses then add_metric(metrics, "query_cache_misses", native_metrics.query_cache_misses) end
    if native_metrics.line_indexes_skipped then add_metric(metrics, "line_indexes_skipped", native_metrics.line_indexes_skipped) end
    if native_metrics.parser_reused then inc_metric(metrics, "parser_reuses", 1) end
    if native_metrics.total_ms then
      local accounted = (native_metrics.prepare_input_ms or 0)
        + (native_metrics.parser_setup_ms or 0)
        + (native_metrics.parse_ms or 0)
        + (native_metrics.outline_query_compile_ms or 0)
        + (native_metrics.outline_query_ms or 0)
        + (native_metrics.outline_line_index_ms or 0)
        + (native_metrics.usage_query_compile_ms or 0)
        + (native_metrics.usage_query_ms or 0)
        + (native_metrics.usage_line_index_ms or 0)
      add_metric(metrics, "native_other_ms", math.max(0, native_metrics.total_ms - accounted))
    end
    if native_metrics.parse_count then inc_metric(metrics, "parse_calls", native_metrics.parse_count) end
  end
  local captures = result and result[prefix] and result[prefix].capture_count
  if captures then inc_metric(metrics, prefix .. "_captures", captures) end
end

local native_index_pool

local function native_index_pool_for(payload)
  if payload.native_index_jobs == false or not native_worker_pool then return nil end
  if native_index_pool then return native_index_pool end
  local worker_count = math.max(1, math.floor(tonumber(payload.native_index_worker_count) or 1))
  local ok, pool = pcall(native_worker_pool.new, {
    name = "treesitter-project-index-native",
    worker_count = worker_count,
  })
  if not ok or not pool then return nil, pool or "native-pool-create-failed" end
  native_index_pool = pool
  return native_index_pool
end

local function native_index_text_job(native_opts, text, payload, ctx, metrics)
  local pool = native_index_pool_for(payload)
  if not pool then return nil, "native-pool-unavailable" end
  local spec = common.merge({}, native_opts or {})
  spec.kind = "treesitter_index_text"
  spec.lines = nil
  spec.text = text
  spec.capture_paging = true
  spec.line_range_lookup = false
  spec.compact_project_records = false
  local submit_started = now()
  local handle, err = pool:submit(spec)
  add_metric(metrics, "native_index_submit_ms", elapsed_ms(submit_started))
  if not handle then return nil, err or "native-submit-failed" end

  local result_handle
  local terminal
  local terminal_error
  while not terminal do
    if ctx.cancelled() then pool:cancel(handle) end
    local drain_started = now()
    local messages = pool:drain({ max_messages = 16 })
    add_metric(metrics, "native_index_drain_ms", elapsed_ms(drain_started))
    for _, message in ipairs(messages or {}) do
      if message.type == "result" then
        result_handle = message.result or (message.payload and message.payload.result)
      elseif message.type == "error" then
        terminal = "error"
        terminal_error = message.error or (message.payload and message.payload.error)
      elseif message.type == "cancelled" then
        terminal = "cancelled"
      elseif message.type == "final" or message.type == "complete" then
        terminal = message.type
      end
    end
    if not terminal then
      if system and system.sleep then system.sleep(0.001) else coroutine.yield(0.001) end
    end
  end

  if terminal == "cancelled" then return nil, "cancelled" end
  if terminal == "error" then return nil, terminal_error or "native-index-failed" end
  if not result_handle then return nil, "missing-native-index-result" end
  local adapt_started = now()
  local result, adapt_err = native_result_adapter.to_index_text_result(result_handle, {
    lazy = true,
    capture_chunk = payload.native_result_capture_chunk or payload.chunk_records or DEFAULT_CHUNK_RECORDS,
  })
  add_metric(metrics, "native_index_result_adapt_ms", elapsed_ms(adapt_started))
  if result then inc_metric(metrics, "native_index_jobs", 1) end
  return result, adapt_err
end

local function query_status_ok(query_result)
  local status = query_result and query_result.status or "ready"
  return status == "ready" or status == "limit"
end

local function file_record_count(file)
  return #(file.symbols or {}) + (file.usage_count or 0)
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

local function serialized_size(value)
  return #common.serialize(value)
end

local function push_file(chunk, file)
  chunk[#chunk + 1] = file
  chunk.record_count = (chunk.record_count or 0) + file_record_count(file)
  chunk.byte_count = (chunk.byte_count or 0) + serialized_size(file) + 64
end

local function bounded_record(record, max_bytes)
  local bytes = serialized_size(record)
  if bytes <= max_bytes then return record, bytes end
  local copy = {}
  for key, value in pairs(record or {}) do copy[key] = value end
  for _, key in ipairs({ "line_text", "declaration", "signature", "search_text", "text" }) do
    local value = copy[key]
    if type(value) == "string" and #value > 1024 then copy[key] = value:sub(1, 1000) .. "…[truncated]" end
  end
  copy.transport_truncated = true
  bytes = serialized_size(copy)
  return bytes <= max_bytes and copy or nil, bytes
end

local function split_large_file(file, max_records, max_bytes)
  max_records = math.max(1, tonumber(max_records) or DEFAULT_CHUNK_RECORDS)
  max_bytes = math.max(4096, tonumber(max_bytes) or DEFAULT_CHUNK_BYTES)
  local payload_budget = max_bytes - 4096
  if file_record_count(file) <= max_records and serialized_size(file) <= payload_budget then return { file } end

  local parts = {}
  local current
  local current_count = 0
  local current_bytes = 1024
  local function new_part()
    current = shallow_file_copy(file)
    current.partial = true
    current.file_done = false
    current.symbols = {}
    current.usages_by_name = {}
    current.usage_count = 0
    current.usage_complete = nil
    current_count = 0
    current_bytes = serialized_size(current) + 512
  end
  local function flush()
    if current and current_count > 0 then parts[#parts + 1] = current end
    new_part()
  end
  local function ensure_room(bytes)
    if current_count > 0 and (current_count >= max_records or current_bytes + bytes + 256 > payload_budget) then flush() end
  end

  new_part()
  for _, original in ipairs(file.symbols or {}) do
    local symbol, bytes = bounded_record(original, payload_budget - 2048)
    if not symbol then error("Tree-sitter Project symbol record exceeds chunk byte ceiling") end
    ensure_room(bytes)
    current.symbols[#current.symbols + 1] = symbol
    current_count = current_count + 1
    current_bytes = current_bytes + bytes + 128
  end
  for name, list in pairs(file.usages_by_name or {}) do
    for _, original in ipairs(list) do
      local usage, bytes = bounded_record(original, payload_budget - 2048)
      if not usage then error("Tree-sitter Project usage record exceeds chunk byte ceiling") end
      ensure_room(bytes + #name)
      local out = current.usages_by_name[name]
      if not out then out = {}; current.usages_by_name[name] = out; current_bytes = current_bytes + #name + 64 end
      out[#out + 1] = usage
      current.usage_count = current.usage_count + 1
      current_count = current_count + 1
      current_bytes = current_bytes + bytes + 128
    end
  end
  if current_count > 0 or #parts == 0 then parts[#parts + 1] = current end
  for i, part in ipairs(parts) do
    part.file_done = i == #parts
    part.usage_complete = part.file_done and file.usage_complete or nil
  end
  return parts
end

local flush_chunk

local function file_manifest(files)
  local manifest = {}
  for _, file in ipairs(files or {}) do
    manifest[#manifest + 1] = {
      path = file.path,
      fingerprint = file.fingerprint,
      usage_complete = file.usage_complete,
      partial = file.partial and true or nil,
      file_done = file.file_done and true or nil,
    }
  end
  return manifest
end

local function write_chunk_artifact(ctx, payload, state, files, diagnostics)
  local dir = payload.artifact_dir
  if not (payload.artifact_chunks and dir and dir ~= "") then return nil end
  local mkdir_started = now()
  local ok, err = common.mkdirp(dir)
  add_metric(state.metrics, "artifact_mkdir_ms", elapsed_ms(mkdir_started))
  if not ok and err ~= "path exists" then return nil, err or "mkdir-failed" end

  state.artifact_sequence = (state.artifact_sequence or 0) + 1
  local path = normalize(join_path(dir, string.format(
    "treesitter-index-%s-%s-%06d.bin",
    tostring(ctx.job_id or 0),
    tostring(ctx.worker_id or 0),
    state.artifact_sequence
  )))
  local artifact_payload = {
    files = files,
    diagnostics = diagnostics,
  }
  local write_started = now()
  local content = artifact_codec.encode(artifact_payload)
  if #content > (payload.chunk_bytes or DEFAULT_CHUNK_BYTES) then
    return nil, "artifact-byte-limit-exceeded"
  end
  local fp, open_err = io.open(path, "wb")
  if not fp then return nil, open_err or "open-failed" end
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
  local max_bytes = payload.chunk_bytes or DEFAULT_CHUNK_BYTES
  local parts = split_large_file(file, payload.chunk_records or DEFAULT_CHUNK_RECORDS, max_bytes)
  for _, part in ipairs(parts) do
    local part_bytes = serialized_size(part) + 64
    if #chunk > 0 and ((chunk.record_count or 0) + file_record_count(part) > (payload.chunk_records or DEFAULT_CHUNK_RECORDS)
      or (chunk.byte_count or 0) + part_bytes + 2048 > max_bytes)
    then
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
    and (chunk.byte_count or 0) + 2048 < (payload.chunk_bytes or DEFAULT_CHUNK_BYTES)
  then
    return true
  end
  local files = {}
  local file_count = #chunk
  local record_count = chunk.record_count or 0
  local byte_count = chunk.byte_count or 0
  for i = 1, #chunk do
    files[i] = chunk[i]
    chunk[i] = nil
  end
  chunk.record_count = 0
  chunk.byte_count = 0
  local metrics = state and state.metrics
  inc_metric(metrics, "chunks_sent", 1)
  max_metric(metrics, "chunk_files_max", file_count)
  max_metric(metrics, "chunk_records_max", record_count)
  add_metric(metrics, "chunk_files_total", file_count)
  add_metric(metrics, "chunk_records_total", record_count)
  local diagnostics = {
    files = file_count,
    records = record_count,
    estimated_bytes = byte_count,
  }
  local chunk_payload = {
    files = files,
    diagnostics = diagnostics,
  }
  local artifact, artifact_err = write_chunk_artifact(ctx, payload, state, files, diagnostics)
  if artifact then
    chunk_payload = {
      artifact = artifact,
      manifest = file_manifest(files),
      diagnostics = diagnostics,
    }
  elseif payload.artifact_chunks then
    inc_metric(metrics, "artifact_write_failures", 1)
    if artifact_err == "artifact-byte-limit-exceeded" then return false, artifact_err end
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

local function index_file(path, root_path, language, payload, ctx, info, usage_remaining, metrics, text_override)
  local max_bytes = payload.max_file_bytes or DEFAULT_MAX_FILE_BYTES
  local text, err, file_info
  if text_override ~= nil then
    text = tostring(text_override or "")
    if #text > max_bytes then return nil, "too-large", info end
  else
    local read_started = now()
    text, err, file_info = read_file_text(path, max_bytes)
    add_metric(metrics, "file_read_ms", elapsed_ms(read_started))
    info = file_info or info
  end
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
    cancel_token = ctx and ctx.cancel_token_name or nil,
  }
  if usage_kind and usage_effective_cap > 0 then
    native_opts.usage_query = sources[usage_kind]
    native_opts.usage_query_timeout_ms = option(language, "usages", "query_timeout_ms", DEFAULT_QUERY_TIMEOUT_MS)
    native_opts.usage_match_limit = option(language, "usages", "match_limit", DEFAULT_MATCH_LIMIT)
    native_opts.usage_max_captures = usage_effective_cap
  end

  local result
  local native_started = now()
  if payload.native_index_jobs ~= false then
    result, err = native_index_text_job(native_opts, text, payload, ctx, metrics)
    if not result and err ~= "cancelled" then
      inc_metric(metrics, "native_index_job_fallbacks", 1)
      result, err = native.index_text(native_opts)
    end
  else
    result, err = native.index_text(native_opts)
  end
  add_metric(metrics, "native_index_text_ms", elapsed_ms(native_started))
  if not result then return nil, err or "index-text-failed", info end
  copy_native_metrics(metrics, result, "outline")
  if result.usage then copy_native_metrics(metrics, result, "usage") end
  if not query_status_ok(result.outline) then
    return nil, (result.outline and result.outline.error) or "outline-query-failed", info
  end

  local relpath = common.relative_path(root_path, path):gsub("\\", "/")
  local symbol_record_started = now()
  local symbols
  if result.outline and result.outline.capture_iter then
    symbols = records.symbols_from_capture_iter(result.outline.capture_iter(), lines)
    inc_metric(metrics, "native_index_lazy_outline_records", 1)
  else
    symbols = records.symbols_from_captures(result.outline and result.outline.captures or {}, lines)
  end
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
      if result.usage.capture_iter then
        usages_by_name, usage_count = records.usages_from_capture_iter(result.usage.capture_iter(), path, relpath, lines, language)
        inc_metric(metrics, "native_index_lazy_usage_records", 1)
      else
        usages_by_name, usage_count = records.usages_from_captures(result.usage.captures, path, relpath, lines, language)
      end
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
  local scan_root = normalize(root.path or root)
  local root_path = normalize(root.root_path or payload.root_path or payload.root or scan_root)
  local stack = { scan_root }
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
          local file_result, err = index_file(path, root_path, language, payload, ctx, info, usage_remaining, state.metrics)
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
  local scan_root = normalize(root.path or root)
  local root_path = normalize(root.root_path or payload.root_path or payload.root or scan_root)
  local stack = { scan_root }
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
      local file_result, err = index_file(path, file_root, language, payload, ctx, file.info, usage_remaining, state.metrics, file.text)
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
