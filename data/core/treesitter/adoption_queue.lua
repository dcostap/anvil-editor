local AdoptionQueue = {}
AdoptionQueue.__index = AdoptionQueue

local DEFAULT_MAX_ITEM_BYTES = 256 * 1024
local DEFAULT_MAX_ITEM_RECORDS = 512

function AdoptionQueue.new(opts)
  opts = opts or {}
  return setmetatable({
    items = {},
    head = 1,
    max_item_bytes = math.max(1, math.floor(tonumber(opts.max_item_bytes) or DEFAULT_MAX_ITEM_BYTES)),
    max_item_records = math.max(1, math.floor(tonumber(opts.max_item_records) or DEFAULT_MAX_ITEM_RECORDS)),
    queued_bytes = 0,
    queued_records = 0,
  }, AdoptionQueue)
end

function AdoptionQueue:count()
  return math.max(0, #self.items - self.head + 1)
end

function AdoptionQueue:enqueue(item)
  if type(item) ~= "table" or type(item.adopt) ~= "function" then return false, "invalid-item" end
  local bytes = math.max(0, math.floor(tonumber(item.bytes) or 0))
  local records = math.max(0, math.floor(tonumber(item.records) or 0))
  if bytes > self.max_item_bytes or records > self.max_item_records then return false, "item-too-large" end
  item.bytes = bytes
  item.records = records
  item.enqueued_at = item.enqueued_at or ((system and system.get_time and system.get_time()) or os.clock())
  self.items[#self.items + 1] = item
  self.queued_bytes = self.queued_bytes + bytes
  self.queued_records = self.queued_records + records
  return true
end

local function remove_head(self)
  local item = self.items[self.head]
  if not item then return nil end
  self.items[self.head] = false
  self.head = self.head + 1
  self.queued_bytes = math.max(0, self.queued_bytes - item.bytes)
  self.queued_records = math.max(0, self.queued_records - item.records)
  if self.head > #self.items then
    self.items = {}
    self.head = 1
  elseif self.head > 128 and self.head > #self.items / 2 then
    local compact = {}
    for i = self.head, #self.items do compact[#compact + 1] = self.items[i] end
    self.items = compact
    self.head = 1
  end
  return item
end

function AdoptionQueue:oldest_age()
  local item = self.items[self.head]
  if not item then return 0 end
  local current = (system and system.get_time and system.get_time()) or os.clock()
  return math.max(0, current - (item.enqueued_at or current))
end

function AdoptionQueue:step(opts)
  opts = opts or {}
  local max_bytes = math.max(0, math.floor(tonumber(opts.max_bytes) or self.max_item_bytes))
  local max_records = math.max(0, math.floor(tonumber(opts.max_records) or self.max_item_records))
  local max_items = math.max(1, math.floor(tonumber(opts.max_items) or math.huge))
  local result = { adopted = 0, discarded = 0, bytes = 0, records = 0 }

  while result.adopted + result.discarded < max_items do
    local item = self.items[self.head]
    if not item then break end
    local stale = item.stale and item.stale() or false
    if stale then
      remove_head(self)
      result.discarded = result.discarded + 1
      if item.discard then item.discard() end
    else
      if result.bytes + item.bytes > max_bytes or result.records + item.records > max_records then break end
      remove_head(self)
      item.adopt()
      result.adopted = result.adopted + 1
      result.bytes = result.bytes + item.bytes
      result.records = result.records + item.records
    end
  end
  result.remaining = self:count()
  result.queued_bytes = self.queued_bytes
  result.queued_records = self.queued_records
  return result
end

return AdoptionQueue
