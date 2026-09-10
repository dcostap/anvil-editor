local common = require "core.common"
local fuzzy = require "fuzzy"

local file_completion = {}

function file_completion.context(text, line, col)
  local start, cursor = nil, 1
  while cursor < col do
    local first, last = text:find("%b[]%(", cursor)
    if not first or last >= col then break end
    if text:sub(first - 1, first - 1) ~= "\\" then start = last + 1 end
    cursor = last + 1
  end
  if not start then return nil end
  while start < col and text:sub(start, start):match("%s") do start = start + 1 end

  local angle = text:sub(start, start) == "<"
  local close, depth, escaped, in_angle, quote = nil, 1, false, angle, nil
  for i = start, #text do
    local ch = text:sub(i, i)
    if escaped then
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif in_angle then
      if ch == ">" then in_angle = false end
    elseif quote then
      if ch == quote then quote = nil end
    elseif (ch == '"' or ch == "'") and text:sub(i - 1, i - 1):match("%s") then
      quote = ch
    elseif ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then close = i; break end
    end
  end
  if close and col > close then return nil end

  local query_start = start + (angle and 1 or 0)
  local target_end = close or #text + 1
  local suffix = ""
  if angle then
    local angle_close = text:find(">", query_start, true)
    if angle_close and angle_close < target_end then
      if col > angle_close then return nil end
      suffix = text:sub(angle_close + 1, target_end - 1)
    end
  else
    local title_start = text:find("%s+[\"']", query_start)
    if title_start and title_start < target_end then
      if col > title_start then return nil end
      suffix = text:sub(title_start, target_end - 1)
    end
  end
  local query = text:sub(query_start, col - 1)
  if query:match("^[%a][%w+.-]*:") or common.is_absolute_path(query) then return nil end
  return {
    mode = "file", line = line, col1 = start,
    col2 = close and close + 1 or #text + 1,
    query_col = query_start,
    query = query:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end),
    has_fragment = query:find("#", 1, true) ~= nil,
    angle = angle,
    suffix = suffix,
  }
end

function file_completion.candidates(context, source_path)
  if context.has_fragment then return {} end
  local root = common.dirname(source_path) or system.getcwd()
  local directory = context.query:match("^(.*[/\\])") or ""
  -- List one directory, not the complete Project, while the user types.
  local paths = common.path_suggest(directory, root)
  local matches = fuzzy.filter(paths, context.query, { mode = "path", limit = 200, spans = false })
  local candidates = {}
  for _, match in ipairs(matches) do
    local path = paths[match.index]
    local is_directory = path:match("[/\\]$") ~= nil
    candidates[#candidates + 1] = {
      text = path:gsub("\\", "/"),
      target = path:gsub("\\", "/"),
      path = common.normalize_path(root .. PATHSEP .. path),
      rel_path = path:gsub("\\", "/"),
      kind = is_directory and "directory" or "file",
      directory = is_directory,
    }
  end
  return candidates
end

function file_completion.replacement(context, target)
  local encoded = target:gsub("[^%w%-%._~/]", function(char)
    return string.format("%%%02X", char:byte())
  end)
  local prefix = context.angle and "<" or ""
  local suffix = (context.angle and ">" or "") .. context.suffix .. ")"
  return prefix .. encoded .. suffix, #prefix + #encoded
end

return file_completion
