local Object = require "core.object"

local BufferRegistry = Object:extend()

local function file_key(path)
  if type(path) ~= "string" or path == "" then return nil end
  path = path:gsub("\\", "/"):gsub("/+", "/")
  if PLATFORM == "Windows" then path = path:lower() end
  return "file:" .. path
end

local function is_dirty(buffer)
  if buffer.is_dirty then return buffer:is_dirty() end
  return buffer.dirty == true
end

function BufferRegistry:new(backing)
  self.buffers = backing or {}
  self.records = setmetatable({}, { __mode = "k" })
  self.by_identity = {}
  self.next_untitled_id = 0
end

function BufferRegistry:list()
  return self.buffers
end

function BufferRegistry:identity(buffer)
  local record = self.records[buffer]
  return record and record.identity or nil
end

function BufferRegistry:register(buffer, identity)
  assert(type(buffer) == "table", "Buffer Registry requires a Buffer")
  local current = self.records[buffer]
  if current then return buffer end
  local key = file_key(identity or buffer.abs_filename)
  if key and self.by_identity[key] then return nil, "file identity is already registered" end
  if not key then
    self.next_untitled_id = self.next_untitled_id + 1
    key = "untitled:" .. self.next_untitled_id
  end
  self.records[buffer] = { identity = key, owners = {} }
  self.by_identity[key] = buffer
  self.buffers[#self.buffers + 1] = buffer
  return buffer
end

function BufferRegistry:find(identity)
  return self.by_identity[file_key(identity) or identity]
end

function BufferRegistry:open(identity, factory)
  local existing = self:find(identity)
  if existing then return existing, false end
  local buffer = assert(factory(), "Buffer factory returned nil")
  local registered = self:register(buffer, identity)
  return registered, registered == buffer
end

function BufferRegistry:update_identity(buffer)
  local record = assert(self.records[buffer], "Buffer is not registered")
  local key = file_key(buffer.abs_filename)
  if not key then return record.identity end
  assert(self:can_use_identity(buffer, buffer.abs_filename),
    "another Buffer already has this file identity")
  self.by_identity[record.identity] = nil
  record.identity = key
  self.by_identity[key] = buffer
  return key
end

function BufferRegistry:can_use_identity(buffer, identity)
  local key = file_key(identity)
  local existing = key and self.by_identity[key]
  return not existing or existing == buffer
end

function BufferRegistry:retain(buffer, owner)
  assert(owner ~= nil, "Buffer owner is required")
  if not self.records[buffer] then
    local registered, err = self:register(buffer)
    assert(registered == buffer, err or "Buffer registration failed")
  end
  self.records[buffer].owners[owner] = true
  return buffer
end

function BufferRegistry:release(buffer, owner)
  local record = self.records[buffer]
  if not record then return false end
  local retained = record.owners[owner] ~= nil
  record.owners[owner] = nil
  return retained
end

function BufferRegistry:reference_count(buffer)
  local record = self.records[buffer]
  if not record then return 0 end
  local count = 0
  for _ in pairs(record.owners) do count = count + 1 end
  return count
end

function BufferRegistry:remove(buffer, force)
  local record = self.records[buffer]
  if not record then return false end
  -- A discarded Untitled Buffer can still report dirty after its identity is cleared.
  if not force
      and (self:reference_count(buffer) > 0
        or (is_dirty(buffer) and not buffer.intellij_untitled_discarded))
  then
    return false
  end
  self.by_identity[record.identity] = nil
  self.records[buffer] = nil
  for i = #self.buffers, 1, -1 do
    if self.buffers[i] == buffer then table.remove(self.buffers, i); break end
  end
  if buffer.on_close then buffer:on_close() end
  return true
end

function BufferRegistry:collect()
  local removed = 0
  for i = #self.buffers, 1, -1 do
    if self:remove(self.buffers[i]) then removed = removed + 1 end
  end
  return removed
end

return BufferRegistry
