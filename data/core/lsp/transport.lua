local transport = {}

local incoming_queue = {}
incoming_queue.__index = incoming_queue

function transport.new_incoming_queue(options)
  options = options or {}
  return setmetatable({
    items = {},
    max_messages = options.max_messages or 256,
    overflow = options.overflow or "fail",
    closed = false,
    failed = false,
    error = nil,
    dropped = 0,
  }, incoming_queue)
end

function incoming_queue:push(item)
  if self.closed or self.failed then
    return nil, self.error or "queue closed"
  end
  if #self.items >= self.max_messages then
    if self.overflow == "drop_newest" then
      self.dropped = self.dropped + 1
      return false, "queue full"
    elseif self.overflow == "drop_oldest" then
      table.remove(self.items, 1)
      self.dropped = self.dropped + 1
    else
      self.failed = true
      self.error = "incoming queue full"
      return nil, self.error
    end
  end
  self.items[#self.items + 1] = item
  return true
end

function incoming_queue:pop()
  if #self.items == 0 then return nil end
  return table.remove(self.items, 1)
end

function incoming_queue:peek()
  return self.items[1]
end

function incoming_queue:size()
  return #self.items
end

function incoming_queue:is_failed()
  return self.failed
end

function incoming_queue:close(err)
  self.closed = true
  self.error = err or self.error
end

local wrapper = {}
wrapper.__index = wrapper

function transport.wrap(driver)
  assert(type(driver) == "table", "transport.wrap expects a table")
  assert(type(driver.read) == "function", "transport must implement read(max_bytes)")
  assert(type(driver.write) == "function", "transport must implement write(bytes)")
  return setmetatable({ driver = driver, closed = false }, wrapper)
end

function wrapper:read(max_bytes)
  if self.closed then return nil, "transport closed" end
  return self.driver:read(max_bytes)
end

function wrapper:write(bytes)
  if self.closed then return nil, "transport closed" end
  return self.driver:write(bytes)
end

function wrapper:close()
  self.closed = true
  if self.driver.close then
    return self.driver:close()
  end
  return true
end

return transport
