local core = require "core"

local selection = {}

local MAX_NODE_RANGES = 128
local MAX_SELECTION_HISTORY = 32

local function log_quiet(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function empty(reason)
  return {}, reason
end

local function copy_list(list)
  local copy = {}
  for i = 1, #list do copy[i] = list[i] end
  return copy
end

local function line_starts(doc, ts)
  local change_id = doc.get_change_id and doc:get_change_id() or 0
  if ts.selection_line_starts and ts.selection_line_starts_change_id == change_id then
    return ts.selection_line_starts
  end
  local starts = {}
  local offset = 0
  for i = 1, #doc.lines do
    starts[i] = offset
    offset = offset + #doc.lines[i]
  end
  starts[#doc.lines + 1] = offset
  ts.selection_line_starts = starts
  ts.selection_line_starts_change_id = change_id
  return starts
end

local function is_utf8_continuation(byte)
  return byte and byte >= 0x80 and byte <= 0xbf
end

local function utf8_boundary(doc, line, col, direction)
  line, col = doc:sanitize_position(line, col)
  local text = doc.lines[line] or ""
  if col <= 1 or col > #text then return line, col end
  if not is_utf8_continuation(text:byte(col)) then return line, col end

  if direction == "forward" then
    while col < #text and is_utf8_continuation(text:byte(col)) do col = col + 1 end
    if is_utf8_continuation(text:byte(col)) then
      while col > 1 and is_utf8_continuation(text:byte(col)) do col = col - 1 end
    end
  else
    while col > 1 and is_utf8_continuation(text:byte(col)) do col = col - 1 end
  end
  return doc:sanitize_position(line, col)
end

local function sorted_selection(line1, col1, line2, col2)
  line2, col2 = line2 or line1, col2 or col1
  if line1 > line2 or (line1 == line2 and col1 > col2) then
    return line2, col2, line1, col1, true
  end
  return line1, col1, line2, col2, false
end

local function byte_offset(doc, ts, line, col)
  local starts = line_starts(doc, ts)
  line, col = doc:sanitize_position(line, col)
  return (starts[line] or 0) + col - 1
end

local function range_from_node(doc, node)
  local start_line, start_col = utf8_boundary(doc, node.start_line, node.start_col, "backward")
  local end_line, end_col = utf8_boundary(doc, node.end_line, node.end_col, "forward")
  return {
    type = node.type,
    named = node.named,
    start_line = start_line,
    start_col = start_col,
    end_line = end_line,
    end_col = end_col,
    start_byte = node.start_byte,
    end_byte = node.end_byte,
    range = {
      start = { line = start_line, col = start_col },
      ["end"] = { line = end_line, col = end_col },
    },
  }
end

local DELIMITER_PAIRS = { ["{"] = "}", ["("] = ")", ["["] = "]" }

local function delimiter_content_range(doc, node_range)
  if not doc or not node_range then return nil end
  local opening = doc:get_char(node_range.start_line, node_range.start_col)
  local expected_close = DELIMITER_PAIRS[opening]
  if not expected_close then return nil end
  local close_line, close_col = doc:position_offset(node_range.end_line, node_range.end_col, -1)
  local closing = doc:get_char(close_line, close_col)
  if closing ~= expected_close then return nil end
  local start_line, start_col = doc:position_offset(node_range.start_line, node_range.start_col, 1)
  local end_line, end_col = close_line, close_col
  local start_byte = (node_range.start_byte or 0) + 1
  local end_byte = (node_range.end_byte or 0) - 1
  if end_byte <= start_byte then return nil end
  return {
    type = tostring(node_range.type or "node") .. ".content",
    named = node_range.named,
    delimiter_content = true,
    start_line = start_line,
    start_col = start_col,
    end_line = end_line,
    end_col = end_col,
    start_byte = start_byte,
    end_byte = end_byte,
    range = {
      start = { line = start_line, col = start_col },
      ["end"] = { line = end_line, col = end_col },
    },
  }
end

local function tree_ready(ts)
  return ts and ts.native and ts.native.has_tree and ts.native:has_tree()
      and ts.status == "ready" and not ts.stale_unrenderable
end

function selection.get_node_ranges(doc, line1, col1, line2, col2, opts)
  opts = opts or {}
  if not doc or not doc.lines then return empty("no-document") end
  local ts = doc.treesitter
  if not ts then return empty("unsupported") end
  if not ts.native then return empty(ts.reason or ts.status or "disabled") end
  if not tree_ready(ts) then return empty("not-ready") end

  if not line1 or not col1 then line1, col1, line2, col2 = doc:get_selection(true) end
  if not line1 or not col1 then return empty("no-selection") end
  line1, col1 = utf8_boundary(doc, line1, col1, "backward")
  line2, col2 = utf8_boundary(doc, line2 or line1, col2 or col1, "forward")
  line1, col1, line2, col2 = sorted_selection(line1, col1, line2, col2)

  local start_byte = byte_offset(doc, ts, line1, col1)
  local end_byte = byte_offset(doc, ts, line2, col2)
  local nodes, err = ts.native:node_ranges(start_byte, end_byte, {
    named_only = opts.named_only ~= false,
    max_nodes = opts.max_nodes or MAX_NODE_RANGES,
  })
  if not nodes then
    log_quiet("Tree-sitter: node range query failed for %s: %s", doc.get_name and doc:get_name() or tostring(doc), tostring(err))
    return empty(err or "node-query-failed")
  end

  local ranges = {}
  for _, node in ipairs(nodes) do
    if node.end_byte and node.start_byte and node.end_byte > node.start_byte then
      local node_range = range_from_node(doc, node)
      local content_range = delimiter_content_range(doc, node_range)
      if content_range then ranges[#ranges + 1] = content_range end
      ranges[#ranges + 1] = node_range
    end
  end
  return ranges
end

function selection.get_current_node_ranges(opts)
  local view = core.active_view
  return selection.get_node_ranges(view and view.doc, nil, nil, nil, nil, opts)
end

local function node_strictly_expands(node, start_byte, end_byte)
  return node.start_byte <= start_byte and node.end_byte >= end_byte
      and (node.start_byte < start_byte or node.end_byte > end_byte)
end

local function choose_expansion(doc, ts, line1, col1, line2, col2)
  line1, col1, line2, col2 = sorted_selection(line1, col1, line2, col2)
  local start_byte = byte_offset(doc, ts, line1, col1)
  local end_byte = byte_offset(doc, ts, line2, col2)
  local ranges = selection.get_node_ranges(doc, line1, col1, line2, col2)
  for _, node in ipairs(ranges) do
    if node_strictly_expands(node, start_byte, end_byte) then return node end
  end
end

local function push_history(doc, ts)
  ts.selection_history = ts.selection_history or {}
  ts.selection_history[#ts.selection_history + 1] = {
    generation = ts.tree_generation,
    selections = copy_list(doc.selections or {}),
    last_selection = doc.last_selection,
  }
  if #ts.selection_history > MAX_SELECTION_HISTORY then table.remove(ts.selection_history, 1) end
end

function selection.expand_selection(doc)
  doc = doc or (core.active_view and core.active_view.doc)
  local ts = doc and doc.treesitter
  if not doc or not tree_ready(ts) then return false, "not-ready" end

  local next_selections = {}
  for _, line1, col1, line2, col2 in doc:get_selections(true) do
    local node = choose_expansion(doc, ts, line1, col1, line2, col2)
    if not node then return false, "no-larger-node" end
    next_selections[#next_selections + 1] = node.start_line
    next_selections[#next_selections + 1] = node.start_col
    next_selections[#next_selections + 1] = node.end_line
    next_selections[#next_selections + 1] = node.end_col
  end

  push_history(doc, ts)
  doc:set_selection_list(next_selections, doc.last_selection, { sanitized = true, merge_cursors = true })
  return true
end

function selection.shrink_selection(doc)
  doc = doc or (core.active_view and core.active_view.doc)
  local ts = doc and doc.treesitter
  if not doc or not ts or not ts.selection_history or #ts.selection_history == 0 then
    return false, "no-history"
  end
  local previous = table.remove(ts.selection_history)
  if previous.generation ~= ts.tree_generation then return false, "stale-history" end
  doc:set_selection_list(previous.selections, previous.last_selection, { sanitized = true, merge_cursors = true })
  return true
end

return selection
