local core = require "core"

local outline = {}

local DEFAULT_MATCH_LIMIT = 20000
local DEFAULT_MAX_CAPTURES = 20000
local DEFAULT_QUERY_TIMEOUT_MS = 20

local function log_quiet(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function empty(reason)
  return {}, reason
end

local function line_starts(doc, ts)
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  if ts.outline_line_starts and ts.outline_line_starts_change_id == change_id then
    return ts.outline_line_starts
  end
  local starts = {}
  local offset = 0
  for i = 1, #doc.lines do
    starts[i] = offset
    offset = offset + #doc.lines[i]
  end
  starts[#doc.lines + 1] = offset
  ts.outline_line_starts = starts
  ts.outline_line_starts_change_id = change_id
  return starts
end

local function byte_len(doc, ts)
  local starts = line_starts(doc, ts)
  return starts[#doc.lines + 1] or 0
end

local function text_for_capture(doc, capture)
  if not doc or not capture then return "" end
  local start_line = capture.start_line or 1
  local end_line = capture.end_line or start_line
  local start_col = capture.start_col or 1
  local end_col = capture.end_col or start_col
  if start_line == end_line then
    local line = doc.lines[start_line] or ""
    return line:sub(start_col, math.max(start_col - 1, end_col - 1))
  end

  local parts = {}
  for line_idx = start_line, end_line do
    local line = doc.lines[line_idx] or ""
    if line_idx == start_line then
      parts[#parts + 1] = line:sub(start_col)
    elseif line_idx == end_line then
      parts[#parts + 1] = line:sub(1, math.max(0, end_col - 1))
    else
      parts[#parts + 1] = line
    end
  end
  return table.concat(parts)
end

local function trim_name(name)
  name = tostring(name or "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  return name:gsub("%s+", " ")
end

local function outline_kind(capture_name)
  return tostring(capture_name or ""):match("^outline%.(.+)$")
end

local function range_from_capture(capture)
  return {
    start = { line = capture.start_line, col = capture.start_col },
    ["end"] = { line = capture.end_line, col = capture.end_col },
  }
end

local function symbol_from_group(doc, group)
  if not group or not group.item or not group.name then return nil end
  local name = trim_name(text_for_capture(doc, group.name))
  if name == "" then return nil end
  local item = group.item
  return {
    name = name,
    kind = group.kind,
    start_line = item.start_line,
    start_col = item.start_col,
    end_line = item.end_line,
    end_col = item.end_col,
    start_byte = item.start_byte,
    end_byte = item.end_byte,
    range = range_from_capture(item),
    name_range = range_from_capture(group.name),
    children = {},
  }
end

local function compare_symbols(a, b)
  if a.start_byte ~= b.start_byte then return a.start_byte < b.start_byte end
  if a.end_byte ~= b.end_byte then return a.end_byte > b.end_byte end
  return a.name < b.name
end

local function contains(parent, child)
  if not parent or not child then return false end
  if parent == child then return false end
  return parent.start_byte <= child.start_byte and parent.end_byte >= child.end_byte
      and (parent.start_byte ~= child.start_byte or parent.end_byte ~= child.end_byte)
end

local function assign_parents(symbols)
  local stack = {}
  for i, symbol in ipairs(symbols) do
    symbol.index = i
    while #stack > 0 and not contains(stack[#stack], symbol) do
      stack[#stack] = nil
    end
    local parent = stack[#stack]
    if parent then
      symbol.parent = parent.index
      symbol.parent_name = parent.name
      symbol.depth = (parent.depth or 0) + 1
      parent.children[#parent.children + 1] = i
    else
      symbol.depth = 0
    end
    stack[#stack + 1] = symbol
  end
end

local function tree_ready(ts)
  return ts and ts.native and ts.native.has_tree and ts.native:has_tree()
      and ts.status == "ready" and not ts.stale_unrenderable
end

function outline.get_document_outline(doc, opts)
  opts = opts or {}
  if not doc or not doc.lines then return empty("no-document") end
  local ts = doc.treesitter
  if not ts then return empty("unsupported") end
  if not ts.native then return empty(ts.reason or ts.status or "disabled") end
  if not tree_ready(ts) then return empty("not-ready") end
  if not ts.queries or not ts.queries.outline then return empty("missing-query") end

  local captures, err = ts.native:query_captures(ts.queries.outline, 0, byte_len(doc, ts), {
    match_limit = opts.match_limit or (ts.language and ts.language.outline_match_limit) or DEFAULT_MATCH_LIMIT,
    max_captures = opts.max_captures or (ts.language and ts.language.outline_max_captures) or DEFAULT_MAX_CAPTURES,
    timeout_ms = opts.timeout_ms or (ts.language and ts.language.outline_query_timeout_ms) or DEFAULT_QUERY_TIMEOUT_MS,
  })
  if not captures then
    log_quiet("Tree-sitter: outline query failed for %s: %s", doc.get_name and doc:get_name() or tostring(doc), tostring(err))
    return empty(err or "query-failed")
  end

  local groups = {}
  for _, capture in ipairs(captures) do
    local match_id = capture.match_id or capture.order or 0
    local group = groups[match_id]
    if not group then
      group = {}
      groups[match_id] = group
    end
    local kind = outline_kind(capture.capture)
    if kind then
      if not group.item or (capture.end_byte - capture.start_byte) > (group.item.end_byte - group.item.start_byte) then
        group.item = capture
        group.kind = kind
      end
    elseif capture.capture == "name" then
      if not group.name or (capture.end_byte - capture.start_byte) < (group.name.end_byte - group.name.start_byte) then
        group.name = capture
      end
    end
  end

  local symbols = {}
  for _, group in pairs(groups) do
    local symbol = symbol_from_group(doc, group)
    if symbol then symbols[#symbols + 1] = symbol end
  end
  table.sort(symbols, compare_symbols)
  assign_parents(symbols)
  return symbols
end

function outline.get_current_document_outline(opts)
  local view = core.active_view
  return outline.get_document_outline(view and view.doc, opts)
end

return outline
