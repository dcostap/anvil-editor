-- Worker-side Project usage query job.
--
-- This is intentionally for compact/snapshot-safe usage lists. Large Project
-- indexes should use a persistent compact index/artifact path rather than
-- copying broad usage tables into a worker for every query.

local common = require "core.common"

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

local function append_index_artifact_usages(out, artifact, name, diagnostics)
  if artifact and artifact.chunks then
    for _, chunk in ipairs(artifact.chunks) do append_index_artifact_usages(out, chunk, name, diagnostics) end
    return
  end
  local path = artifact and artifact.path
  if not path then return end
  local artifact_payload, err = load_lua_payload(path, false)
  if not artifact_payload then
    diagnostics.artifact_load_errors = (diagnostics.artifact_load_errors or 0) + 1
    diagnostics.last_artifact_load_error = err or "artifact-load-failed"
    diagnostics.last_artifact_load_path = path
    return
  end
  diagnostics.artifacts_loaded = (diagnostics.artifacts_loaded or 0) + 1
  for _, usage in ipairs((artifact_payload and artifact_payload.usages) or {}) do out[#out + 1] = usage end
  for _, usage in ipairs(((artifact_payload and artifact_payload.usages_by_name) or {})[name] or {}) do out[#out + 1] = usage end
end

local function now()
  return system and system.get_time and system.get_time() or os.clock()
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

function worker.run(payload, ctx)
  payload = load_payload_artifact(payload)
  local started = now()
  local diagnostics = {
    artifacts_loaded = 0,
    artifact_load_errors = 0,
  }
  local usages = {}
  local suppressed = {}
  for _, path in ipairs(payload.suppressed_paths or {}) do suppressed[path] = true end
  local name = tostring(payload.name or "")
  for _, artifact in ipairs(payload.index_artifacts or {}) do append_index_artifact_usages(usages, artifact, name, diagnostics) end
  for _, usage in ipairs(payload.usages or {}) do usages[#usages + 1] = usage end
  for _, usage in ipairs(payload.extra_usages or {}) do usages[#usages + 1] = usage end
  if next(suppressed) ~= nil then
    local filtered = {}
    for _, usage in ipairs(usages) do
      if not suppressed[usage.path] then filtered[#filtered + 1] = usage end
    end
    usages = filtered
  end
  local include_declaration = payload.include_declaration ~= false
  local limit = tonumber(payload.limit) or DEFAULT_QUERY_LIMIT
  sort_usages(usages)

  local out = {}
  local has_more = false
  local matched = 0
  for _, usage in ipairs(usages) do
    if include_declaration or not usage.is_declaration then
      matched = matched + 1
      if #out < limit then
        out[#out + 1] = usage
      else
        has_more = true
      end
    end
  end

  ctx.send({
    type = "result",
    payload = {
      usages = out,
      has_more = has_more,
      diagnostics = common.merge(diagnostics, {
        input_usages = #usages,
        matched_usages = matched,
        returned_usages = #out,
        query_ms = (now() - started) * 1000,
      }),
    },
  })
  ctx.send({
    type = "final",
    payload = {
      diagnostics = common.merge(diagnostics, {
        input_usages = #usages,
        duration_ms = (now() - started) * 1000,
      }),
    },
  })
end

return worker
