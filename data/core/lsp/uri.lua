local common = require "core.common"

local uri = {}

local function is_windows_path(path)
  return path:match("^%a:[/\\]") or path:match("^%a:$") or path:match("^[\\/][\\/]")
end

local function hex(byte)
  return string.format("%%%02X", byte)
end

local function is_unreserved(byte)
  return (byte >= 65 and byte <= 90)
    or (byte >= 97 and byte <= 122)
    or (byte >= 48 and byte <= 57)
    or byte == 45 -- -
    or byte == 46 -- .
    or byte == 95 -- _
    or byte == 126 -- ~
end

function uri.escape_path(path)
  assert(type(path) == "string", "uri.escape_path expects a string")
  return (path:gsub(".", function(char)
    local byte = char:byte()
    if is_unreserved(byte) or char == "/" or char == ":" then
      return char
    end
    return hex(byte)
  end))
end

function uri.unescape_path(path)
  assert(type(path) == "string", "uri.unescape_path expects a string")
  local i = 1
  while true do
    local percent = path:find("%%", i, true)
    if not percent then break end
    if not path:sub(percent + 1, percent + 2):match("^%x%x$") then
      return nil, "invalid percent escape in URI path"
    end
    i = percent + 3
  end
  return (path:gsub("%%(%x%x)", function(value)
    return string.char(tonumber(value, 16))
  end))
end

local function split_scheme(value)
  return value:match("^([%a][%w+.-]*):(.*)$")
end

local function normalize_windows_uri_path(path)
  path = path:gsub("\\", "/")
  if path:match("^%a:$") then
    path = path .. "/"
  end
  return path
end

function uri.path_to_uri(path)
  assert(type(path) == "string", "uri.path_to_uri expects a string")
  local normalized = normalize_windows_uri_path(path)

  if normalized:match("^//") then
    local without_slashes = normalized:gsub("^/+", "")
    local host, rest = without_slashes:match("^([^/]+)(/.*)$")
    if host then
      return "file://" .. uri.escape_path(host) .. uri.escape_path(rest)
    end
  end

  if normalized:match("^%a:/") then
    return "file:///" .. uri.escape_path(normalized)
  end

  if normalized:sub(1, 1) == "/" then
    return "file://" .. uri.escape_path(normalized)
  end

  if PLATFORM == "Windows" or is_windows_path(normalized) then
    return "file:///" .. uri.escape_path(normalized)
  end
  return "file://" .. uri.escape_path(normalized)
end

function uri.scheme(value)
  return split_scheme(value)
end

function uri.is_file_uri(value)
  if is_windows_path(value) then return false end
  local scheme = split_scheme(value)
  return scheme and scheme:lower() == "file"
end

function uri.uri_to_path(value, options)
  assert(type(value) == "string", "uri.uri_to_path expects a string")
  options = options or {}
  if is_windows_path(value) then
    if options.allow_path then return value end
    return nil, "URI is missing a scheme"
  end
  local scheme, rest = split_scheme(value)
  if not scheme then
    if options.allow_path then return value end
    return nil, "URI is missing a scheme"
  end
  if scheme:lower() ~= "file" then
    return nil, "unsupported URI scheme: " .. scheme
  end

  local authority, path
  if rest:sub(1, 2) == "//" then
    local after_slashes = rest:sub(3)
    authority, path = after_slashes:match("^([^/]*)(/.*)$")
    if not authority then
      authority = after_slashes
      path = ""
    end
  else
    authority = ""
    path = rest
  end

  local decoded_authority, auth_err = uri.unescape_path(authority or "")
  if not decoded_authority then return nil, auth_err end
  local decoded_path, path_err = uri.unescape_path(path or "")
  if not decoded_path then return nil, path_err end

  if PLATFORM == "Windows" then
    if decoded_authority ~= "" and decoded_authority ~= "localhost" then
      return "\\\\" .. decoded_authority .. decoded_path:gsub("/", "\\")
    end
    if decoded_path:match("^/%a:") then
      decoded_path = decoded_path:sub(2)
    end
    return decoded_path:gsub("/", "\\")
  end

  if decoded_authority ~= "" and decoded_authority ~= "localhost" then
    return "//" .. decoded_authority .. decoded_path
  end
  return decoded_path
end

uri.from_path = uri.path_to_uri
uri.to_path = uri.uri_to_path

function uri.file_operation_path(value)
  if uri.is_file_uri(value) then
    return uri.uri_to_path(value)
  end
  if is_windows_path(value) then return value end
  local scheme = split_scheme(value)
  if scheme then
    return nil, "unsupported URI scheme: " .. scheme
  end
  return value
end

local function normalize_comparison_path(path)
  local normalized = path:gsub("/", PATHSEP)
  normalized = common.normalize_path(normalized)
  if PLATFORM == "Windows" then
    normalized = normalized:gsub("/", "\\"):lower()
  end
  return normalized
end

function uri.comparison_key(value)
  assert(type(value) == "string", "uri.comparison_key expects a string")
  local path
  if uri.is_file_uri(value) then
    local err
    path, err = uri.uri_to_path(value)
    if not path then return nil, err end
  else
    if not is_windows_path(value) then
      local scheme = split_scheme(value)
      if scheme then return nil, "unsupported URI scheme: " .. scheme end
    end
    path = value
  end
  return normalize_comparison_path(path)
end

return uri
