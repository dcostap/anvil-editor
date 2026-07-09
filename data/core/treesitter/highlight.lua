local core = require "core"
local tokenizer = require "core.tokenizer"

local highlight = {}

local DEFAULT_MATCH_LIMIT = 50000
local DEFAULT_MAX_CAPTURES = 50000
local DEFAULT_QUERY_TIMEOUT_MS = 8
local MAX_FAILURES = 3

local capture_aliases = {
  attribute = "annotation",
  boolean = "constant.builtin",
  character = "string",
  conditional = "keyword",
  delimiter = "punctuation.delimiter",
  escape = "string.escape",
  field = "variable.field",
  float = "number",
  include = "keyword",
  label = "function.label",
  namespace = "type.namespace",
  parameter = "variable.parameter",
  preproc = "keyword",
  property = "variable.property",
  ["repeat"] = "keyword",
  spell = "comment",
  storageclass = "keyword",
  ["punctuation.bracket"] = "punctuation.bracket",
  ["punctuation.delimiter"] = "punctuation.delimiter",
}

local function log_quiet(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function capture_type(name)
  return capture_aliases[name] or name or "normal"
end

local function specificity(name)
  local count = 1
  for _ in tostring(name):gmatch("%.") do count = count + 1 end
  return count
end

local function ensure_line_starts(doc, ts)
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  if ts.line_starts and ts.line_starts_change_id == change_id then return ts.line_starts end
  local starts = {}
  local offset = 0
  for i = 1, #doc.lines do
    starts[i] = offset
    offset = offset + #doc.lines[i]
  end
  starts[#doc.lines + 1] = offset
  ts.line_starts = starts
  ts.line_starts_change_id = change_id
  return starts
end

local function tree_is_renderable(ts)
  if not ts or not ts.native or not ts.queries or not ts.queries.highlights then return false end
  if ts.highlight_disabled_reason then return false end
  if ts.stale_unrenderable then return false end
  if ts.status == "ready" then return ts.native:has_tree() end
  if ts.stale_renderable then return ts.native:has_tree() end
  return false
end

local function compare_capture(a, b)
  if not b then return true end
  local ap, bp = a.priority or 0, b.priority or 0
  if ap ~= bp then return ap > bp end
  local as, bs = specificity(a.type), specificity(b.type)
  if as ~= bs then return as > bs end
  local al, bl = (a.end_byte - a.start_byte), (b.end_byte - b.start_byte)
  if al ~= bl then return al < bl end
  local ao = (a.pattern_index or 0) * 1000000 + (a.capture_index or 0) * 1000 + (a.order or 0)
  local bo = (b.pattern_index or 0) * 1000000 + (b.capture_index or 0) * 1000 + (b.order or 0)
  return ao > bo
end

local function add_token(tokens, token_type, text)
  if text == "" then return end
  local n = #tokens
  if n >= 2 and tokens[n - 1] == token_type then
    tokens[n] = tokens[n] .. text
  else
    tokens[n + 1] = token_type
    tokens[n + 2] = text
  end
end

function highlight.resolve_line_tokens(text, line_start, line_end, captures)
  local boundaries = { line_start, line_end }
  local spans = {}
  for _, capture in ipairs(captures or {}) do
    local s = math.max(line_start, capture.start_byte or 0)
    local e = math.min(line_end, capture.end_byte or 0)
    if e > s then
      local span = {
        start_byte = s,
        end_byte = e,
        original_start = capture.start_byte,
        original_end = capture.end_byte,
        priority = tonumber(capture.priority) or 0,
        pattern_index = tonumber(capture.pattern_index) or 0,
        capture_index = tonumber(capture.capture_index) or 0,
        order = tonumber(capture.order) or 0,
        type = capture_type(capture.capture),
      }
      spans[#spans + 1] = span
      boundaries[#boundaries + 1] = s
      boundaries[#boundaries + 1] = e
    end
  end

  table.sort(boundaries)
  local unique = {}
  local last
  for _, boundary in ipairs(boundaries) do
    if boundary ~= last then
      unique[#unique + 1] = boundary
      last = boundary
    end
  end

  table.sort(spans, function(a, b)
    if a.start_byte ~= b.start_byte then return a.start_byte < b.start_byte end
    return compare_capture(a, b)
  end)

  local heap = {}
  local function heap_better(a, b) return compare_capture(a, b) end
  local function heap_push(item)
    local i = #heap + 1
    heap[i] = item
    while i > 1 do
      local parent = math.floor(i / 2)
      if not heap_better(heap[i], heap[parent]) then break end
      heap[i], heap[parent] = heap[parent], heap[i]
      i = parent
    end
  end
  local function heap_pop()
    local last_item = heap[#heap]
    heap[#heap] = nil
    if #heap == 0 then return end
    heap[1] = last_item
    local i = 1
    while true do
      local left, right = i * 2, i * 2 + 1
      if left > #heap then break end
      local best = left
      if right <= #heap and heap_better(heap[right], heap[left]) then best = right end
      if not heap_better(heap[best], heap[i]) then break end
      heap[i], heap[best] = heap[best], heap[i]
      i = best
    end
  end

  local tokens = {}
  local span_idx = 1
  for i = 1, #unique - 1 do
    local s, e = unique[i], unique[i + 1]
    while span_idx <= #spans and spans[span_idx].start_byte <= s do
      heap_push(spans[span_idx])
      span_idx = span_idx + 1
    end
    while heap[1] and heap[1].end_byte <= s do heap_pop() end
    if e > s then
      local winner = heap[1]
      local rel_s = s - line_start + 1
      local rel_e = e - line_start
      add_token(tokens, winner and winner.type or "normal", text:sub(rel_s, rel_e))
    end
  end

  if #tokens == 0 then
    tokens = { "normal", text or "" }
  end
  return tokens
end

function highlight.populate_range(doc, first_line, last_line)
  local ts = doc and doc.treesitter
  if not tree_is_renderable(ts) then return nil, "not-renderable" end
  first_line = math.max(1, math.floor(tonumber(first_line) or 1))
  last_line = math.min(#doc.lines, math.max(first_line, math.floor(tonumber(last_line) or first_line)))
  local starts = ensure_line_starts(doc, ts)
  local byte_start = starts[first_line]
  local byte_end = starts[last_line] + #(doc.lines[last_line] or "")
  if not byte_start then return nil, "no-line-start" end
  local captures, err = ts.native:query_captures(ts.queries.highlights, byte_start, byte_end, {
    match_limit = ts.language and ts.language.query_match_limit or DEFAULT_MATCH_LIMIT,
    max_captures = ts.language and ts.language.max_query_captures or DEFAULT_MAX_CAPTURES,
    timeout_ms = ts.language and ts.language.query_timeout_ms or DEFAULT_QUERY_TIMEOUT_MS,
  })
  ts.highlight_query_calls = (ts.highlight_query_calls or 0) + 1
  if not captures then
    ts.highlight_failures = (ts.highlight_failures or 0) + 1
    log_quiet("Tree-sitter: highlight range query failed for %s lines=%d-%d: %s",
      tostring(doc:get_name()), first_line, last_line, tostring(err))
    if ts.highlight_failures >= MAX_FAILURES then
      ts.highlight_disabled_reason = err or "highlight query failed repeatedly"
      log_quiet("Tree-sitter: disabled highlighting for %s: %s", tostring(doc:get_name()), tostring(ts.highlight_disabled_reason))
    end
    return nil, err or "query-failed"
  end
  ts.highlight_failures = 0

  local by_line = {}
  for _, capture in ipairs(captures) do
    local from = math.max(first_line, tonumber(capture.start_line) or first_line)
    local to = math.min(last_line, tonumber(capture.end_line) or from)
    for line_idx = from, to do
      local list = by_line[line_idx]
      if not list then list = {}; by_line[line_idx] = list end
      list[#list + 1] = capture
    end
  end
  local cache = ts.highlight_cache or {}
  ts.highlight_cache = cache
  for line_idx = first_line, last_line do
    local line = doc.lines[line_idx] or ""
    local key = table.concat({ tostring(line_idx), line }, "\0")
    local cached = cache[line_idx]
    if not (cached and cached.key == key) then
      local line_start = starts[line_idx]
      cache[line_idx] = {
        key = key,
        tokens = highlight.resolve_line_tokens(line, line_start, line_start + #line, by_line[line_idx] or {}),
      }
    end
  end
  return true
end

function highlight.line_tokens(doc, idx)
  local ts = doc and doc.treesitter
  if not tree_is_renderable(ts) then return nil, "not-renderable" end
  local line = doc.lines[idx]
  if not line then return nil, "no-line" end

  local cache = ts.highlight_cache or {}
  ts.highlight_cache = cache
  local key = table.concat({ tostring(idx), line }, "\0")
  local cached = cache[idx]
  if cached and cached.key == key then return cached.tokens, nil, "treesitter" end

  local ok, err = highlight.populate_range(doc, idx, math.min(#doc.lines, idx + 63))
  if not ok then return nil, err end
  cached = ts.highlight_cache and ts.highlight_cache[idx]
  return cached and cached.tokens or { "normal", line }, nil, "treesitter"
end

function highlight.invalidate_doc(doc, first_line, last_line)
  local ts = doc and doc.treesitter
  if not ts then return end
  ts.highlight_cache = ts.highlight_cache or {}
  if not first_line then
    ts.highlight_cache = {}
    ts.line_starts = nil
    return
  end
  last_line = last_line or first_line
  for i = first_line, last_line do
    ts.highlight_cache[i] = nil
  end
  ts.line_starts = nil
end

return highlight
