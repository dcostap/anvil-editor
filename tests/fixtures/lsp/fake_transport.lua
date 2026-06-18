local jsonrpc = require "core.lsp.jsonrpc"

local fake_transport = {}
local fake_transport_mt = {}
fake_transport_mt.__index = fake_transport_mt

function fake_transport.new(options)
  options = options or {}
  return setmetatable({
    chunks = options.chunks or {},
    writes = {},
    closed = false,
    read_error = options.read_error,
    write_error = options.write_error,
  }, fake_transport_mt)
end

local function split_bytes(text, sizes)
  if not sizes then return { text } end
  local out = {}
  local pos = 1
  for _, size in ipairs(sizes) do
    if pos > #text then break end
    out[#out + 1] = text:sub(pos, pos + size - 1)
    pos = pos + size
  end
  if pos <= #text then
    out[#out + 1] = text:sub(pos)
  end
  return out
end

function fake_transport_mt:push_chunk(chunk)
  self.chunks[#self.chunks + 1] = chunk
end

function fake_transport_mt:push_message(message, chunk_sizes)
  for _, chunk in ipairs(split_bytes(jsonrpc.encode(message), chunk_sizes)) do
    self:push_chunk(chunk)
  end
end

function fake_transport_mt:read(_max_bytes)
  if self.closed then return nil, "closed" end
  if self.read_error then return nil, self.read_error end
  if #self.chunks == 0 then return nil end
  return table.remove(self.chunks, 1)
end

function fake_transport_mt:write(bytes)
  if self.closed then return nil, "closed" end
  if self.write_error then return nil, self.write_error end
  self.writes[#self.writes + 1] = bytes
  return true
end

function fake_transport_mt:written_bytes()
  return table.concat(self.writes)
end

function fake_transport_mt:written_messages()
  local parser = jsonrpc.new_parser()
  local messages, err = parser:feed(self:written_bytes())
  if not messages then return nil, err end
  return messages
end

function fake_transport_mt:close()
  self.closed = true
  return true
end

return fake_transport
