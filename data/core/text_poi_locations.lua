local common = require "core.common"
local uri = require "core.lsp.uri"

local locations = {}

local function is_uri_like_path(path)
  path = tostring(path or "")
  if not path:find(":", 1, true) then return false end
  if path:match("^%a[%w+.-]*://") then return true end
  return path:match("^%a[%w+.-]*:") ~= nil and not path:match("^%a:[/\\]")
end

local function clean_path(path)
  -- Most matches are already plain paths. Avoid repeated trim scans and
  -- replacements, especially for long fields that resemble file names.
  if type(path) == "string" and path:byte(1) ~= 45 and path:byte(-1) ~= 46
      and path:find("^[%w_./\\~+-]+$") then
    return path
  end
  path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
  path = path:gsub("^[\"']", ""):gsub("[\"']$", "")
  path = path:gsub("^[%-%>:%s]+", ""):gsub("[%s,;]+$", "")
  while #path > 1 and path:match("[%.%)]$") do path = path:sub(1, -2) end
  return path
end

local function path_from_file_uri(path)
  if not uri.is_file_uri(path) then return nil end
  local ok, converted = pcall(uri.uri_to_path, path)
  return ok and converted or nil
end

local function existing_target(path, dirs)
  local info = path and system.get_file_info(path)
  return info and (dirs or info.type ~= "dir")
end

-- `opts.dirs` also accepts a folder.
function locations.resolve_path(path, root, opts)
  path = clean_path(path)
  if path == "" then return nil end
  local file_path = path_from_file_uri(path)
  if file_path then
    path = file_path
  elseif is_uri_like_path(path) then
    return nil
  end
  local ok, candidate = pcall(function()
    return common.is_absolute_path(path)
      and common.normalize_path(path)
      or common.normalize_path((root or system.getcwd()) .. PATHSEP .. path)
  end)
  if not ok then return nil end
  return existing_target(candidate, opts and opts.dirs) and candidate or nil
end

local function resolved_candidate(candidate, path, kind)
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

function locations.resolve_candidate(candidate, root, kind)
  local path = locations.resolve_path(candidate and candidate.source_path, root)
  return path and resolved_candidate(candidate, path, kind) or nil
end

local function add_candidate(
  list, seen, limit, line_no, col1, col2, path, target_line, target_col, label
)
  if #list >= limit then return end
  path = clean_path(path)
  if path == "" or (is_uri_like_path(path) and not uri.is_file_uri(path)) then return end
  target_line = math.max(1, math.floor(tonumber(target_line) or 1))
  target_col = math.max(1, math.floor(tonumber(target_col) or 1))
  -- Columns come directly from string matching and are already valid offsets.
  local key = line_no .. "\0" .. col1 .. "\0" .. col2 .. "\0"
    .. path .. "\0" .. target_line .. "\0" .. target_col
  if seen[key] then return end
  seen[key] = true
  list[#list + 1] = {
    line = line_no, col = col1, line2 = line_no, col2 = col2,
    source_path = path, label = label or path,
    target_line = target_line, target_col = target_col,
  }
end

local function starts_in_uri(scan, col)
  -- Matches advance within each format pass. Keep only the current token,
  -- and restart when another format returns to an earlier column. A result
  -- limit must not first allocate URI ranges for the complete line.
  if col < scan.start then
    scan.start, scan.finish, scan.next = 1, 1, 1
  end
  while col >= scan.finish do
    local first, last = scan.line:find("[^%s\"']+", scan.next)
    if not first then return false end
    scan.start, scan.finish, scan.next = first, last + 1, last + 1
    local token = scan.line:sub(first, last)
    local _, colon
    if token:find(":", 1, true) then
      _, colon = token:find("%a[%w+.-]*:")
    end
    scan.colon = colon and first + colon - 1 or last + 1
  end
  return col > scan.colon and col < scan.finish
end

-- Every supported source location puts its line number directly after ":"
-- or "(", or after "line" and whitespace. Most editor text, including URLs
-- and prose with numbers, can skip all pattern scans. Trailing line breaks
-- cannot change the answer because no digit follows them.
local function may_have_location(line)
  return line:find(":%d") or line:find("%(%d") or line:find("line%s+%d")
end

-- Keep scan data in arguments. A JIT trace can retain a helper closure and
-- all candidate tables captured by its upvalues after the scan returns.
local function add(list, seen, limit, line_no, uri_scan, col1, col2, path, target_line, target_col, label)
  if #list < limit and not starts_in_uri(uri_scan, col1) then
    add_candidate(
      list, seen, limit, line_no, col1, col2, path, target_line, target_col, label
    )
  end
end

local function add_file_uri(list, seen, limit, line_no, col1, col2, path, target_line, target_col)
  if #list < limit then
    add_candidate(
      list, seen, limit, line_no, col1, col2, path, target_line, target_col
    )
  end
end

local function add_line_matches(list, seen, limit, line, line_no)
  if #list >= limit or not may_have_location(line) then return end
  local uri_scan = { line = line, start = 1, finish = 1, next = 1 }
  local windows = line:find(":/", 1, true) or line:find(":\\", 1, true)
  local parentheses = line:find("(", 1, true)
  local init = 1
  if line:find("://", 1, true) then
    while #list < limit do
      local s, e, path, target_line, target_col = line:find(
        "([Ff][Ii][Ll][Ee]://[^%s\"'()<>|]+):(%d+):(%d+)", init
      )
      if not s then break end
      add_file_uri(list, seen, limit, line_no, s, e + 1, path, target_line, target_col)
      init = e + 1
    end
    init = 1
    while #list < limit do
      local s, e, path, target_line, target_col = line:find(
        "([Ff][Ii][Ll][Ee]://[^%s\"'()<>|]+):(%d+),(%d+)", init
      )
      if not s then break end
      add_file_uri(list, seen, limit, line_no, s, e + 1, path, target_line, target_col)
      init = e + 1
    end
    init = 1
    while #list < limit do
      local s, e, path, target_line = line:find(
        "([Ff][Ii][Ll][Ee]://[^%s\"'()<>|]+):(%d+)", init
      )
      if not s then break end
      if not line:find("^[:,]%d", e + 1) then
        add_file_uri(list, seen, limit, line_no, s, e + 1, path, target_line, 1)
      end
      init = e + 1
    end
    init = 1
    while #list < limit do
      local s, e, path, target_line, target_col = line:find(
        "([Ff][Ii][Ll][Ee]://[^%s\"'()<>|]+)%((%d+),(%d+)%)", init
      )
      if not s then break end
      add_file_uri(list, seen, limit, line_no, s, e + 1, path, target_line, target_col)
      init = e + 1
    end
    init = 1
    while #list < limit do
      local s, e, path, target_line = line:find(
        "([Ff][Ii][Ll][Ee]://[^%s\"'()<>|]+)%((%d+)%)", init
      )
      if not s then break end
      if line:sub(e + 1, e + 1) ~= "," then
        add_file_uri(list, seen, limit, line_no, s, e + 1, path, target_line, 1)
      end
      init = e + 1
    end
  end
  if line:find('"', 1, true) and line:find("line", 1, true) then
    init = 1
    while #list < limit do
      local s, e, path, target_line = line:find("File%s+\"([^\"]+)\"%,%s+line%s+(%d+)", init)
      if not s then break end
      if not line:find("^,%s*column", e + 1) then
        add(list, seen, limit, line_no, uri_scan, s, e + 1, path, target_line, 1, line:sub(s, e))
      end
      init = e + 1
    end
    init = 1
    while #list < limit do
      local s, e, path, target_line, target_col = line:find("\"([^\"]+)\"%,%s+line%s+(%d+)%,%s+column%s+(%d+)", init)
      if not s then break end
      if line:sub(math.max(1, s - 5), s - 1) ~= "File " then
        add(list, seen, limit, line_no, uri_scan, s, e + 1, path, target_line, target_col, line:sub(s, e))
      end
      init = e + 1
    end
    init = 1
    while #list < limit do
      local s, e, path, target_line, target_col = line:find("File%s+\"([^\"]+)\"%,%s+line%s+(%d+)%,%s+column%s+(%d+)", init)
      if not s then break end
      add(list, seen, limit, line_no, uri_scan, s, e + 1, path, target_line, target_col, line:sub(s, e))
      init = e + 1
    end
  end
  if line:find("-->", 1, true) then
    init = 1
    while #list < limit do
      local s, e, path, target_line, target_col = line:find("%-%-%>%s*([^:%s][^:\r\n]-):(%d+):(%d+)", init)
      if not s then break end
      local path_offset = line:find(path, s, true) or s
      add(list, seen, limit, line_no, uri_scan, path_offset, e + 1, path, target_line, target_col, line:sub(path_offset, e))
      init = e + 1
    end
  end
  if #list >= limit then return end
  if windows then
    for s, path, target_line, target_col, e in line:gmatch("()([A-Za-z]:[/\\][^:\r\n]-):(%d+):(%d+)()") do
      add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, target_col)
      if #list >= limit then return end
    end
    for s, path, target_line, target_col, e in line:gmatch("()([A-Za-z]:[/\\][^:\r\n]-):(%d+),(%d+)()") do
      add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, target_col)
      if #list >= limit then return end
    end
    for s, path, target_line, e in line:gmatch("()([A-Za-z]:[/\\][^:\r\n]-):(%d+)()") do
      if not line:find("^[:,]%d", e) then
        add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, 1)
      end
      if #list >= limit then return end
    end
  end
  -- Start at token boundaries. Retrying a failed path at every byte makes a
  -- long JSONL field with one :number take quadratic time on the UI thread.
  for s, path, target_line, target_col, e in line:gmatch("%f[^%z%s:\"'()<>|]()([^%s:\"'()<>|]+):(%d+):(%d+)()") do
    add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, target_col)
    if #list >= limit then return end
  end
  for s, path, target_line, target_col, e in line:gmatch("%f[^%z%s:\"'()<>|]()([^%s:\"'()<>|]+):(%d+),(%d+)()") do
    add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, target_col)
    if #list >= limit then return end
  end
  for s, path, target_line, e in line:gmatch("%f[^%z%s:\"'()<>|]()([^%s:\"'()<>|]+):(%d+)()") do
    if not line:find("^[:,]%d", e) then
      add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, 1)
    end
    if #list >= limit then return end
  end
  if parentheses and windows then
    for s, path, target_line, target_col, e in line:gmatch("()([A-Za-z]:[/\\][^%(%)\r\n]-)%((%d+)%,(%d+)%)()") do
      add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, target_col)
      if #list >= limit then return end
    end
    for s, path, target_line, e in line:gmatch("()([A-Za-z]:[/\\][^%(%)\r\n]-)%((%d+)%)()") do
      if line:sub(e, e) ~= "," then
        add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, 1)
      end
      if #list >= limit then return end
    end
  end
  if parentheses then
    for s, path, target_line, target_col, e in line:gmatch("%f[^%z%s:\"'()<>|]()([^%s:\"'<>|]+)%((%d+)%,(%d+)%)()") do
      add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, target_col)
      if #list >= limit then return end
    end
    for s, path, target_line, e in line:gmatch("%f[^%z%s:\"'()<>|]()([^%s:\"'<>|]+)%((%d+)%)()") do
      if line:sub(e, e) ~= "," then
        add(list, seen, limit, line_no, uri_scan, s, e, path, target_line, 1)
      end
      if #list >= limit then return end
    end
  end
end

local function sort(candidates)
  table.sort(candidates, function(a, b)
    return a.line ~= b.line and a.line < b.line or a.line == b.line and a.col < b.col
  end)
  return candidates
end

-- Plain paths have no line suffix. Keep quoted paths together, and do not
-- add a second target inside a diagnostic or a quoted path.
local function add_plain_paths(list, seen, limit, line, line_no, first_candidate)
  local ranges = {}
  for index = first_candidate, #list do
    local candidate = list[index]
    ranges[#ranges + 1] = { col = candidate.col, col2 = candidate.col2 }
  end
  for first, quote, path, last in line:gmatch("()([\"'`])(.-)%2()") do
    ranges[#ranges + 1] = { col = first, col2 = last }
    if not may_have_location(path) then
      add_candidate(list, seen, limit, line_no, first + 1, last - 1, path, 1, 1)
    end
    if #list >= limit then return end
  end
  table.sort(ranges, function(a, b) return a.col < b.col end)
  local index = 1
  for first, path, last in line:gmatch("()([^%s\"'`<>|]+)()") do
    while ranges[index] and ranges[index].col2 <= first do index = index + 1 end
    local range = ranges[index]
    if not range or range.col >= last then
      path = path:gsub("^[%(%[]+", ""):gsub("[%]%),;]+$", "")
      add_candidate(list, seen, limit, line_no, first, last, path, 1, 1)
    end
    if #list >= limit then return end
  end
end

function locations.extract_line_candidates(text, line_no, limit)
  text = tostring(text or "")
  -- File scans call this for every line. Skip the copy without its line break.
  if not may_have_location(text) then return {} end
  limit = math.max(0, math.floor(tonumber(limit) or math.huge))
  local ending = text:byte(-1)
  if ending == 10 or ending == 13 then text = text:gsub("[\r\n]+$", "") end
  local candidates = {}
  add_line_matches(
    candidates, {}, limit, text,
    math.max(1, math.floor(tonumber(line_no) or 1))
  )
  return sort(candidates)
end

function locations.extract_candidates(text, limit, opts)
  limit = math.max(0, math.floor(tonumber(limit) or math.huge))
  local candidates, seen, line_no = {}, {}, 1
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if #candidates >= limit then break end
    line = line:gsub("\r$", "")
    local first = #candidates + 1
    add_line_matches(candidates, seen, limit, line, line_no)
    if opts and opts.plain_paths and #candidates < limit then
      add_plain_paths(candidates, seen, limit, line, line_no, first)
    end
    line_no = line_no + 1
  end
  return sort(candidates)
end

function locations.resolve_candidates(candidates, roots, kind, cancelled)
  -- A diagnostic can name one file many times. Resolve each path once for
  -- this snapshot, but do not retain filesystem results across calls.
  local points, paths = {}, {}
  for _, candidate in ipairs(candidates or {}) do
    if cancelled and cancelled() then return nil end
    local source = candidate.source_path
    if source then
      local path = paths[source]
      if path == nil then
        path = false
        for _, root in ipairs(roots) do
          path = locations.resolve_path(source, root) or false
          if path then break end
        end
        paths[source] = path
      end
      if path then points[#points + 1] = resolved_candidate(candidate, path, kind) end
    end
  end
  return sort(points)
end

function locations.extract(text, opts)
  opts = opts or {}
  return locations.resolve_candidates(locations.extract_candidates(text), { opts.root or system.getcwd() }, opts.kind)
end

return locations
