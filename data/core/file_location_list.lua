-- Compact file locations for worker results. Expand a record only when a caller needs it.
local has_buffer, buffer = pcall(require, "string.buffer")
local list = {}

local function before(a, b)
  if a.line ~= b.line then return a.line < b.line end
  if a.col ~= b.col then return a.col < b.col end
  if a.line2 ~= b.line2 then return a.line2 < b.line2 end
  return a.col2 < b.col2
end

function list.new(candidates, root, kind, cancelled)
  local locations = require "core.text_poi_locations"
  -- Parsing normally supplies ordered candidates. Preserve that order without another full sort.
  for i = 2, #candidates do
    if before(candidates[i], candidates[i - 1]) then
      local ordered = {}
      for j, candidate in ipairs(candidates) do ordered[j] = candidate end
      table.sort(ordered, before)
      candidates = ordered
      break
    end
  end
  local data = {
    kind = kind, lines = {}, cols = {}, end_lines = {}, end_cols = {},
    target_lines = {}, target_cols = {}, target_ids = {}, targets = {},
  }
  local paths, target_ids = {}, {}
  for _, candidate in ipairs(candidates) do
    if cancelled and cancelled() then return nil end
    local source = candidate.source_path
    local path = paths[source]
    if path == nil then
      path = locations.resolve_path(source, root) or false
      paths[source] = path
    end
    if path then
      local label = candidate.label or path
      local labels = target_ids[path]
      if not labels then labels = {}; target_ids[path] = labels end
      local id = labels[label]
      if not id then
        id = #data.targets + 1
        labels[label] = id
        data.targets[id] = { path = path, label = label }
      end
      local n = #data.lines + 1
      data.lines[n], data.cols[n] = candidate.line, candidate.col
      data.end_lines[n], data.end_cols[n] = candidate.line2, candidate.col2
      data.target_lines[n], data.target_cols[n] = candidate.target_line, candidate.target_col
      data.target_ids[n] = id
    end
  end
  return data
end

-- The binary codec avoids a channel allocation for every numeric key and value.
-- Runtimes without this codec pass the same data as tables.
function list.encode(data)
  return has_buffer and buffer.encode(data) or data
end

function list.decode(data)
  return type(data) == "string" and buffer.decode(data) or data
end

function list.count(data)
  return data and #data.lines or 0
end

function list.point(data, index)
  if not data or not data.lines[index] then return nil end
  local target = data.targets[data.target_ids[index]]
  return {
    line = data.lines[index], col = data.cols[index],
    line2 = data.end_lines[index], col2 = data.end_cols[index],
    target_line = data.target_lines[index], target_col = data.target_cols[index],
    path = target.path, label = target.label, kind = data.kind, text_bounds = true,
  }
end

function list.points(data)
  local points = {}
  for i = 1, #data.lines do points[i] = list.point(data, i) end
  return points
end

function list.at(data, line, col)
  for i = 1, list.count(data) do
    local first_line, first_col = data.lines[i], data.cols[i]
    if first_line > line or first_line == line and first_col > col then break end
    local last_line, last_col = data.end_lines[i], data.end_cols[i]
    if last_line > line or last_line == line and last_col > col then
      return list.point(data, i)
    end
  end
end

function list.next(data, direction, line, col)
  if not data or #data.lines == 0 then return nil, "empty" end
  local first, last = 1, #data.lines
  while first <= last do
    local middle = math.floor((first + last) / 2)
    local row, column = data.lines[middle], data.cols[middle]
    if row < line or row == line and (column < col or direction > 0 and column == col) then
      first = middle + 1
    else
      last = middle - 1
    end
  end
  local point = list.point(data, direction > 0 and first or last)
  return point, not point and "boundary" or nil
end

return list
