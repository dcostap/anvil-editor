-- Worker-side aggregate builder for Tree-sitter project index chunks.
--
-- The project-index worker emits bounded file chunks, often as Lua artifacts.
-- This worker consumes those artifacts off the UI thread, builds the sorted disk
-- aggregate, and emits bounded aggregate chunks for the UI to adopt by simple
-- append/swap instead of scanning and sorting every file entry on the UI thread.

local common = require "core.common"

local worker = {}

local DEFAULT_CHUNK_RECORDS = 2048
local DEFAULT_PROJECT_USAGE_CAP = 750000

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function elapsed_ms(started)
  return (now() - started) * 1000
end

local artifact_sequence = 0

local function write_lua_payload(dir, prefix, payload)
  if not dir or dir == "" then return nil, "missing-dir" end
  local ok, err = common.mkdirp(dir)
  if not ok and err ~= "path exists" then return nil, err or "mkdir-failed" end
  artifact_sequence = artifact_sequence + 1
  local path = common.normalize_path(dir .. PATHSEP .. string.format(
    "%s-%s-%06d.lua",
    tostring(prefix or "treesitter-query"),
    tostring(system and system.get_process_id and system.get_process_id() or 0),
    artifact_sequence
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

local function load_lua_payload(path)
  local loader, err = loadfile(path)
  if not loader then return nil, err or "artifact-load-failed" end
  local ok, payload = pcall(loader)
  if not ok or type(payload) ~= "table" then return nil, payload or "artifact-invalid" end
  return payload
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

local function append_file(aggregate, file, include_usages, usage_cap)
  if type(file) ~= "table" then return end
  for _, symbol in ipairs(file.symbols or {}) do aggregate.symbols[#aggregate.symbols + 1] = symbol end
  if file.usage_complete == false then
    aggregate.usage_truncated = true
    aggregate.usage_truncated_reason = "project-usage-cap"
  end
  if not include_usages then return end
  for name, list in pairs(file.usages_by_name or {}) do
    local out = aggregate.usages_by_name[name]
    if not out then
      out = {}
      aggregate.usages_by_name[name] = out
    end
    for _, usage in ipairs(list) do
      if aggregate.usage_count < usage_cap then
        out[#out + 1] = usage
        aggregate.usage_count = aggregate.usage_count + 1
      else
        aggregate.usage_truncated = true
        aggregate.usage_truncated_reason = "project-usage-cap"
        break
      end
    end
  end
end

local function send_symbol_chunks(ctx, aggregate, chunk_records)
  local symbols = aggregate.symbols
  for i = 1, #symbols, chunk_records do
    if ctx.cancelled() then return false, "cancelled" end
    local chunk = {}
    for j = i, math.min(#symbols, i + chunk_records - 1) do chunk[#chunk + 1] = symbols[j] end
    local ok, err = ctx.send({
      type = "chunk",
      payload = {
        kind = "aggregate",
        symbols = chunk,
        records = #chunk,
      },
    })
    if not ok then return false, err end
  end
  return true
end

local function send_usage_chunks(ctx, aggregate, chunk_records)
  local names = {}
  for name in pairs(aggregate.usages_by_name) do names[#names + 1] = name end
  table.sort(names)
  local usages_by_name = {}
  local records = 0
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
    local ok, err = ctx.send({ type = "chunk", payload = payload })
    if not ok then return false, err end
    return true
  end
  for _, name in ipairs(names) do
    if ctx.cancelled() then return false, "cancelled" end
    local list = aggregate.usages_by_name[name] or {}
    local sorted = {}
    for _, usage in ipairs(list) do
      sorted[#sorted + 1] = usage
      records = records + 1
      if records >= chunk_records then
        usages_by_name[name] = sorted
        sorted = {}
        local ok, err = flush(false)
        if not ok then return false, err end
      end
    end
    if #sorted > 0 then usages_by_name[name] = sorted end
  end
  return flush(false)
end

function worker.run(payload, ctx)
  payload = payload or {}
  local started = now()
  local include_usages = payload.include_usages ~= false
  local usage_cap = tonumber(payload.project_usage_cap or DEFAULT_PROJECT_USAGE_CAP) or DEFAULT_PROJECT_USAGE_CAP
  local chunk_records = math.max(1, math.floor(tonumber(payload.chunk_records or DEFAULT_CHUNK_RECORDS) or DEFAULT_CHUNK_RECORDS))
  local aggregate = {
    symbols = {},
    usages_by_name = {},
    usage_count = 0,
    usage_truncated = false,
    usage_truncated_reason = nil,
  }
  local diagnostics = {
    artifacts_loaded = 0,
    files_loaded = 0,
    load_ms = 0,
    sort_ms = 0,
    symbols_total = 0,
    usage_count = 0,
  }

  local function consume_payload(chunk_payload)
    for _, file in ipairs((chunk_payload and chunk_payload.files) or {}) do
      append_file(aggregate, file, include_usages, usage_cap)
      diagnostics.files_loaded = diagnostics.files_loaded + 1
    end
  end

  for _, artifact in ipairs(payload.artifacts or {}) do
    if ctx.cancelled() then ctx.send({ type = "cancelled", payload = { reason = "cancelled" } }); return end
    local path = type(artifact) == "table" and artifact.path or artifact
    if path then
      local load_started = now()
      local chunk_payload, err = load_lua_payload(path)
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
  sort_symbols(aggregate.symbols)
  for _, list in pairs(aggregate.usages_by_name) do sort_usages(list) end
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
    local artifact, artifact_err = write_lua_payload(payload.query_artifact_dir, "treesitter-symbols-index", {
      symbols = compact_symbols,
    })
    diagnostics.symbol_query_artifact_ms = elapsed_ms(artifact_started)
    if artifact then
      symbol_query_artifact = artifact
      diagnostics.symbol_query_artifact_items = #compact_symbols
    else
      diagnostics.symbol_query_artifact_error = artifact_err or "artifact-write-failed"
    end

    local usage_artifact_started = now()
    local usage_artifact, usage_artifact_err = write_lua_payload(payload.query_artifact_dir, "treesitter-usages-index", {
      usages_by_name = aggregate.usages_by_name,
    })
    diagnostics.usage_query_artifact_ms = elapsed_ms(usage_artifact_started)
    if usage_artifact then
      usage_query_artifact = usage_artifact
      diagnostics.usage_query_artifact_items = aggregate.usage_count
    else
      diagnostics.usage_query_artifact_error = usage_artifact_err or "artifact-write-failed"
    end
  end

  ctx.send({
    type = "chunk",
    payload = {
      kind = "aggregate",
      reset = true,
      symbols_total = #aggregate.symbols,
      usage_count_total = aggregate.usage_count,
      usage_truncated = aggregate.usage_truncated,
      usage_truncated_reason = aggregate.usage_truncated_reason,
      records = 0,
    },
  })
  local ok, err = send_symbol_chunks(ctx, aggregate, chunk_records)
  if not ok then ctx.send({ type = "cancelled", payload = { reason = err or "cancelled" } }); return end
  ok, err = send_usage_chunks(ctx, aggregate, chunk_records)
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
