local lsp_json = {}

local null_marker = {}
local array_mt = { __lsp_json_kind = "array" }
local object_mt = { __lsp_json_kind = "object" }

lsp_json.null = null_marker

local function marker_kind(value)
  local mt = type(value) == "table" and getmetatable(value)
  return mt and mt.__lsp_json_kind or nil
end

function lsp_json.array(values)
  values = values or {}
  assert(type(values) == "table", "lsp_json.array expects a table")
  return setmetatable(values, array_mt)
end

function lsp_json.object(values)
  values = values or {}
  assert(type(values) == "table", "lsp_json.object expects a table")
  return setmetatable(values, object_mt)
end

function lsp_json.is_null(value)
  return value == null_marker
end

function lsp_json.is_array(value)
  return marker_kind(value) == "array"
end

function lsp_json.is_object(value)
  return marker_kind(value) == "object"
end

local encode

local escape_char_map = {
  ["\\"] = "\\",
  ["\""] = "\"",
  ["\b"] = "b",
  ["\f"] = "f",
  ["\n"] = "n",
  ["\r"] = "r",
  ["\t"] = "t",
}

local escape_char_map_inv = { ["/"] = "/" }
for k, v in pairs(escape_char_map) do
  escape_char_map_inv[v] = k
end

local function escape_char(c)
  return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
end

local function encode_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function encode_number(value)
  if value ~= value or value <= -math.huge or value >= math.huge then
    error("unexpected number value '" .. tostring(value) .. "'")
  end
  return string.format("%.14g", value)
end

local function is_sequential_array(value)
  if rawget(value, 1) == nil then
    return false
  end
  local n = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      error("invalid table: mixed or invalid key types")
    end
    n = n + 1
  end
  if n ~= #value then
    error("invalid table: sparse array")
  end
  return true
end

local function encode_array(value, stack)
  local out = {}
  local n = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      error("invalid array: non-sequential or non-numeric key")
    end
    n = n + 1
  end
  if n ~= #value then
    error("invalid array: sparse array")
  end
  for i = 1, #value do
    out[i] = encode(value[i], stack)
  end
  return "[" .. table.concat(out, ",") .. "]"
end

local function encode_object(value, stack)
  local out = {}
  for key, item in pairs(value) do
    if type(key) ~= "string" then
      error("invalid object: non-string key")
    end
    out[#out + 1] = encode_string(key) .. ":" .. encode(item, stack)
  end
  return "{" .. table.concat(out, ",") .. "}"
end

local function encode_table(value, stack)
  if value == null_marker then
    return "null"
  end
  stack = stack or {}
  if stack[value] then error("circular reference") end
  stack[value] = true

  local kind = marker_kind(value)
  local result
  if kind == "array" then
    result = encode_array(value, stack)
  elseif kind == "object" then
    result = encode_object(value, stack)
  elseif is_sequential_array(value) then
    result = encode_array(value, stack)
  else
    -- Raw empty tables are objects by default. Use lsp_json.array({}) when an
    -- explicit empty array is required by the protocol.
    result = encode_object(value, stack)
  end

  stack[value] = nil
  return result
end

encode = function(value, stack)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "table" then
    return encode_table(value, stack)
  elseif kind == "string" then
    return encode_string(value)
  elseif kind == "number" then
    return encode_number(value)
  elseif kind == "boolean" then
    return tostring(value)
  end
  error("unexpected type '" .. kind .. "'")
end

function lsp_json.encode(value)
  return encode(value)
end

local parse
local error_message = ""

local function create_set(...)
  local out = {}
  for i = 1, select("#", ...) do
    out[select(i, ...)] = true
  end
  return out
end

local space_chars = create_set(" ", "\t", "\r", "\n")
local delim_chars = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local literals = create_set("true", "false", "null")

local literal_map = {
  ["true"] = true,
  ["false"] = false,
  ["null"] = null_marker,
}

local function decode_error(str, idx, msg)
  local line_count = 1
  local col_count = 1
  for i = 1, idx - 1 do
    col_count = col_count + 1
    if str:sub(i, i) == "\n" then
      line_count = line_count + 1
      col_count = 1
    end
  end
  error_message = string.format("%s at line %d col %d", msg, line_count, col_count)
end

local function next_char(str, idx, set, negate)
  if type(idx) ~= "number" then
    decode_error(str, #str, "invalid json string")
    return #str + 1
  end
  for i = idx, #str do
    if set[str:sub(i, i)] ~= negate then
      return i
    end
  end
  return #str + 1
end

local function codepoint_to_utf8(n)
  local f = math.floor
  if n <= 0x7f then
    return string.char(n)
  elseif n <= 0x7ff then
    return string.char(f(n / 64) + 192, n % 64 + 128)
  elseif n <= 0xffff then
    return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
  elseif n <= 0x10ffff then
    return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
      f(n % 4096 / 64) + 128, n % 64 + 128)
  end
  error(string.format("invalid unicode codepoint '%x'", n))
end

local function parse_unicode_escape(s)
  local n1 = tonumber(s:sub(1, 4), 16)
  local n2 = tonumber(s:sub(7, 10), 16)
  if n2 then
    return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
  end
  return codepoint_to_utf8(n1)
end

local function parse_string(str, i)
  local out = ""
  local j = i + 1
  local k = j

  while j <= #str do
    local byte = str:byte(j)
    if byte < 32 then
      decode_error(str, j, "control character in string")
      return nil, j
    elseif byte == 92 then
      out = out .. str:sub(k, j - 1)
      j = j + 1
      local c = str:sub(j, j)
      if c == "u" then
        local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
          or str:match("^%x%x%x%x", j + 1)
        if not hex then
          decode_error(str, j - 1, "invalid unicode escape in string")
          return nil, j
        end
        out = out .. parse_unicode_escape(hex)
        j = j + #hex
      else
        if not escape_chars[c] then
          decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
          return nil, j
        end
        out = out .. escape_char_map_inv[c]
      end
      k = j + 1
    elseif byte == 34 then
      out = out .. str:sub(k, j - 1)
      return out, j + 1
    end
    j = j + 1
  end

  decode_error(str, i, "expected closing quote for string")
  return nil, j
end

local function parse_number(str, i)
  local x = next_char(str, i, delim_chars)
  local s = str:sub(i, x - 1)
  local n = tonumber(s)
  if not n then
    decode_error(str, i, "invalid number '" .. s .. "'")
  end
  return n, x
end

local function parse_literal(str, i)
  local x = next_char(str, i, delim_chars)
  local word = str:sub(i, x - 1)
  if not literals[word] then
    decode_error(str, i, "invalid literal '" .. word .. "'")
    return nil, x
  end
  return literal_map[word], x
end

local function parse_array(str, i)
  local out = lsp_json.array({})
  local n = 1
  i = i + 1
  while true do
    local value
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) == "]" then
      return out, i + 1
    end
    value, i = parse(str, i)
    if error_message ~= "" then return nil, i end
    out[n] = value
    n = n + 1
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "]" then break end
    if chr ~= "," then
      decode_error(str, i, "expected ']' or ','")
      return nil, i
    end
  end
  return out, i
end

local function parse_object(str, i)
  local out = lsp_json.object({})
  i = i + 1
  while true do
    local key, value
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) == "}" then
      return out, i + 1
    end
    if str:sub(i, i) ~= '"' then
      decode_error(str, i, "expected string for key")
      return nil, i
    end
    key, i = parse(str, i)
    if error_message ~= "" then return nil, i end
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) ~= ":" then
      decode_error(str, i, "expected ':' after key")
      return nil, i
    end
    i = next_char(str, i + 1, space_chars, true)
    value, i = parse(str, i)
    if error_message ~= "" then return nil, i end
    out[key] = value
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "}" then break end
    if chr ~= "," then
      decode_error(str, i, "expected '}' or ','")
      return nil, i
    end
  end
  return out, i
end

local char_func_map = {
  ['"'] = parse_string,
  ["0"] = parse_number,
  ["1"] = parse_number,
  ["2"] = parse_number,
  ["3"] = parse_number,
  ["4"] = parse_number,
  ["5"] = parse_number,
  ["6"] = parse_number,
  ["7"] = parse_number,
  ["8"] = parse_number,
  ["9"] = parse_number,
  ["-"] = parse_number,
  ["t"] = parse_literal,
  ["f"] = parse_literal,
  ["n"] = parse_literal,
  ["["] = parse_array,
  ["{"] = parse_object,
}

parse = function(str, idx)
  local chr = str:sub(idx, idx)
  local fn = char_func_map[chr]
  if fn then
    return fn(str, idx)
  end
  decode_error(str, idx, "unexpected character '" .. chr .. "'")
  return nil, idx
end

function lsp_json.last_error()
  return error_message
end

function lsp_json.decode(str)
  if type(str) ~= "string" then
    return nil, "expected argument of type string, got " .. type(str)
  end
  error_message = ""
  local value, idx = parse(str, next_char(str, 1, space_chars, true))
  if error_message ~= "" then
    return nil, error_message
  end
  idx = next_char(str, idx, space_chars, true)
  if idx <= #str then
    decode_error(str, idx, "trailing garbage")
    return nil, error_message
  end
  return value
end

return lsp_json
