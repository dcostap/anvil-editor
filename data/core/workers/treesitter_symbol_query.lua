-- Worker-side Project symbol query job.
--
-- This is intentionally for compact/snapshot-safe symbol lists. Large Project
-- indexes should use a persistent compact index/artifact path rather than
-- copying the whole index into a worker for every query.

local common = require "core.common"
local native_fuzzy = require "fuzzy"

local worker = {}

local DEFAULT_QUERY_LIMIT = 200
local ARTIFACT_CACHE_MAX_BYTES = 256 * 1024 * 1024

local artifact_cache = {}
local artifact_cache_bytes = 0

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function load_lua_payload(path, remove_after_load)
  local loader, err = loadfile(path)
  if not loader then
    if remove_after_load then os.remove(path) end
    return nil, err or "artifact-load-failed"
  end
  local ok, artifact_payload = pcall(loader)
  if remove_after_load then os.remove(path) end
  if not ok or type(artifact_payload) ~= "table" then
    return nil, artifact_payload or "artifact-invalid"
  end
  return artifact_payload
end

local function load_payload_artifact(payload)
  local artifact = payload and payload.artifact
  local path = artifact and artifact.path
  if not path then return payload or {} end
  local artifact_payload, err = load_lua_payload(path, true)
  if not artifact_payload then return payload or {}, err end
  return artifact_payload
end

local function cache_weight(artifact, payload)
  return tonumber(artifact and artifact.bytes) or tonumber(payload and payload.bytes) or 0
end

local function trim_artifact_cache()
  if artifact_cache_bytes <= ARTIFACT_CACHE_MAX_BYTES then return end
  local oldest_key, oldest_at
  for key, entry in pairs(artifact_cache) do
    if not oldest_at or (entry.last_used or 0) < oldest_at then
      oldest_key, oldest_at = key, entry.last_used or 0
    end
  end
  if oldest_key then
    artifact_cache_bytes = math.max(0, artifact_cache_bytes - (artifact_cache[oldest_key].bytes or 0))
    artifact_cache[oldest_key] = nil
  end
end

local function load_cached_index_artifact(artifact, diagnostics)
  local path = artifact and artifact.path
  if not path then return nil end
  local entry = artifact_cache[path]
  if entry then
    entry.last_used = now()
    diagnostics.artifact_cache_hits = (diagnostics.artifact_cache_hits or 0) + 1
    return entry.payload
  end
  local artifact_payload, err = load_lua_payload(path, false)
  if not artifact_payload then return nil, err end
  local bytes = cache_weight(artifact, artifact_payload)
  artifact_cache[path] = { payload = artifact_payload, bytes = bytes, last_used = now() }
  artifact_cache_bytes = artifact_cache_bytes + bytes
  diagnostics.artifact_cache_misses = (diagnostics.artifact_cache_misses or 0) + 1
  trim_artifact_cache()
  return artifact_payload
end

local function append_index_artifact_symbols(out, artifact, diagnostics)
  if artifact and artifact.chunks then
    for _, chunk in ipairs(artifact.chunks) do append_index_artifact_symbols(out, chunk, diagnostics) end
    return
  end
  local path = artifact and artifact.path
  if not path then return end
  local artifact_payload, err = load_cached_index_artifact(artifact, diagnostics)
  if not artifact_payload then
    diagnostics.artifact_load_errors = (diagnostics.artifact_load_errors or 0) + 1
    diagnostics.last_artifact_load_error = err or "artifact-load-failed"
    diagnostics.last_artifact_load_path = path
    return
  end
  diagnostics.artifacts_loaded = (diagnostics.artifacts_loaded or 0) + 1
  for _, symbol in ipairs((artifact_payload and artifact_payload.symbols) or {}) do out[#out + 1] = symbol end
end

local function sort_symbols(symbols)
  table.sort(symbols, function(a, b)
    local af, bf = tostring(a.relpath or a.path or ""), tostring(b.relpath or b.path or "")
    if af ~= bf then return af < bf end
    if (a.start_line or 0) ~= (b.start_line or 0) then return (a.start_line or 0) < (b.start_line or 0) end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
end

function worker.run(payload, ctx)
  local payload_artifact_path = payload and payload.artifact and payload.artifact.path
  local payload_artifact_err
  payload, payload_artifact_err = load_payload_artifact(payload)
  local started = now()
  local query = tostring(payload.query or "")
  local limit = tonumber(payload.limit) or DEFAULT_QUERY_LIMIT
  local symbols = payload.symbols or {}
  local suppressed = {}
  for _, path in ipairs(payload.suppressed_paths or {}) do suppressed[path] = true end
  local diagnostics = {
    artifacts_loaded = 0,
    artifact_load_errors = payload_artifact_err and 1 or 0,
    artifact_cache_hits = 0,
    artifact_cache_misses = 0,
    last_artifact_load_error = payload_artifact_err,
    last_artifact_load_path = payload_artifact_err and payload_artifact_path or nil,
  }
  local matched = {}
  for _, artifact in ipairs(payload.index_artifacts or {}) do append_index_artifact_symbols(matched, artifact, diagnostics) end
  for _, symbol in ipairs(symbols) do matched[#matched + 1] = symbol end
  if next(suppressed) ~= nil then
    local filtered = {}
    for _, symbol in ipairs(matched) do
      if not suppressed[symbol.path] then filtered[#filtered + 1] = symbol end
    end
    matched = filtered
  end
  -- Open Document overlays are the replacement for suppressed disk entries;
  -- never run them through the same suppression pass or a clean Side Editor can
  -- erase both the stale disk symbol and its live replacement.
  for _, symbol in ipairs(payload.extra_symbols or {}) do matched[#matched + 1] = symbol end
  sort_symbols(matched)
  local input_count = #matched
  if query ~= "" then
    local texts = {}
    for i, symbol in ipairs(matched) do texts[i] = tostring(symbol.search_text or symbol.text or symbol.name or "") end
    local fuzzy_matches = native_fuzzy.filter(texts, query, {
      mode = "generic",
      limit = #texts,
      spans = false,
    })
    local ranked = {}
    for _, match in ipairs(fuzzy_matches or {}) do ranked[#ranked + 1] = matched[match.index] end
    matched = ranked
  end

  local out = {}
  for i = 1, math.min(limit, #matched) do out[i] = matched[i] end
  ctx.send({
    type = "result",
    payload = {
      symbols = out,
      has_more = #matched > #out,
      diagnostics = common.merge(diagnostics, {
        input_symbols = input_count,
        matched_symbols = #matched,
        returned_symbols = #out,
        query_ms = (now() - started) * 1000,
      }),
    },
  })
  ctx.send({
    type = "final",
    payload = {
      diagnostics = common.merge(diagnostics, {
        input_symbols = input_count,
        duration_ms = (now() - started) * 1000,
      }),
    },
  })
end

return worker
