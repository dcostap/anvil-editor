local projection = {}

function projection.ordered_changed_ranges(transaction)
  local ranges = {}
  for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
    ranges[#ranges + 1] = range
  end
  table.sort(ranges, function(left, right)
    return (left.old_line1 or left.new_line1 or 1)
      < (right.old_line1 or right.new_line1 or 1)
  end)
  return ranges
end

function projection.map_unchanged_line(ranges, old_line)
  local delta = 0
  for _, range in ipairs(ranges) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    if old_line < old_line1 then return old_line + delta end
    if old_line <= old_line2 then return nil end
    delta = delta + (range.line_delta or 0)
  end
  return old_line + delta
end

local function list_marker(text)
  text = tostring(text or ""):gsub("\n$", "")
  return text:match("^[\t ]*[-%*%+][\t ]+") ~= nil
    or text:match("^[\t ]*%d+[.)][\t ]+") ~= nil
end

local function atx_heading_content(text)
  local indent, marks, content = tostring(text or ""):match("^( *)(#+)[ \t]+(.*)$")
  if marks and #indent <= 3 and #marks <= 6 then return content end
end

local function link_target_signature(text)
  text = tostring(text or ""):gsub("\n$", "")
  if list_marker(text) then return "" end
  local body = atx_heading_content(text)
  if body and body ~= "" then return "heading:" .. body end
  local setext = text:match("^%s*([=%-]+)%s*$")
  if setext then return "setext:" .. setext:sub(1, 1) end
  local block = text:match("%^([%w_-]+)%s*$")
  if block then return "block:" .. block end
  local label, target = text:match("^%s*%[([^%]]+)%]:%s*(.-)%s*$")
  if label then return "reference:" .. label:lower() .. ":" .. target end
  return ""
end

function projection.transaction_changes_link_targets(buffer, transaction, pre_edit_lines)
  for _, range in ipairs(projection.ordered_changed_ranges(transaction)) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    local new_line1 = range.new_line1 or old_line1
    local new_line2 = range.new_line2 or new_line1
    for line = old_line1, old_line2 do
      local previous = pre_edit_lines and pre_edit_lines[line]
      if previous and link_target_signature(previous.source_text) ~= "" then
        return true
      end
    end
    for line = new_line1, new_line2 do
      if link_target_signature(buffer.lines[line]) ~= "" then return true end
    end
  end
  return false
end

return projection
