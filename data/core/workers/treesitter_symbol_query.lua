-- Worker-side Project symbol query job.
--
-- This is intentionally for compact/snapshot-safe symbol lists. Large Project
-- indexes should use a persistent compact index/artifact path rather than
-- copying the whole index into a worker for every query.

local common = require "core.common"
local native_fuzzy = require "fuzzy"

local worker = {}

local DEFAULT_QUERY_LIMIT = 200

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

local function append_index_artifact_symbols(out, artifact)
  local path = artifact and artifact.path
  if not path then return end
  local artifact_payload = load_lua_payload(path, false)
  for _, symbol in ipairs((artifact_payload and artifact_payload.symbols) or {}) do out[#out + 1] = symbol end
end

local function now()
  return system and system.get_time and system.get_time() or os.clock()
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
  payload = load_payload_artifact(payload)
  local started = now()
  local query = tostring(payload.query or "")
  local limit = tonumber(payload.limit) or DEFAULT_QUERY_LIMIT
  local symbols = payload.symbols or {}
  local suppressed = {}
  for _, path in ipairs(payload.suppressed_paths or {}) do suppressed[path] = true end
  local matched = {}
  for _, artifact in ipairs(payload.index_artifacts or {}) do append_index_artifact_symbols(matched, artifact) end
  for _, symbol in ipairs(symbols) do matched[#matched + 1] = symbol end
  for _, symbol in ipairs(payload.extra_symbols or {}) do matched[#matched + 1] = symbol end
  if next(suppressed) ~= nil then
    local filtered = {}
    for _, symbol in ipairs(matched) do
      if not suppressed[symbol.path] then filtered[#filtered + 1] = symbol end
    end
    matched = filtered
  end
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
      diagnostics = {
        input_symbols = input_count,
        matched_symbols = #matched,
        returned_symbols = #out,
        query_ms = (now() - started) * 1000,
      },
    },
  })
  ctx.send({
    type = "final",
    payload = {
      diagnostics = {
        input_symbols = input_count,
        duration_ms = (now() - started) * 1000,
      },
    },
  })
end

return worker
