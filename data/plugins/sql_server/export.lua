-- Text forms of a SQL Result: the rows that its table View shows, in the View's
-- order. Values stay the exact text that the server sent. NULL is `false`.
local M = {}

local function csv_value(value)
  if value == false then return "" end
  if value == "" or value:find('[,"\r\n]') or value:find("^%s") or value:find("%s$") then
    return '"' .. value:gsub('"', '""') .. '"'
  end
  return value
end

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function json_string(value)
  return '"' .. value:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function rows(view)
  local list = {}
  for i = 1, view:row_count() do list[i] = view:source_row(i).cells end
  return list
end

-- RFC 4180 quoting. An empty field is NULL; an empty string is "". Lines end
-- with "\n", as other Buffer text does; a save writes the Buffer's line ends.
function M.csv(view)
  local model, lines, fields = view.model, {}, {}
  for i = 1, model.column_count do fields[i] = csv_value(model.headers[i] or "") end
  lines[1] = table.concat(fields, ",")
  for _, cells in ipairs(rows(view)) do
    for i = 1, model.column_count do fields[i] = csv_value(cells[i]) end
    lines[#lines + 1] = table.concat(fields, ",")
  end
  return table.concat(lines, "\n") .. "\n"
end

-- An array of objects, one row on each line. Keys keep the column order, and a
-- repeated column name gets a number, such as "id (2)".
function M.json(view)
  local model, keys, seen = view.model, {}, {}
  for i = 1, model.column_count do
    local name = model.headers[i] or ""
    local key, n = name, 1
    while seen[key] do n = n + 1; key = string.format("%s (%d)", name, n) end
    seen[key] = true
    keys[i] = json_string(key) .. ": "
  end
  local lines, fields = {}, {}
  for _, cells in ipairs(rows(view)) do
    for i = 1, model.column_count do
      fields[i] = keys[i] .. (cells[i] == false and "null" or json_string(cells[i]))
    end
    lines[#lines + 1] = "  {" .. table.concat(fields, ", ") .. "}"
  end
  if #lines == 0 then return "[]\n" end
  return "[\n" .. table.concat(lines, ",\n") .. "\n]\n"
end

return M
