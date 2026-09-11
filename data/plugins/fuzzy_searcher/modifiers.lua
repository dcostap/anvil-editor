-- Search Modifier syntax and file predicates. Offsets refer to the original input.
local modifiers = {}

local units = { b = 1, k = 1024, kb = 1024, m = 1048576, mb = 1048576,
  g = 1073741824, gb = 1073741824, t = 1099511627776, tb = 1099511627776 }

local definitions = {}

function definitions.size(value, result)
  local op, number, suffix = value:lower():match("^([<>=]*)(%d+)(%a*)$")
  local unit = suffix == "" and 1 or units[suffix]
  local bytes = number and unit and tonumber(number) * unit
  if not bytes or bytes + unit > 9007199254740991 then return "Invalid file size" end
  local low, high = 0, math.huge
  if op == "" then low, high = bytes, bytes + unit
  elseif op == "=" then low, high = bytes, bytes + 1
  elseif op == ">=" then low = bytes
  elseif op == ">" then low = bytes + 1
  elseif op == "<" then high = bytes
  elseif op == "<=" then high = bytes + 1
  else return "Invalid size comparison" end
  result.min_size = math.max(result.min_size or 0, low)
  result.max_size = math.min(result.max_size or math.huge, high)
end

function definitions.sort(value, result)
  value = value:lower()
  if value ~= "name" and value ~= "size" and value ~= "date" then
    return "Sort must be name, size, or date"
  end
  if result.sort and result.sort ~= value then return "Conflicting sort modifiers" end
  result.sort = value
end

function definitions.commit(value, result)
  if not value:match("^%x+$") or #value > 64 then return "Invalid commit ID" end
  value = value:lower()
  if result.commit and result.commit ~= value then return "Conflicting commit modifiers" end
  result.commit = value
end

local function mode_marker(text)
  local first = text:find("%S") or 1
  local prefix = text:sub(first, first)
  if prefix == "!" or prefix == ">" or prefix == "@" then return first, first, prefix end
  if text:sub(first, first + 1) == "$$" then return first, first + 1, "$$" end
  local quoted = false
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == '"' then quoted = not quoted end
    if not quoted and (ch == "#" or ch == "$") then return i, i, ch end
  end
end

function modifiers.parse(text)
  text = tostring(text or "")
  local result = { text = text, tokens = {}, active = false }
  -- Shell text and command identifiers own their colons.
  if text:match("^%s*[!>]") then
    result.marker_first, result.marker_last, result.mode = mode_marker(text)
    return result
  end
  local chunks, masked, first, i, quoted = {}, {}, 1, 1, false
  while i <= #text do
    local ch = text:sub(i, i)
    if ch == '"' then quoted = not quoted end
    local previous = text:sub(i - 1, i - 1)
    local boundary = i == 1 or previous:match("%s") or previous == "#" or previous == "@"
    local name, value = text:sub(i):match("^([%a_]+):([^%s]*)")
    local definition = name and definitions[name:lower()]
    if not quoted and boundary and definition then
      local last = i + #name + #value
      local token = { first = i, last = last, name = name:lower(), value = value }
      if value == "" then
        token.pending = true
        result.error = result.error or ("Enter a value for " .. token.name .. ":")
      else
        token.error = definition(value, result)
        token.valid = not token.error
        result.error = result.error or token.error
      end
      result.tokens[#result.tokens + 1] = token
      result.active = true
      chunks[#chunks + 1] = text:sub(first, i - 1)
      masked[#masked + 1] = text:sub(first, i - 1) .. string.rep(" ", last - i + 1)
      i = last + 1
      local spaces = text:sub(i):match("^%s*")
      masked[#masked + 1] = spaces
      i = i + #spaces
      first = i
    else
      i = i + 1
    end
  end
  chunks[#chunks + 1] = text:sub(first)
  masked[#masked + 1] = text:sub(first)
  result.text = table.concat(chunks):gsub("^%s+", ""):gsub("%s+$", "")
  result.marker_first, result.marker_last, result.mode = mode_marker(table.concat(masked))
  if result.active and (result.mode == "$" or result.mode == "$$"
    or result.mode == "!" or result.mode == ">") then
    result.error = "Search Modifiers require File Search or Text Search"
  elseif result.commit and result.sort == "date" then
    result.error = "Git commits do not store file modification dates"
  elseif result.commit and result.mode == "@" then
    result.error = "Commit Search requires the Project repository, not Path Search"
  end
  return result
end

function modifiers.accepts(options, info)
  if not info then return false end
  if options.min_size or options.sort == "size" then
    if info.type ~= "file" or type(info.size) ~= "number" then return false end
  end
  return not options.min_size
    or info.size >= options.min_size and info.size < options.max_size
end

function modifiers.less(options, a, b)
  local sort = options.sort
  if sort == "size" or sort == "date" then
    local field = sort == "size" and "file_size" or "file_modified"
    local av, bv = tonumber(a[field]) or -math.huge, tonumber(b[field]) or -math.huge
    if av ~= bv then return av > bv end
  elseif not sort then
    local av, bv = a.score or 0, b.score or 0
    if av ~= bv then return av > bv end
  end
  local ap, bp = a.file:lower(), b.file:lower()
  if sort then
    local an, bn = ap:match("[^/\\]+$") or ap, bp:match("[^/\\]+$") or bp
    if an ~= bn then return an < bn end
  end
  if ap ~= bp then return ap < bp end
  if a.file ~= b.file then return a.file < b.file end
  if a.line ~= b.line then return (a.line or 1) < (b.line or 1) end
  return (a.col or 1) < (b.col or 1)
end

return modifiers
