local core = require "core"
local outline = require "core.treesitter.outline"

-- Local Tree-sitter fallback symbol helpers.
--
-- These APIs are intentionally current-document and syntactic only. They use the
-- bundled locals.scm query to find identifier-shaped definitions/references, but
-- they do not attempt C/C++ semantic resolution for macros, includes, templates,
-- overloads, types, or build configuration. LSP should eventually supersede this
-- for semantic go-to-definition and references.

local locals = {}

local DEFAULT_MATCH_LIMIT = 50000
local DEFAULT_MAX_CAPTURES = 50000
local DEFAULT_QUERY_TIMEOUT_MS = 20

local function log_quiet(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function empty(reason)
  return nil, reason
end

local function empty_list(reason)
  return {}, reason
end

local function line_starts(doc, ts)
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  if ts.locals_line_starts and ts.locals_line_starts_change_id == change_id then
    return ts.locals_line_starts
  end
  local starts = {}
  local offset = 0
  for i = 1, #doc.lines do
    starts[i] = offset
    offset = offset + #doc.lines[i]
  end
  starts[#doc.lines + 1] = offset
  ts.locals_line_starts = starts
  ts.locals_line_starts_change_id = change_id
  return starts
end

local function byte_len(doc, ts)
  local starts = line_starts(doc, ts)
  return starts[#doc.lines + 1] or 0
end

local function byte_offset(doc, ts, line, col)
  local starts = line_starts(doc, ts)
  line, col = doc:sanitize_position(line, col)
  return (starts[line] or 0) + col - 1
end

local function sorted_selection(line1, col1, line2, col2)
  line2, col2 = line2 or line1, col2 or col1
  if line1 > line2 or (line1 == line2 and col1 > col2) then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end

local function capture_text(doc, capture)
  return doc:get_text(capture.start_line, capture.start_col, capture.end_line, capture.end_col)
end

local function capture_kind(capture_name)
  return tostring(capture_name or ""):match("^definition%.(.+)$")
end

local function is_definition(capture)
  return capture_kind(capture.capture) ~= nil
end

local function is_symbol_capture(capture)
  return is_definition(capture) or capture.capture == "reference"
end

local function range_len(capture)
  return (capture.end_byte or 0) - (capture.start_byte or 0)
end

local function tree_ready(ts)
  return ts and ts.native and ts.native.has_tree and ts.native:has_tree()
      and ts.status == "ready" and not ts.stale_unrenderable
end

local function range_from_capture(capture)
  return {
    start = { line = capture.start_line, col = capture.start_col },
    ["end"] = { line = capture.end_line, col = capture.end_col },
  }
end

local function item_from_capture(doc, capture)
  return {
    name = capture_text(doc, capture),
    kind = capture_kind(capture.capture) or "reference",
    capture = capture.capture,
    start_line = capture.start_line,
    start_col = capture.start_col,
    end_line = capture.end_line,
    end_col = capture.end_col,
    start_byte = capture.start_byte,
    end_byte = capture.end_byte,
    range = range_from_capture(capture),
  }
end

local function query_captures(doc, opts)
  opts = opts or {}
  if not doc or not doc.lines then return empty_list("no-document") end
  local ts = doc.treesitter
  if not ts then return empty_list("unsupported") end
  if not ts.native then return empty_list(ts.reason or ts.status or "disabled") end
  if not tree_ready(ts) then return empty_list("not-ready") end
  if not ts.queries or not ts.queries.locals then return empty_list("missing-query") end

  local captures, err = ts.native:query_captures(ts.queries.locals, 0, byte_len(doc, ts), {
    match_limit = opts.match_limit or (ts.language and ts.language.locals_match_limit) or DEFAULT_MATCH_LIMIT,
    max_captures = opts.max_captures or (ts.language and ts.language.locals_max_captures) or DEFAULT_MAX_CAPTURES,
    timeout_ms = opts.timeout_ms or (ts.language and ts.language.locals_query_timeout_ms) or DEFAULT_QUERY_TIMEOUT_MS,
  })
  if not captures then
    log_quiet("Tree-sitter: local symbol query failed for %s: %s", doc.get_name and doc:get_name() or tostring(doc), tostring(err))
    return empty_list(err or "query-failed")
  end
  return captures
end

local function dedupe_items(items)
  local result, seen = {}, {}
  for _, item in ipairs(items) do
    local key = table.concat({ item.name or "", item.start_byte or 0, item.end_byte or 0 }, "\0")
    if not seen[key] then
      seen[key] = true
      result[#result + 1] = item
    end
  end
  table.sort(result, function(a, b)
    if a.start_byte ~= b.start_byte then return a.start_byte < b.start_byte end
    if a.end_byte ~= b.end_byte then return a.end_byte < b.end_byte end
    return tostring(a.capture) < tostring(b.capture)
  end)
  return result
end

local function target_at(doc, captures, start_byte, end_byte)
  local best
  for _, capture in ipairs(captures) do
    if is_symbol_capture(capture) and capture.start_byte <= start_byte and capture.end_byte >= end_byte then
      if not best or range_len(capture) < range_len(best) or (range_len(capture) == range_len(best) and is_definition(capture)) then
        best = capture
      end
    end
  end
  return best
end

local function symbol_contains(symbol, start_byte, end_byte)
  return symbol and symbol.start_byte <= start_byte and symbol.end_byte >= end_byte
end

local function enclosing_outline_symbol(doc, start_byte, end_byte)
  local symbols = outline.get_document_outline(doc)
  local best
  for _, symbol in ipairs(symbols or {}) do
    if symbol_contains(symbol, start_byte, end_byte) then
      if not best or (symbol.end_byte - symbol.start_byte) < (best.end_byte - best.start_byte) then
        best = symbol
      end
    end
  end
  return best
end

local function in_scope(capture, scope)
  if not scope then return true end
  return capture.start_byte >= scope.start_byte and capture.end_byte <= scope.end_byte
end

local function find_definition(doc, captures, name, target, scope)
  local local_defs, global_defs = {}, {}
  for _, capture in ipairs(captures) do
    if is_definition(capture) and capture_text(doc, capture) == name then
      local item = item_from_capture(doc, capture)
      if in_scope(capture, scope) then
        local_defs[#local_defs + 1] = item
      else
        global_defs[#global_defs + 1] = item
      end
    end
  end

  local_defs = dedupe_items(local_defs)
  global_defs = dedupe_items(global_defs)
  local best
  for _, item in ipairs(local_defs) do
    if item.start_byte <= target.start_byte and (not best or item.start_byte > best.start_byte) then
      best = item
    end
  end
  if best then return best, scope end
  if #local_defs > 0 then return local_defs[1], scope end
  if #global_defs > 0 then return global_defs[1], nil end
end

local function target_context(doc, line1, col1, line2, col2, opts)
  if not doc or not doc.lines then return nil, nil, nil, "no-document" end
  local ts = doc.treesitter
  if not ts then return nil, nil, nil, "unsupported" end
  if not line1 or not col1 then line1, col1, line2, col2 = doc:get_selection(true) end
  if not line1 or not col1 then return nil, nil, nil, "no-selection" end
  line1, col1, line2, col2 = sorted_selection(line1, col1, line2, col2)
  local start_byte = byte_offset(doc, ts, line1, col1)
  local end_byte = byte_offset(doc, ts, line2, col2)
  local captures, reason = query_captures(doc, opts)
  if #captures == 0 then return nil, nil, nil, reason end
  local target = target_at(doc, captures, start_byte, end_byte)
  if not target then return nil, nil, nil, "no-symbol" end
  local name = capture_text(doc, target)
  local scope = enclosing_outline_symbol(doc, target.start_byte, target.end_byte)
  return captures, item_from_capture(doc, target), scope, nil, name
end

function locals.get_document_symbols(doc, opts)
  local captures, reason = query_captures(doc, opts)
  if #captures == 0 then return empty_list(reason) end
  local items = {}
  local seen = {}
  for _, capture in ipairs(captures) do
    if is_definition(capture) then
      local item = item_from_capture(doc, capture)
      local key = table.concat({ item.name or "", item.kind or "" }, "\0")
      if item.name ~= "" and not seen[key] then
        seen[key] = true
        items[#items + 1] = item
      end
    end
  end
  table.sort(items, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.kind ~= b.kind then return tostring(a.kind) < tostring(b.kind) end
    return (a.start_byte or 0) < (b.start_byte or 0)
  end)
  return items
end

function locals.get_local_definition(doc, line1, col1, line2, col2, opts)
  local captures, target, scope, reason, name = target_context(doc, line1, col1, line2, col2, opts)
  if not captures then return empty(reason) end
  local definition, definition_scope = find_definition(doc, captures, name, target, scope)
  if not definition then return empty("no-local-definition") end
  definition.scope = definition_scope
  definition.target = target
  definition.local_tree_sitter_fallback = true
  return definition
end

function locals.get_local_references(doc, line1, col1, line2, col2, opts)
  local captures, target, scope, reason, name = target_context(doc, line1, col1, line2, col2, opts)
  if not captures then return empty_list(reason) end
  local definition, definition_scope = find_definition(doc, captures, name, target, scope)
  local ref_scope = definition_scope or scope
  local items = {}
  for _, capture in ipairs(captures) do
    if is_symbol_capture(capture) and capture_text(doc, capture) == name and in_scope(capture, ref_scope) then
      items[#items + 1] = item_from_capture(doc, capture)
    end
  end
  items = dedupe_items(items)
  for _, item in ipairs(items) do
    item.definition = definition
    item.scope = ref_scope
    item.local_tree_sitter_fallback = true
  end
  if #items == 0 then return empty_list("no-local-references") end
  return items
end

local function select_item(doc, item)
  if not doc or not item then return false end
  doc:set_selection(item.start_line, item.start_col, item.end_line, item.end_col)
  return true
end

function locals.goto_local_definition(doc)
  doc = doc or (core.active_view and core.active_view.doc)
  local definition, reason = locals.get_local_definition(doc)
  if not definition then return false, reason end
  return select_item(doc, definition)
end

function locals.goto_local_declaration(doc)
  return locals.goto_local_definition(doc)
end

function locals.select_local_references(doc)
  doc = doc or (core.active_view and core.active_view.doc)
  local references, reason = locals.get_local_references(doc)
  if not references or #references == 0 then return false, reason end
  local selections = {}
  for _, ref in ipairs(references) do
    selections[#selections + 1] = ref.start_line
    selections[#selections + 1] = ref.start_col
    selections[#selections + 1] = ref.end_line
    selections[#selections + 1] = ref.end_col
  end
  doc:set_selection_list(selections, doc.last_selection, { sanitized = true, merge_cursors = true })
  return true
end

return locals
