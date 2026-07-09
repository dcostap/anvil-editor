local codec = {}

local function append(out, value)
  out[#out + 1] = value
end

local function encode_value(value, out, seen)
  local kind = type(value)
  if kind == "nil" then
    append(out, "N")
  elseif kind == "boolean" then
    append(out, value and "T" or "F")
  elseif kind == "number" then
    local text = tostring(value)
    append(out, "D" .. #text .. ":" .. text)
  elseif kind == "string" then
    append(out, "S" .. #value .. ":" .. value)
  elseif kind == "table" then
    if seen[value] then error("Tree-sitter artifact cannot encode cyclic tables") end
    seen[value] = true
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    append(out, "M" .. tostring(count) .. ":")
    for key, item in pairs(value) do
      encode_value(key, out, seen)
      encode_value(item, out, seen)
    end
    seen[value] = nil
  else
    error("Tree-sitter artifact cannot encode " .. kind)
  end
end

function codec.encode(value)
  local out = { "ANVILTS1" }
  encode_value(value, out, {})
  return table.concat(out)
end

local function read_length(data, pos)
  local colon = data:find(":", pos, true)
  if not colon then return nil, nil, "missing-length-delimiter" end
  local length = tonumber(data:sub(pos, colon - 1))
  if not length or length < 0 or length ~= math.floor(length) then return nil, nil, "invalid-length" end
  return length, colon + 1
end

local function decode_value(data, pos)
  local tag = data:sub(pos, pos)
  pos = pos + 1
  if tag == "N" then return nil, pos end
  if tag == "T" then return true, pos end
  if tag == "F" then return false, pos end
  if tag == "D" or tag == "S" then
    local length, value_pos, err = read_length(data, pos)
    if not length then return nil, nil, err end
    local last = value_pos + length - 1
    if last > #data then return nil, nil, "truncated-value" end
    local text = data:sub(value_pos, last)
    if tag == "D" then
      local number = tonumber(text)
      if number == nil then return nil, nil, "invalid-number" end
      return number, last + 1
    end
    return text, last + 1
  end
  if tag == "M" then
    local count, item_pos, err = read_length(data, pos)
    if not count then return nil, nil, err end
    local value = {}
    pos = item_pos
    for _ = 1, count do
      local key
      key, pos, err = decode_value(data, pos)
      if pos == nil then return nil, nil, err end
      local item
      item, pos, err = decode_value(data, pos)
      if pos == nil then return nil, nil, err end
      value[key] = item
    end
    return value, pos
  end
  return nil, nil, "invalid-tag"
end

function codec.decode(data)
  if type(data) ~= "string" or data:sub(1, 8) ~= "ANVILTS1" then return nil, "invalid-header" end
  local value, pos, err = decode_value(data, 9)
  if pos == nil then return nil, err end
  if pos <= #data then return nil, "trailing-data" end
  return value
end

function codec.write(path, value)
  local ok, encoded = pcall(codec.encode, value)
  if not ok then return nil, encoded end
  local fp, err = io.open(path, "wb")
  if not fp then return nil, err or "open-failed" end
  local wrote, write_err = fp:write(encoded)
  local closed, close_err = fp:close()
  if not wrote or not closed then pcall(os.remove, path); return nil, write_err or close_err or "write-failed" end
  return { path = path, bytes = #encoded }
end

function codec.read(path)
  local fp, err = io.open(path, "rb")
  if not fp then return nil, err or "open-failed" end
  local data = fp:read("*a") or ""
  fp:close()
  return codec.decode(data)
end

return codec
