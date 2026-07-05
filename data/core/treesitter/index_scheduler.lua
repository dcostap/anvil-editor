-- Lua-side scheduler for Tree-sitter indexing shard jobs.
--
-- This limits how many background indexing jobs are submitted to the shared
-- worker pool at once. It is intentionally small and Lua-only; later sharding
-- milestones can use it as the run-level coordinator before native lanes exist.

local worker_pool = require "core.worker_pool"

local scheduler = {}
scheduler.__index = scheduler

local function default_max_running(pool)
  local pool_workers = tonumber(pool and pool.worker_count) or 1
  local cpu_count = thread and thread.get_cpu_count and thread.get_cpu_count() or pool_workers
  cpu_count = math.max(1, math.floor(tonumber(cpu_count) or 1))
  if pool_workers > 1 then
    return math.max(1, math.min(cpu_count - 1, pool_workers - 1, 3))
  end
  return 1
end

function scheduler.new(options)
  options = options or {}
  local pool = options.pool or worker_pool.system()
  local self = setmetatable({
    pool = pool,
    max_running = math.max(1, math.floor(tonumber(options.max_running) or default_max_running(pool))),
    queue = {},
    running = {},
    next_id = 0,
    cancelled = false,
  }, scheduler)
  return self
end

function scheduler:running_count()
  local count = 0
  for _ in pairs(self.running) do count = count + 1 end
  return count
end

function scheduler:queued_count()
  return #self.queue
end

function scheduler:outstanding_count()
  return self:queued_count() + self:running_count()
end

function scheduler:set_max_running(value)
  self.max_running = math.max(1, math.floor(tonumber(value) or self.max_running or 1))
  self:pump()
end

local function remove_queued(self, handle)
  for i, item in ipairs(self.queue) do
    if item.handle == handle then
      table.remove(self.queue, i)
      return item
    end
  end
end

function scheduler:cancel(handle)
  if not handle then return false end
  if handle.state == "queued" then
    local item = remove_queued(self, handle)
    if not item then return false end
    handle.state = "cancelled"
    if item.spec.on_cancelled then
      item.spec.on_cancelled({
        type = "cancelled",
        payload = { before_start = true, scheduler_cancelled = true },
        generation = item.spec.generation,
        project_paths_generation = item.spec.project_paths_generation,
        phase = item.spec.phase,
      }, handle)
    end
    return true
  end
  if handle.state == "running" and handle.worker_handle then
    handle.state = "cancelling"
    return self.pool:cancel(handle.worker_handle)
  end
  return false
end

function scheduler:cancel_all()
  local cancelled = 0
  for i = #self.queue, 1, -1 do
    local item = table.remove(self.queue, i)
    item.handle.state = "cancelled"
    cancelled = cancelled + 1
    if item.spec.on_cancelled then
      item.spec.on_cancelled({
        type = "cancelled",
        payload = { before_start = true, scheduler_cancelled = true },
        generation = item.spec.generation,
        project_paths_generation = item.spec.project_paths_generation,
        phase = item.spec.phase,
      }, item.handle)
    end
  end
  for _, handle in pairs(self.running) do
    if handle.worker_handle and self.pool:cancel(handle.worker_handle) then cancelled = cancelled + 1 end
    handle.state = "cancelling"
  end
  return cancelled
end

local function terminal_message_type(message)
  local message_type = message and message.type
  return message_type == "final"
      or message_type == "complete"
      or message_type == "error"
      or message_type == "cancelled"
end

function scheduler:on_terminal(handle, state)
  if handle and handle.worker_handle then
    self.running[handle.worker_handle.id] = nil
  end
  if handle then handle.state = state or handle.state or "complete" end
  self:pump()
end

local function wrap_terminal(self, item, name, state)
  local original = item.spec[name]
  item.spec[name] = function(message, worker_handle)
    if original then original(message, item.handle, worker_handle) end
    self:on_terminal(item.handle, state)
  end
end

local function wrap_stale(self, item)
  local original = item.spec.on_stale
  item.spec.on_stale = function(message, worker_handle)
    if original then original(message, item.handle, worker_handle) end
    if terminal_message_type(message) then self:on_terminal(item.handle, "stale") end
  end
end

function scheduler:pump()
  while not self.cancelled and self:running_count() < self.max_running and #self.queue > 0 do
    local item = table.remove(self.queue, 1)
    if item.handle.state == "queued" then
      wrap_terminal(self, item, "on_complete", "complete")
      wrap_terminal(self, item, "on_error", "failed")
      wrap_terminal(self, item, "on_cancelled", "cancelled")
      wrap_stale(self, item)
      local worker_handle, err = self.pool:submit(item.spec)
      if worker_handle then
        item.handle.worker_handle = worker_handle
        item.handle.state = "running"
        self.running[worker_handle.id] = item.handle
      else
        item.handle.state = "failed"
        if item.spec.on_error then
          item.spec.on_error({ type = "error", error = err or "scheduler-submit-failed" }, item.handle)
        end
      end
    end
  end
end

function scheduler:submit(spec)
  assert(type(spec) == "table", "index scheduler submit expects a worker spec table")
  self.next_id = self.next_id + 1
  local handle = {
    id = self.next_id,
    kind = spec.kind,
    generation = spec.generation,
    project_paths_generation = spec.project_paths_generation,
    phase = spec.phase,
    state = "queued",
  }
  self.queue[#self.queue + 1] = { spec = spec, handle = handle }
  self:pump()
  return handle
end

function scheduler.default_max_running(pool)
  return default_max_running(pool)
end

return scheduler
