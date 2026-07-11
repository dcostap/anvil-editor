-- Converts native worker-pool Tree-sitter index result handles into the
-- worker-safe table shape historically returned by treesitter.index_text.
--
-- The native handle owns the full capture vectors. This adapter pulls bounded
-- slices when a Lua table is needed, keeping channel/result delivery bounded.

local common = require "core.common"

local adapter = {}

local DEFAULT_CAPTURE_CHUNK = 512

function adapter.capture_iterator(result_handle, kind, opts)
  opts = opts or {}
  local limit = math.max(1, math.floor(tonumber(opts.capture_chunk) or DEFAULT_CAPTURE_CHUNK))
  local offset = math.max(1, math.floor(tonumber(opts.offset) or 1))
  local chunk = nil
  local chunk_index = 1
  local exhausted = false

  return function()
    while not exhausted do
      if chunk and chunk_index <= #chunk then
        local capture = chunk[chunk_index]
        chunk_index = chunk_index + 1
        return capture
      end
      chunk = result_handle:captures(kind, { offset = offset, limit = limit })
      chunk_index = 1
      local next_offset = tonumber(chunk and chunk.next_offset) or (offset + #(chunk or {}))
      if not chunk or #chunk == 0 or next_offset <= offset then
        exhausted = true
        return nil
      end
      offset = next_offset
    end
  end
end

local function project_record_iterator(result_handle, method, opts)
  opts = opts or {}
  local limit = math.max(1, math.floor(tonumber(opts.record_chunk or opts.capture_chunk) or DEFAULT_CAPTURE_CHUNK))
  local offset = math.max(1, math.floor(tonumber(opts.offset) or 1))
  local chunk, chunk_index, exhausted
  return function()
    while not exhausted do
      if chunk and chunk_index <= #chunk then
        local record = chunk[chunk_index]
        chunk_index = chunk_index + 1
        return record
      end
      chunk = result_handle[method](result_handle, { offset = offset, limit = limit })
      chunk_index = 1
      local next_offset = tonumber(chunk and chunk.next_offset) or (offset + #(chunk or {}))
      if not chunk or #chunk == 0 or next_offset <= offset then
        exhausted = true
        return nil
      end
      offset = next_offset
    end
  end
end

local function query_from_summary(summary_query, result_handle, kind, opts)
  if not summary_query or summary_query.status == "absent" then return nil end
  opts = opts or {}
  local query = {
    capture_count = tonumber(summary_query.capture_count) or 0,
    exceeded_match_limit = summary_query.exceeded_match_limit and true or false,
    status = summary_query.status or "ready",
    error = summary_query.error,
  }
  if opts.lazy then
    query.capture_iter = function(iter_opts)
      return adapter.capture_iterator(result_handle, kind, common.merge(opts, iter_opts or {}))
    end
    return query
  end
  local captures = {}
  for capture in adapter.capture_iterator(result_handle, kind, opts) do
    captures[#captures + 1] = capture
  end
  query.captures = captures
  return query
end

function adapter.to_index_text_result(result_handle, opts)
  if not result_handle then return nil, "missing-native-result-handle" end
  local summary = result_handle:summary()
  if not summary then return nil, "missing-native-result-summary" end
  local metrics = summary.metrics or {}
  if metrics.parse_count == nil and metrics.parse_ms ~= nil then metrics.parse_count = 1 end
  local result = {
    language = summary.language,
    byte_len = summary.byte_len,
    metrics = metrics,
  }
  result.outline = query_from_summary(summary.outline, result_handle, "outline", opts)
  result.usage = query_from_summary(summary.usage, result_handle, "usage", opts)
  if summary.project then
    result.project = {
      path = summary.project.path,
      relpath = summary.project.relpath,
      symbol_count = tonumber(summary.project.symbol_count) or 0,
      usage_count = tonumber(summary.project.usage_count) or 0,
      symbol_iter = function(iter_opts)
        return project_record_iterator(result_handle, "symbols", common.merge(opts, iter_opts or {}))
      end,
      usage_iter = function(iter_opts)
        return project_record_iterator(result_handle, "usages", common.merge(opts, iter_opts or {}))
      end,
    }
  end
  return result
end

return adapter
