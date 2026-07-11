-- Worker-side aggregate builder for Tree-sitter project index chunks.
--
-- The project-index worker emits bounded file chunks using framed data artifacts.
-- This worker consumes those artifacts off the UI thread, builds the sorted disk
-- aggregate, and emits bounded aggregate chunks for the UI to adopt by simple
-- append/swap instead of scanning and sorting every file entry on the UI thread.

local common = require "core.common"
local artifact_codec = require "core.treesitter.artifact_codec"

local worker = {}

local DEFAULT_CHUNK_RECORDS = 512
local DEFAULT_CHUNK_BYTES = 256 * 1024
local DEFAULT_PROJECT_USAGE_CAP = 750000

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function elapsed_ms(started)
  return (now() - started) * 1000
end

local function add_metric(diagnostics, key, value)
  if diagnostics then diagnostics[key] = (diagnostics[key] or 0) + (tonumber(value) or 0) end
end

local function inc_metric(diagnostics, key, value)
  add_metric(diagnostics, key, value or 1)
end

local artifact_sequence = 0
local serialized_size

local function write_lua_payload(dir, prefix, payload, ctx, diagnostics)
  if not dir or dir == "" then return nil, "missing-dir" end
  local mkdir_started = now()
  local ok, err = common.mkdirp(dir)
  add_metric(diagnostics, "query_artifact_mkdir_ms", elapsed_ms(mkdir_started))
  if not ok and err ~= "path exists" then return nil, err or "mkdir-failed" end
  artifact_sequence = artifact_sequence + 1
  local path = common.normalize_path(dir .. PATHSEP .. string.format(
    "%s-%s-w%s-j%s-%06d.bin",
    tostring(prefix or "treesitter-query"),
    tostring(system and system.get_process_id and system.get_process_id() or 0),
    tostring(ctx and ctx.worker_id or 0),
    tostring(ctx and ctx.job_id or 0),
    artifact_sequence
  ))
  local open_started = now()
  local fp, open_err = io.open(path, "wb")
  add_metric(diagnostics, "query_artifact_open_ms", elapsed_ms(open_started))
  if not fp then return nil, open_err or "open-failed" end
  local encode_started = now()
  local content = artifact_codec.encode(payload)
  add_metric(diagnostics, "query_artifact_encode_ms", elapsed_ms(encode_started))
  local write_started = now()
  local wrote, write_err = fp:write(content)
  local closed, close_err = fp:close()
  add_metric(diagnostics, "query_artifact_file_write_ms", elapsed_ms(write_started))
  inc_metric(diagnostics, "query_artifacts_written", 1)
  add_metric(diagnostics, "query_artifact_bytes", #content)
  if not wrote or not closed then
    os.remove(path)
    return nil, write_err or close_err or "write-failed"
  end
  return { path = path, bytes = #content }
end

local function combined_chunk_artifact(chunks, count, bytes)
  if #chunks == 1 then
    chunks[1].count = count
    return chunks[1]
  end
  return {
    chunks = chunks,
    count = count,
    bytes = bytes,
    chunked = true,
  }
end

local function write_lua_array_chunks(dir, prefix, field, items, chunk_records, chunk_bytes, ctx, diagnostics)
  chunk_records = math.max(1, math.floor(tonumber(chunk_records) or DEFAULT_CHUNK_RECORDS))
  chunk_bytes = math.max(4096, math.floor(tonumber(chunk_bytes) or DEFAULT_CHUNK_BYTES))
  local chunks, chunk = {}, {}
  local total_bytes, estimated = 0, 256
  local function flush(force)
    if #chunk == 0 and not force then return true end
    local artifact, err = write_lua_payload(dir, prefix, { [field] = chunk }, ctx, diagnostics)
    if not artifact then return nil, err end
    if (artifact.bytes or 0) > chunk_bytes then pcall(os.remove, artifact.path); return nil, "query-artifact-byte-limit-exceeded" end
    chunks[#chunks + 1] = artifact
    total_bytes = total_bytes + (artifact.bytes or 0)
    chunk, estimated = {}, 256
    return true
  end
  for _, item in ipairs(items) do
    local bytes = serialized_size(item, diagnostics)
    if #chunk > 0 and (#chunk >= chunk_records or estimated + bytes + 128 > chunk_bytes) then
      local ok, err = flush(false); if not ok then return nil, err end
    end
    chunk[#chunk + 1] = item
    estimated = estimated + bytes + 128
  end
  local ok, err = flush(#items == 0); if not ok then return nil, err end
  return combined_chunk_artifact(chunks, #items, total_bytes)
end

local function write_lua_usages_by_name_chunks(dir, prefix, usages_by_name, usage_count, chunk_records, chunk_bytes, ctx, diagnostics)
  chunk_records = math.max(1, math.floor(tonumber(chunk_records) or DEFAULT_CHUNK_RECORDS))
  chunk_bytes = math.max(4096, math.floor(tonumber(chunk_bytes) or DEFAULT_CHUNK_BYTES))
  local chunks = {}
  local total_bytes = 0
  local current = {}
  local records = 0
  local estimated = 256

  local function flush(force)
    if records == 0 and not force then return true end
    local artifact, err = write_lua_payload(dir, prefix, { usages_by_name = current }, ctx, diagnostics)
    if not artifact then return nil, err end
    if (artifact.bytes or 0) > chunk_bytes then pcall(os.remove, artifact.path); return nil, "query-artifact-byte-limit-exceeded" end
    chunks[#chunks + 1] = artifact
    total_bytes = total_bytes + (artifact.bytes or 0)
    current = {}
    records = 0
    estimated = 256
    return true
  end

  local names = {}
  for name in pairs(usages_by_name or {}) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then
    local ok, err = flush(true)
    if not ok then return nil, err end
  else
    for _, name in ipairs(names) do
      for _, usage in ipairs(usages_by_name[name] or {}) do
        local bytes = serialized_size(usage, diagnostics) + #name + 128
        if records > 0 and (records >= chunk_records or estimated + bytes > chunk_bytes) then
          local ok, err = flush(false)
          if not ok then return nil, err end
        end
        local out = current[name]
        if not out then
          out = {}
          current[name] = out
        end
        out[#out + 1] = usage
        records = records + 1
        estimated = estimated + bytes
      end
    end
    local ok, err = flush(false)
    if not ok then return nil, err end
  end
  return combined_chunk_artifact(chunks, usage_count or 0, total_bytes)
end

local function load_artifact_payload(path)
  local payload, err = artifact_codec.read(path)
  if type(payload) ~= "table" then return nil, err or "artifact-invalid" end
  return payload
end

local function each_artifact(artifact, callback)
  if type(artifact) ~= "table" then
    if artifact then callback(artifact) end
    return
  end
  if artifact.chunks then
    for _, chunk in ipairs(artifact.chunks) do each_artifact(chunk, callback) end
  elseif artifact.path then
    callback(artifact.path)
  end
end

local function path_in_scope(path, scope)
  if not (path and scope) then return false end
  return common.path_equals(path, scope) or common.path_belongs_to(path, scope)
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

local function append_usage(aggregate, name, usage, usage_cap)
  if aggregate.usage_count >= usage_cap then
    aggregate.usage_truncated = true
    aggregate.usage_truncated_reason = "project-usage-cap"
    return false
  end
  local out = aggregate.usages_by_name[name]
  if not out then
    out = {}
    aggregate.usages_by_name[name] = out
  end
  out[#out + 1] = usage
  aggregate.usage_count = aggregate.usage_count + 1
  return true
end

local function append_file(aggregate, file, include_usages, usage_cap)
  if type(file) ~= "table" then return end
  for _, symbol in ipairs(file.symbols or {}) do aggregate.symbols[#aggregate.symbols + 1] = symbol end
  if file.usage_complete == false then
    aggregate.usage_truncated = true
    aggregate.usage_truncated_reason = "project-usage-cap"
  end
  if not include_usages then return end
  for name, list in pairs(file.usages_by_name or {}) do
    for _, usage in ipairs(list) do
      if not append_usage(aggregate, name, usage, usage_cap) then break end
    end
  end
end

local function append_base_payload(aggregate, chunk_payload, replacement_dir, include_usages, usage_cap)
  for _, symbol in ipairs((chunk_payload and chunk_payload.symbols) or {}) do
    if not path_in_scope(symbol.path, replacement_dir) then
      aggregate.symbols[#aggregate.symbols + 1] = symbol
    end
  end
  if not include_usages then return end
  for name, list in pairs((chunk_payload and chunk_payload.usages_by_name) or {}) do
    for _, usage in ipairs(list) do
      if not path_in_scope(usage.path, replacement_dir) then
        if not append_usage(aggregate, name, usage, usage_cap) then break end
      end
    end
  end
  for _, usage in ipairs((chunk_payload and chunk_payload.usages) or {}) do
    if usage.name and not path_in_scope(usage.path, replacement_dir) then
      if not append_usage(aggregate, usage.name, usage, usage_cap) then break end
    end
  end
end

serialized_size = function(value, diagnostics)
  local started = now()
  local bytes = #common.serialize(value)
  add_metric(diagnostics, "emit_serialize_ms", elapsed_ms(started))
  inc_metric(diagnostics, "serialized_size_calls", 1)
  add_metric(diagnostics, "serialized_size_bytes", bytes)
  return bytes
end

local function truncate_record(record, max_bytes, diagnostics)
  local bytes = serialized_size(record, diagnostics)
  if bytes <= max_bytes then return record, bytes end
  local copy = {}
  for key, value in pairs(record or {}) do copy[key] = value end
  for _, key in ipairs({ "line_text", "declaration", "signature", "search_text", "text" }) do
    local value = copy[key]
    if type(value) == "string" and #value > 1024 then copy[key] = value:sub(1, 1000) .. "…[truncated]" end
  end
  copy.transport_truncated = true
  bytes = serialized_size(copy, diagnostics)
  if bytes > max_bytes then return nil, bytes end
  return copy, bytes
end

local function send_aggregate_payload(ctx, payload, max_bytes, diagnostics)
  payload.serialized_bytes = 0
  payload.serialized_bytes = serialized_size(payload, diagnostics)
  payload.serialized_bytes = serialized_size(payload, diagnostics)
  if payload.serialized_bytes > max_bytes then return false, "aggregate-chunk-too-large" end
  local send_started = now()
  local ok, err = ctx.send({ type = "chunk", payload = payload })
  add_metric(diagnostics, "emit_send_wait_ms", elapsed_ms(send_started))
  inc_metric(diagnostics, "emit_chunks", 1)
  add_metric(diagnostics, "emit_records", payload.records or 0)
  return ok, err
end

local function compact_symbol(symbol)
  local copy = {}
  for key, value in pairs(symbol or {}) do
    if key ~= "text" and key ~= "file" and key ~= "range" and key ~= "search_text" then copy[key] = value end
  end
  return copy
end

local function send_symbol_chunks(ctx, aggregate, chunk_records, chunk_bytes, diagnostics)
  local chunk, estimated = {}, 256
  local function flush()
    if #chunk == 0 then return true end
    local payload = { kind = "aggregate", symbols = chunk, records = #chunk }
    chunk, estimated = {}, 256
    return send_aggregate_payload(ctx, payload, chunk_bytes, diagnostics)
  end
  for _, original in ipairs(aggregate.symbols) do
    if ctx.cancelled() then return false, "cancelled" end
    local symbol, bytes = truncate_record(compact_symbol(original), chunk_bytes - 1024, diagnostics)
    if not symbol then return false, "oversized-symbol-record" end
    if #chunk > 0 and (#chunk >= chunk_records or estimated + bytes + 64 > chunk_bytes) then
      local ok, err = flush()
      if not ok then return false, err end
    end
    chunk[#chunk + 1] = symbol
    estimated = estimated + bytes + 64
  end
  return flush()
end

local function compact_usage(name, usage)
  return {
    path = usage.path,
    relpath = usage.relpath or usage.file,
    language_id = usage.language_id,
    kind = usage.kind,
    capture = usage.capture,
    is_declaration = usage.is_declaration and true or false,
    line_text = usage.line_text,
    start_line = usage.start_line,
    start_col = usage.start_col,
    end_line = usage.end_line,
    end_col = usage.end_col,
    start_byte = usage.start_byte,
    end_byte = usage.end_byte,
    workspace_tree_sitter_fallback = usage.workspace_tree_sitter_fallback,
    transport_truncated = usage.transport_truncated,
  }
end

local function send_usage_chunks(ctx, aggregate, chunk_records, chunk_bytes, diagnostics)
  local names = {}
  for name in pairs(aggregate.usages_by_name) do names[#names + 1] = name end
  table.sort(names)
  local usages_by_name = {}
  local records = 0
  local estimated = 256
  local function flush(force)
    if records == 0 and not force then return true end
    local payload = {
      kind = "aggregate",
      usages_by_name = usages_by_name,
      usage_count = records,
      records = records,
    }
    usages_by_name = {}
    records = 0
    estimated = 256
    return send_aggregate_payload(ctx, payload, chunk_bytes, diagnostics)
  end
  for _, name in ipairs(names) do
    if ctx.cancelled() then return false, "cancelled" end
    local list = aggregate.usages_by_name[name] or {}
    for _, original in ipairs(list) do
      local usage, bytes = truncate_record(compact_usage(name, original), chunk_bytes - 1024, diagnostics)
      if not usage then return false, "oversized-usage-record" end
      if records > 0 and (records >= chunk_records or estimated + bytes + #name + 128 > chunk_bytes) then
        local ok, err = flush(false)
        if not ok then return false, err end
      end
      local out = usages_by_name[name]
      if not out then out = {}; usages_by_name[name] = out; estimated = estimated + #name + 32 end
      out[#out + 1] = usage
      records = records + 1
      estimated = estimated + bytes + 96
    end
  end
  return flush(false)
end

function worker.run(payload, ctx)
  payload = payload or {}
  local started = now()
  local include_usages = payload.include_usages ~= false
  local usage_cap = tonumber(payload.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP) or DEFAULT_PROJECT_USAGE_CAP
  local chunk_records = math.max(1, math.floor(tonumber(payload.chunk_records or DEFAULT_CHUNK_RECORDS) or DEFAULT_CHUNK_RECORDS))
  local chunk_bytes = math.max(4096, math.floor(tonumber(payload.chunk_bytes or DEFAULT_CHUNK_BYTES) or DEFAULT_CHUNK_BYTES))
  local query_artifact_chunk_records = math.max(1, math.floor(tonumber(payload.query_artifact_chunk_records or chunk_records) or chunk_records))
  local query_artifact_chunk_bytes = math.max(4096, math.floor(tonumber(payload.query_artifact_chunk_bytes or chunk_bytes) or chunk_bytes))
  local aggregate = {
    symbols = {},
    usages_by_name = {},
    usage_count = 0,
    usage_truncated = false,
    usage_truncated_reason = nil,
  }
  local diagnostics = {
    artifacts_loaded = 0,
    base_artifacts_loaded = 0,
    files_loaded = 0,
    load_ms = 0,
    base_load_ms = 0,
    append_ms = 0,
    sort_ms = 0,
    symbol_sort_ms = 0,
    usage_sort_ms = 0,
    query_artifact_mkdir_ms = 0,
    query_artifact_open_ms = 0,
    query_artifact_encode_ms = 0,
    query_artifact_file_write_ms = 0,
    query_artifacts_written = 0,
    query_artifact_bytes = 0,
    emit_reset_ms = 0,
    emit_symbols_ms = 0,
    emit_usages_ms = 0,
    emit_serialize_ms = 0,
    emit_send_wait_ms = 0,
    emit_chunks = 0,
    emit_records = 0,
    serialized_size_calls = 0,
    serialized_size_bytes = 0,
    symbols_total = 0,
    usage_count = 0,
  }

  local replacement_dir = payload.replacement_dir
  if replacement_dir then
    local base_load_error
    local function consume_base_artifact(artifact)
      each_artifact(artifact, function(path)
        if ctx.cancelled() or base_load_error then return end
        local load_started = now()
        local chunk_payload, err = load_artifact_payload(path)
        diagnostics.base_load_ms = diagnostics.base_load_ms + elapsed_ms(load_started)
        if chunk_payload then
          diagnostics.base_artifacts_loaded = diagnostics.base_artifacts_loaded + 1
          append_base_payload(aggregate, chunk_payload, replacement_dir, include_usages, usage_cap)
        else
          base_load_error = err or "base-artifact-load-failed"
          ctx.send({ type = "log", payload = { path = path, reason = base_load_error } })
        end
      end)
    end
    consume_base_artifact(payload.base_symbol_artifact)
    consume_base_artifact(payload.base_usage_artifact)
    if base_load_error then
      error("failed to load base aggregate artifact: " .. tostring(base_load_error))
    end
    if payload.base_usage_truncated then
      aggregate.usage_truncated = true
      aggregate.usage_truncated_reason = payload.base_usage_truncated_reason or "project-usage-cap"
    end
    if ctx.cancelled() then ctx.send({ type = "cancelled", payload = { reason = "cancelled" } }); return end
  end

  local function consume_payload(chunk_payload)
    local append_started = now()
    for _, file in ipairs((chunk_payload and chunk_payload.files) or {}) do
      append_file(aggregate, file, include_usages, usage_cap)
      diagnostics.files_loaded = diagnostics.files_loaded + 1
    end
    diagnostics.append_ms = diagnostics.append_ms + elapsed_ms(append_started)
  end

  for _, artifact in ipairs(payload.artifacts or {}) do
    if ctx.cancelled() then ctx.send({ type = "cancelled", payload = { reason = "cancelled" } }); return end
    local path = type(artifact) == "table" and artifact.path or artifact
    if path then
      local load_started = now()
      local chunk_payload, err = load_artifact_payload(path)
      diagnostics.load_ms = diagnostics.load_ms + elapsed_ms(load_started)
      if chunk_payload then
        diagnostics.artifacts_loaded = diagnostics.artifacts_loaded + 1
        consume_payload(chunk_payload)
      else
        ctx.send({ type = "log", payload = { path = path, reason = err or "artifact-load-failed" } })
      end
      if payload.remove_artifacts ~= false then pcall(os.remove, path) end
    end
  end
  consume_payload(payload)

  local sort_started = now()
  local symbol_sort_started = now()
  sort_symbols(aggregate.symbols)
  diagnostics.symbol_sort_ms = elapsed_ms(symbol_sort_started)
  local usage_sort_started = now()
  for _, list in pairs(aggregate.usages_by_name) do sort_usages(list) end
  diagnostics.usage_sort_ms = elapsed_ms(usage_sort_started)
  diagnostics.sort_ms = elapsed_ms(sort_started)
  diagnostics.symbols_total = #aggregate.symbols
  diagnostics.usage_count = aggregate.usage_count

  local symbol_query_artifact
  local usage_query_artifact
  if payload.query_artifact_dir then
    local artifact_started = now()
    local compact_symbols = {}
    for i, symbol in ipairs(aggregate.symbols) do
      compact_symbols[i] = symbol
      symbol.search_text = tostring(symbol.search_text or symbol.text or symbol.name or "")
    end
    local artifact, artifact_err = write_lua_array_chunks(
      payload.query_artifact_dir,
      "treesitter-symbols-index",
      "symbols",
      compact_symbols,
      query_artifact_chunk_records,
      query_artifact_chunk_bytes,
      ctx,
      diagnostics
    )
    diagnostics.symbol_query_artifact_ms = elapsed_ms(artifact_started)
    if artifact then
      symbol_query_artifact = artifact
      diagnostics.symbol_query_artifact_items = #compact_symbols
    else
      diagnostics.symbol_query_artifact_error = artifact_err or "artifact-write-failed"
    end

    local usage_artifact_started = now()
    local usage_artifact, usage_artifact_err = write_lua_usages_by_name_chunks(
      payload.query_artifact_dir,
      "treesitter-usages-index",
      aggregate.usages_by_name,
      aggregate.usage_count,
      query_artifact_chunk_records,
      query_artifact_chunk_bytes,
      ctx,
      diagnostics
    )
    diagnostics.usage_query_artifact_ms = elapsed_ms(usage_artifact_started)
    if usage_artifact then
      usage_query_artifact = usage_artifact
      diagnostics.usage_query_artifact_items = aggregate.usage_count
    else
      diagnostics.usage_query_artifact_error = usage_artifact_err or "artifact-write-failed"
    end
  end

  local reset_payload = {
    kind = "aggregate",
    reset = true,
    symbols_total = #aggregate.symbols,
    usage_count_total = aggregate.usage_count,
    usage_truncated = aggregate.usage_truncated,
    usage_truncated_reason = aggregate.usage_truncated_reason,
    records = 0,
  }
  local emit_started = now()
  local ok, err = send_aggregate_payload(ctx, reset_payload, chunk_bytes, diagnostics)
  diagnostics.emit_reset_ms = elapsed_ms(emit_started)
  if not ok then ctx.send({ type = "cancelled", payload = { reason = err or "cancelled" } }); return end
  emit_started = now()
  ok, err = send_symbol_chunks(ctx, aggregate, chunk_records, chunk_bytes, diagnostics)
  diagnostics.emit_symbols_ms = elapsed_ms(emit_started)
  if not ok then ctx.send({ type = "cancelled", payload = { reason = err or "cancelled" } }); return end
  emit_started = now()
  ok, err = send_usage_chunks(ctx, aggregate, chunk_records, chunk_bytes, diagnostics)
  diagnostics.emit_usages_ms = elapsed_ms(emit_started)
  if not ok then ctx.send({ type = "cancelled", payload = { reason = err or "cancelled" } }); return end

  diagnostics.total_ms = elapsed_ms(started)
  ctx.send({
    type = "final",
    payload = {
      aggregate = true,
      symbols_total = #aggregate.symbols,
      usage_count = aggregate.usage_count,
      usage_truncated = aggregate.usage_truncated,
      usage_truncated_reason = aggregate.usage_truncated_reason,
      symbol_query_artifact = symbol_query_artifact,
      usage_query_artifact = usage_query_artifact,
      diagnostics = diagnostics,
    },
  })
end

return worker
