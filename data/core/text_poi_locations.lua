local common = require "core.common"

local locations = {}

local function is_uri_like_path(path)
  path = tostring(path or "")
  if path:match("^%a[%w+.-]*://") then return true end
  return path:match("^%a[%w+.-]*:") ~= nil and not path:match("^%a:[/\\]")
end

local function clean_path(path)
  path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
  path = path:gsub("^[\"']", ""):gsub("[\"']$", "")
  path = path:gsub("^[%-%>:%s]+", ""):gsub("[%s,;]+$", "")
  while #path > 1 and path:match("[%.%)]$") do path = path:sub(1, -2) end
  return path
end

local function existing_file(path)
  local info = path and system.get_file_info(path)
  return info and info.type ~= "dir"
end

function locations.resolve_path(path, root)
  path = clean_path(path)
  if path == "" or is_uri_like_path(path) then return nil end
  local ok, candidate = pcall(function()
    return common.is_absolute_path(path)
      and common.normalize_path(path)
      or common.normalize_path((root or system.getcwd()) .. PATHSEP .. path)
  end)
  if not ok then return nil end
  return existing_file(candidate) and candidate or nil
end

function locations.resolve_candidate(candidate, root, kind)
  local path = locations.resolve_path(candidate and candidate.source_path, root)
  if not path then return nil end
  return {
    line = candidate.line,
    col = candidate.col,
    line2 = candidate.line2,
    col2 = candidate.col2,
    kind = kind or "command-output-location",
    label = candidate.label or path,
    path = path,
    target_line = candidate.target_line,
    target_col = candidate.target_col,
    text_bounds = true,
  }
end

local function add_candidate(
  list, seen, limit, line_no, col1, col2, path, target_line, target_col, label
)
  if #list >= limit then return end
  path = clean_path(path)
  if path == "" or is_uri_like_path(path) then return end
  target_line = math.max(1, math.floor(tonumber(target_line) or 1))
  target_col = math.max(1, math.floor(tonumber(target_col) or 1))
  col1 = math.max(1, math.floor(tonumber(col1) or 1))
  col2 = math.max(col1 + 1, math.floor(tonumber(col2) or col1 + 1))
  local key = table.concat({ line_no, col1, col2, path, target_line, target_col }, "\0")
  if seen[key] then return end
  seen[key] = true
  list[#list + 1] = {
    line = line_no, col = col1, line2 = line_no, col2 = col2,
    source_path = path, label = label or path,
    target_line = target_line, target_col = target_col,
  }
end

local function starts_in_uri(line, col)
  local prefix = line:sub(1, math.max(0, (col or 1) - 1))
  local token = (prefix:match("([^%s\"']*)$") or ""):gsub("^[%(%[%{%<]+", "")
  return token:match("%a[%w+.-]*:") ~= nil
end

local function add_line_matches(list, seen, limit, line, line_no)
  local function add(col1, col2, path, target_line, target_col, label)
    if #list < limit and not starts_in_uri(line, col1) then
      add_candidate(
        list, seen, limit, line_no, col1, col2, path, target_line, target_col, label
      )
    end
  end
  local init = 1
  while true do
    local s, e, path, target_line = line:find("File%s+\"([^\"]+)\"%,%s+line%s+(%d+)", init)
    if not s then break end
    if not line:sub(e + 1):match("^,%s*column") then add(s, e + 1, path, target_line, 1, line:sub(s, e)) end
    init = e + 1
  end
  init = 1
  while true do
    local s, e, path, target_line, target_col = line:find("\"([^\"]+)\"%,%s+line%s+(%d+)%,%s+column%s+(%d+)", init)
    if not s then break end
    if line:sub(math.max(1, s - 5), s - 1) ~= "File " then add(s, e + 1, path, target_line, target_col, line:sub(s, e)) end
    init = e + 1
  end
  init = 1
  while true do
    local s, e, path, target_line, target_col = line:find("File%s+\"([^\"]+)\"%,%s+line%s+(%d+)%,%s+column%s+(%d+)", init)
    if not s then break end
    add(s, e + 1, path, target_line, target_col, line:sub(s, e))
    init = e + 1
  end
  init = 1
  while true do
    local s, e, path, target_line, target_col = line:find("%-%-%>%s*([^:%s][^:\r\n]-):(%d+):(%d+)", init)
    if not s then break end
    local path_offset = line:find(path, s, true) or s
    add(path_offset, e + 1, path, target_line, target_col, line:sub(path_offset, e))
    init = e + 1
  end
  for s, path, target_line, target_col, e in line:gmatch("()([A-Za-z]:[/\\][^:\r\n]-):(%d+):(%d+)()") do add(s, e, path, target_line, target_col) end
  for s, path, target_line, target_col, e in line:gmatch("()([A-Za-z]:[/\\][^:\r\n]-):(%d+),(%d+)()") do add(s, e, path, target_line, target_col) end
  for s, path, target_line, e in line:gmatch("()([A-Za-z]:[/\\][^:\r\n]-):(%d+)()") do if not line:sub(e):match("^[:,]%d") then add(s, e, path, target_line, 1) end end
  for s, path, target_line, target_col, e in line:gmatch("()([^%s:\"'()<>|]+):(%d+):(%d+)()") do add(s, e, path, target_line, target_col) end
  for s, path, target_line, target_col, e in line:gmatch("()([^%s:\"'()<>|]+):(%d+),(%d+)()") do add(s, e, path, target_line, target_col) end
  for s, path, target_line, e in line:gmatch("()([^%s:\"'()<>|]+):(%d+)()") do if not line:sub(e):match("^[:,]%d") then add(s, e, path, target_line, 1) end end
  for s, path, target_line, target_col, e in line:gmatch("()([A-Za-z]:[/\\][^%(%)\r\n]-)%((%d+)%,(%d+)%)()") do add(s, e, path, target_line, target_col) end
  for s, path, target_line, e in line:gmatch("()([A-Za-z]:[/\\][^%(%)\r\n]-)%((%d+)%)()") do if line:sub(e, e) ~= "," then add(s, e, path, target_line, 1) end end
  for s, path, target_line, target_col, e in line:gmatch("()([^%s:\"'<>|]+)%((%d+)%,(%d+)%)()") do add(s, e, path, target_line, target_col) end
  for s, path, target_line, e in line:gmatch("()([^%s:\"'<>|]+)%((%d+)%)()") do if line:sub(e, e) ~= "," then add(s, e, path, target_line, 1) end end
end

local function sort(candidates)
  table.sort(candidates, function(a, b)
    return a.line ~= b.line and a.line < b.line or a.line == b.line and a.col < b.col
  end)
  return candidates
end

function locations.extract_candidates(text, limit)
  limit = math.max(0, math.floor(tonumber(limit) or math.huge))
  local candidates, seen, line_no = {}, {}, 1
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if #candidates >= limit then break end
    add_line_matches(candidates, seen, limit, line:gsub("\r$", ""), line_no)
    line_no = line_no + 1
  end
  return sort(candidates)
end

function locations.resolve_candidates(candidates, root, kind)
  local points = {}
  for _, candidate in ipairs(candidates or {}) do
    local point = locations.resolve_candidate(candidate, root, kind)
    if point then points[#points + 1] = point end
  end
  return sort(points)
end

function locations.extract(text, opts)
  opts = opts or {}
  return locations.resolve_candidates(locations.extract_candidates(text), opts.root, opts.kind)
end

return locations
