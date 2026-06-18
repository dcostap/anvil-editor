local core = require "core"
local outline = require "core.treesitter.outline"

local navigation = {}

local NAVIGABLE_KINDS = {
  namespace = true,
  class = true,
  struct = true,
  union = true,
  enum = true,
  ["function"] = true,
  method = true,
}

local function empty(reason)
  return nil, reason
end

local function line_starts(doc, ts)
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  if ts.navigation_line_starts and ts.navigation_line_starts_change_id == change_id then
    return ts.navigation_line_starts
  end
  local starts = {}
  local offset = 0
  for i = 1, #doc.lines do
    starts[i] = offset
    offset = offset + #doc.lines[i]
  end
  starts[#doc.lines + 1] = offset
  ts.navigation_line_starts = starts
  ts.navigation_line_starts_change_id = change_id
  return starts
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

local function selection_bytes(doc, ts, line1, col1, line2, col2)
  if not line1 or not col1 then line1, col1, line2, col2 = doc:get_selection(true) end
  if not line1 or not col1 then return nil end
  line1, col1, line2, col2 = sorted_selection(line1, col1, line2, col2)
  return byte_offset(doc, ts, line1, col1), byte_offset(doc, ts, line2, col2)
end

local function get_symbols(doc, opts)
  local symbols, reason = outline.get_document_outline(doc, opts)
  if not symbols or #symbols == 0 then return {}, reason or "no-symbols" end
  local filtered = {}
  for _, symbol in ipairs(symbols) do
    if NAVIGABLE_KINDS[symbol.kind] and symbol.name_range then
      filtered[#filtered + 1] = symbol
    end
  end
  if #filtered == 0 then return {}, "no-navigable-symbols" end
  return filtered
end

local function contains(symbol, start_byte, end_byte)
  return symbol.start_byte <= start_byte and symbol.end_byte >= end_byte
end

local function symbol_start(symbol)
  return symbol.name_range and symbol.name_range.start or symbol.range and symbol.range.start
end

local function symbol_end(symbol)
  return symbol.name_range and symbol.name_range["end"] or symbol.range and symbol.range["end"]
end

function navigation.get_enclosing_symbol(doc, line1, col1, line2, col2, opts)
  if not doc or not doc.lines then return empty("no-document") end
  local ts = doc.treesitter
  if not ts then return empty("unsupported") end
  local start_byte, end_byte = selection_bytes(doc, ts, line1, col1, line2, col2)
  if not start_byte then return empty("no-selection") end
  local symbols, reason = get_symbols(doc, opts)
  if #symbols == 0 then return empty(reason) end

  local best
  for _, symbol in ipairs(symbols) do
    if contains(symbol, start_byte, end_byte) then
      if not best or (symbol.end_byte - symbol.start_byte) < (best.end_byte - best.start_byte) then
        best = symbol
      end
    end
  end
  return best or empty("no-enclosing-symbol")
end

function navigation.get_next_symbol(doc, line, col, opts)
  if not doc or not doc.lines then return empty("no-document") end
  local ts = doc.treesitter
  if not ts then return empty("unsupported") end
  if not line or not col then line, col = doc:get_selection(true) end
  if not line or not col then return empty("no-selection") end
  local cursor_byte = byte_offset(doc, ts, line, col)
  local symbols, reason = get_symbols(doc, opts)
  if #symbols == 0 then return empty(reason) end

  for _, symbol in ipairs(symbols) do
    local target = symbol.name_range and symbol.name_range.start
    local target_byte = target and byte_offset(doc, ts, target.line, target.col) or symbol.start_byte
    if target_byte > cursor_byte then return symbol end
  end
  return empty("no-next-symbol")
end

function navigation.get_previous_symbol(doc, line, col, opts)
  if not doc or not doc.lines then return empty("no-document") end
  local ts = doc.treesitter
  if not ts then return empty("unsupported") end
  if not line or not col then line, col = doc:get_selection(true) end
  if not line or not col then return empty("no-selection") end
  local cursor_byte = byte_offset(doc, ts, line, col)
  local symbols, reason = get_symbols(doc, opts)
  if #symbols == 0 then return empty(reason) end

  local previous
  for _, symbol in ipairs(symbols) do
    local target = symbol.name_range and symbol.name_range.start
    local target_byte = target and byte_offset(doc, ts, target.line, target.col) or symbol.start_byte
    if target_byte >= cursor_byte then break end
    previous = symbol
  end
  return previous or empty("no-previous-symbol")
end

local function select_symbol(doc, symbol)
  if not doc or not symbol then return false end
  local start = symbol_start(symbol)
  local finish = symbol_end(symbol)
  if not start or not finish then return false end
  doc:set_selection(start.line, start.col, finish.line, finish.col)
  return true
end

function navigation.goto_enclosing_symbol(doc)
  doc = doc or (core.active_view and core.active_view.doc)
  local symbol, reason = navigation.get_enclosing_symbol(doc)
  if not symbol then return false, reason end
  return select_symbol(doc, symbol)
end

function navigation.goto_next_symbol(doc)
  doc = doc or (core.active_view and core.active_view.doc)
  local symbol, reason = navigation.get_next_symbol(doc)
  if not symbol then return false, reason end
  return select_symbol(doc, symbol)
end

function navigation.goto_previous_symbol(doc)
  doc = doc or (core.active_view and core.active_view.doc)
  local symbol, reason = navigation.get_previous_symbol(doc)
  if not symbol then return false, reason end
  return select_symbol(doc, symbol)
end

return navigation
