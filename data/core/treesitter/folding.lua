local common = require "core.common"
local selection = require "core.treesitter.selection"

local folding = {}

local ROOT_NODE_TYPES = {
  source_file = true,
  translation_unit = true,
}

local function empty(reason)
  return nil, reason
end

local function clamp_line(doc, line)
  return common.clamp(math.floor(tonumber(line) or 1), 1, #doc.lines)
end

local function normalize_query_position(doc, line1, col1, line2, col2)
  if not line1 or not col1 then line1, col1, line2, col2 = doc:get_selection(true) end
  if not line1 or not col1 then return nil end
  line2, col2 = line2 or line1, col2 or col1
  if line1 ~= line2 or col1 ~= col2 then return line1, col1, line2, col2 end

  line1, col1 = doc:sanitize_position(line1, col1)
  local text = doc.lines[line1] or ""
  local first_non_whitespace = text:find("%S")
  if first_non_whitespace and col1 <= first_non_whitespace then
    col1 = first_non_whitespace
  end
  return line1, col1, line1, col1
end

local function range_to_fold_target(doc, node)
  if not doc or not doc.lines or not node then return nil end
  local line1 = clamp_line(doc, node.start_line)
  local line2 = clamp_line(doc, node.end_line)
  local end_col = tonumber(node.end_col) or 1
  if end_col <= 1 then line2 = math.max(line1, line2 - 1) end
  if line2 <= line1 then return nil end

  local col1 = tonumber(node.start_col) or 1
  local col2
  if line2 == clamp_line(doc, node.end_line) and end_col > 1 then
    col2 = end_col
  else
    col2 = #(doc.lines[line2] or "") + 1
  end

  return {
    line1 = line1,
    col1 = common.clamp(col1, 1, #(doc.lines[line1] or "") + 1),
    line2 = line2,
    col2 = common.clamp(col2, 1, #(doc.lines[line2] or "") + 1),
    kind = "syntax",
    metadata = {
      provider = "treesitter",
      node_type = node.type,
      start_byte = node.start_byte,
      end_byte = node.end_byte,
    },
  }
end

local function is_foldable_node(node)
  if not node or node.delimiter_content then return false end
  local node_type = tostring(node.type or "")
  if node_type == "ERROR" or node_type == "MISSING" or node_type:match("^MISSING[%s_]") then return false end
  if ROOT_NODE_TYPES[node.type] then return false end
  if not node.start_line or not node.end_line then return false end
  return true
end

function folding.get_fold_target(doc, line1, col1, line2, col2, opts)
  if not doc or not doc.lines then return empty("no-document") end
  line1, col1, line2, col2 = normalize_query_position(doc, line1, col1, line2, col2)
  if not line1 then return empty("no-selection") end
  local ranges, reason = selection.get_node_ranges(doc, line1, col1, line2, col2, opts)
  if not ranges or #ranges == 0 then return empty(reason or "no-node-ranges") end

  for _, node in ipairs(ranges) do
    if is_foldable_node(node) then
      local target = range_to_fold_target(doc, node)
      if target then return target end
    end
  end
  return empty("no-foldable-node")
end

return folding
