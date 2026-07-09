local common = require "core.common"

local native_ok, native_pool = pcall(require, "worker_pool_native")
if not native_ok then native_pool = nil end

local worker_pool = {}
worker_pool.__index = worker_pool

local system_pool
local pool_sequence = 0

local DEFAULT_DRAIN_BUDGET_MS = 1.0
local DEFAULT_DRAIN_MAX_MESSAGES = 64

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function log_quiet(fmt, ...)
  local core = package.loaded.core or rawget(_G, "core")
  if core and core.log_quiet then
    core.log_quiet(fmt, ...)
  end
end

local function unique_name(prefix)
  pool_sequence = pool_sequence + 1
  local pid = system and system.get_process_id and system.get_process_id() or 0
  return string.format("anvil-worker-pool-%s-%s-%d-%d", prefix, tostring(pid), math.floor(now() * 1000000), pool_sequence)
end

local function copy_handle(handle)
  if type(handle) ~= "table" then return nil end
  return {
    id = handle.id,
    pool_id = handle.pool_id,
    worker_id = handle.worker_id,
    kind = handle.kind,
    generation = handle.generation,
    project_paths_generation = handle.project_paths_generation,
    phase = handle.phase,
  }
end

local function default_worker_count()
  local count = thread and thread.get_cpu_count and thread.get_cpu_count() or 1
  count = math.max(1, math.min(4, math.floor(count or 1)))
  return count
end

local function mark_terminal(job, status)
  job.status = status
  job.finished_at = job.finished_at or now()
end

local function release_terminal_job(job)
  if not job or not job.finished_at or job.released then return end
  if job.cancel_channel then job.cancel_channel:clear() end
  job.spec = nil
  job.cancel_channel = nil
  job.cancel_channel_name = nil
  if job.native_id and job.pool then job.pool.native_jobs[job.native_id] = nil end
  job.native_handle = nil
  job.native_id = nil
  job.native_cancel_token = nil
  job.native_cancel_token_name = nil
  job.pool = nil
  job.released = true
end

local function call_callback(job, name, ...)
  local callback = job.spec and job.spec[name]
  if callback then
    local started = now()
    local ok, err = pcall(callback, ...)
    local elapsed_ms = (now() - started) * 1000
    if not ok then
      log_quiet("worker_pool callback %s for job %s failed: %s", tostring(name), tostring(job.id), tostring(err))
    end
    return elapsed_ms, true
  end
  return 0, false
end

local function is_terminal_type(message_type)
  return message_type == "final"
      or message_type == "complete"
      or message_type == "error"
      or message_type == "cancelled"
end

function worker_pool.new(options)
  options = options or {}
  local self = setmetatable({}, worker_pool)
  self.id = unique_name(options.name or "pool")
  self.name = options.name or self.id
  self.worker_count = math.max(1, math.floor(options.worker_count or default_worker_count()))
  self.next_job_id = 0
  self.next_worker = 0
  self.workers = {}
  self.jobs = {}
  self.native_jobs = {}
  self.native = nil
  self.closed = false
  self.diagnostics = {
    submitted = 0,
    completed = 0,
    cancelled = 0,
    failed = 0,
    stale = 0,
    messages = 0,
  }

  for i = 1, self.worker_count do
    local input_name = unique_name(self.name .. "-in-" .. i)
    local output_name = unique_name(self.name .. "-out-" .. i)
    local input = thread.get_channel(input_name)
    local output = thread.get_channel(output_name)
    input:clear()
    output:clear()
    local worker, err = thread.create("worker-pool-" .. tostring(i), function(opts)
      local bootstrap = require "core.worker_bootstrap"
      return bootstrap.run(opts)
    end, {
      worker_id = i,
      input_name = input_name,
      output_name = output_name,
    })
    assert(worker, err)
    self.workers[i] = {
      id = i,
      thread = worker,
      input_name = input_name,
      output_name = output_name,
      input = input,
      output = output,
      ready = false,
      shutdown = false,
    }
  end

  log_quiet("worker_pool %s started with %d Lua worker(s)", tostring(self.name), self.worker_count)
  return self
end

function worker_pool.system()
  if not system_pool or system_pool.closed then
    system_pool = worker_pool.new({ name = "system" })
  end
  return system_pool
end

function worker_pool.current_system()
  if system_pool and not system_pool.closed then return system_pool end
end

function worker_pool.shutdown_system(options)
  if system_pool then
    system_pool:shutdown(options)
    system_pool = nil
  end
end

function worker_pool:choose_worker(spec)
  local loads = {}
  for _, worker in ipairs(self.workers) do loads[worker.id] = 0 end
  for _, job in pairs(self.jobs) do
    if not job.finished_at and job.worker_id and loads[job.worker_id] ~= nil then
      loads[job.worker_id] = loads[job.worker_id] + 1
    end
  end

  local best
  local best_load
  local worker_count = #self.workers
  local first_worker, last_worker = 1, worker_count
  if worker_count > 1 and spec and spec.priority == "background" then
    first_worker = 2
  elseif worker_count > 1 and spec and spec.priority == "interactive" then
    last_worker = 1
  end
  local lane_count = last_worker - first_worker + 1
  for offset = 1, lane_count do
    local idx = first_worker + ((self.next_worker + offset - first_worker) % lane_count)
    local worker = self.workers[idx]
    local load = loads[worker.id] or 0
    if not best or load < best_load then
      best = worker
      best_load = load
      if load == 0 then break end
    end
  end
  self.next_worker = best and best.id or ((self.next_worker % worker_count) + 1)
  return best or self.workers[self.next_worker]
end

function worker_pool:native_pool()
  if not native_pool then return nil, "native-unavailable" end
  if not self.native then
    local ok, pool_or_err = pcall(native_pool.new, {
      name = tostring(self.name) .. "-native",
      worker_count = self.worker_count,
    })
    if not ok or not pool_or_err then return nil, pool_or_err or "native-create-failed" end
    self.native = pool_or_err
  end
  return self.native
end

function worker_pool:submit(spec)
  assert(type(spec) == "table", "worker_pool submit expects a job spec table")
  if self.closed then return nil, "closed" end
  assert(type(spec.kind) == "string" and spec.kind ~= "", "worker_pool job kind is required")

  self.next_job_id = self.next_job_id + 1
  local job_id = self.next_job_id
  if spec.native then
    local native, native_err = self:native_pool()
    if not native then return nil, native_err or "native-unavailable" end
    local native_spec = common.merge({}, spec.native_payload or spec.payload or {})
    native_spec.kind = spec.native_kind or native_spec.kind or spec.kind
    local native_handle, err = native:submit(native_spec)
    if not native_handle then return nil, err or "native-submit-failed" end
    local native_status = native:status(native_handle) or {}
    local native_id = native_status.id
    local handle = {
      id = job_id,
      pool_id = self.id,
      worker_id = "native",
      kind = spec.kind,
      generation = spec.generation,
      project_paths_generation = spec.project_paths_generation,
      phase = spec.phase,
    }
    self.jobs[job_id] = {
      pool = self,
      id = job_id,
      handle = handle,
      spec = spec,
      backend = "native",
      native_handle = native_handle,
      native_id = native_id,
      worker_id = "native",
      status = "queued",
      submitted_at = now(),
      started_at = nil,
      finished_at = nil,
      messages = 0,
    }
    if native_id then self.native_jobs[native_id] = job_id end
    self.diagnostics.submitted = self.diagnostics.submitted + 1
    log_quiet("worker_pool %s submitted native job %d kind=%s native_id=%s", tostring(self.name), job_id, spec.kind, tostring(native_id))
    return copy_handle(handle)
  end

  local worker = self:choose_worker(spec)
  local cancel_channel_name = unique_name(self.name .. "-cancel-" .. job_id)
  local cancel_channel = thread.get_channel(cancel_channel_name)
  cancel_channel:clear()
  local native_cancel_token
  local native_cancel_token_name
  if native_pool and native_pool.new_cancel_token then
    local ok, token_or_err = pcall(native_pool.new_cancel_token)
    if ok and token_or_err then
      native_cancel_token = token_or_err
      native_cancel_token_name = native_cancel_token:name()
    else
      log_quiet("worker_pool %s failed to create native cancel token for job %d: %s", tostring(self.name), job_id, tostring(token_or_err))
    end
  end

  local handle = {
    id = job_id,
    pool_id = self.id,
    worker_id = worker.id,
    kind = spec.kind,
    generation = spec.generation,
    project_paths_generation = spec.project_paths_generation,
    phase = spec.phase,
  }

  self.jobs[job_id] = {
    pool = self,
    id = job_id,
    handle = handle,
    spec = spec,
    worker_id = worker.id,
    cancel_channel = cancel_channel,
    cancel_channel_name = cancel_channel_name,
    native_cancel_token = native_cancel_token,
    native_cancel_token_name = native_cancel_token_name,
    status = "queued",
    submitted_at = now(),
    started_at = nil,
    finished_at = nil,
    messages = 0,
  }

  worker.input:push({
    type = "run",
    job_id = job_id,
    kind = spec.kind,
    generation = spec.generation,
    project_paths_generation = spec.project_paths_generation,
    phase = spec.phase,
    payload = spec.payload or {},
    cancel_channel_name = cancel_channel_name,
    cancel_token_name = native_cancel_token_name,
  })

  self.diagnostics.submitted = self.diagnostics.submitted + 1
  log_quiet("worker_pool %s submitted job %d kind=%s worker=%d", tostring(self.name), job_id, spec.kind, worker.id)
  return copy_handle(handle)
end

function worker_pool:cancel(handle)
  local job = handle and self.jobs[handle.id]
  if not job or job.finished_at then
    return false
  end
  job.cancel_requested = true
  if job.status == "queued" then job.status = "cancelling" end
  if job.backend == "native" and self.native and job.native_handle then
    local ok, result = pcall(function() return self.native:cancel(job.native_handle) end)
    if not ok then
      log_quiet("worker_pool native cancel for job %s failed: %s", tostring(job.id), tostring(result))
    end
    log_quiet("worker_pool %s cancelled native job %d kind=%s", tostring(self.name), job.id, tostring(job.handle.kind))
    return ok and result or false
  end
  if job.native_cancel_token then
    local ok, err = pcall(function() job.native_cancel_token:cancel() end)
    if not ok then log_quiet("worker_pool native cancel token for job %s failed: %s", tostring(job.id), tostring(err)) end
  end
  if job.cancel_channel then
    job.cancel_channel:push({ type = "cancel", job_id = job.id, time = now() })
  end
  local worker = self.workers[job.worker_id]
  if worker then
    worker.input:push({ type = "cancel", job_id = job.id })
  end
  log_quiet("worker_pool %s cancelled job %d kind=%s", tostring(self.name), job.id, tostring(job.handle.kind))
  return true
end

function worker_pool:status(handle)
  local job = handle and self.jobs[handle.id]
  if not job then return nil end
  if job.backend == "native" and self.native and job.native_handle and not job.finished_at then
    local ok, native_status = pcall(function() return self.native:status(job.native_handle) end)
    if ok and native_status and native_status.status then job.status = native_status.status end
  end
  return {
    id = job.id,
    kind = job.handle.kind,
    status = job.status,
    generation = job.handle.generation,
    project_paths_generation = job.handle.project_paths_generation,
    phase = job.handle.phase,
    worker_id = job.worker_id,
    submitted_at = job.submitted_at,
    started_at = job.started_at,
    finished_at = job.finished_at,
    cancel_requested = not not job.cancel_requested,
    messages = job.messages,
  }
end

function worker_pool:is_stale(job, message)
  if not job then return true end
  if message.generation ~= nil and job.handle.generation ~= nil and message.generation ~= job.handle.generation then
    return true
  end
  if message.project_paths_generation ~= nil
    and job.handle.project_paths_generation ~= nil
    and message.project_paths_generation ~= job.handle.project_paths_generation
  then
    return true
  end
  local stale = job.spec and job.spec.is_stale
  if stale then
    local ok, result = pcall(stale, message, job.handle)
    if not ok then
      log_quiet("worker_pool stale predicate for job %s failed: %s", tostring(job.id), tostring(result))
      return true
    end
    return not not result
  end
  return false
end

function worker_pool:dispatch_message(message)
  local dispatch_started = now()
  local stats = {
    message_type = type(message) == "table" and message.type or "invalid",
    callback_ms = 0,
    callbacks = 0,
    slowest_callback_ms = 0,
    slowest_callback_name = "",
  }

  local function finish(result)
    stats.dispatch_ms = (now() - dispatch_started) * 1000
    return result, stats
  end

  local function invoke(job, name, ...)
    local elapsed, ran = call_callback(job, name, ...)
    if ran then
      stats.callback_ms = stats.callback_ms + elapsed
      stats.callbacks = stats.callbacks + 1
      local label = string.format(
        "%s:%s:%s:%s",
        tostring(job.handle.kind or ""),
        tostring(job.handle.phase or ""),
        tostring(message and message.type or ""),
        tostring(name)
      )
      if elapsed > stats.slowest_callback_ms then
        stats.slowest_callback_ms = elapsed
        stats.slowest_callback_name = label
      end
    end
  end

  if type(message) ~= "table" then return finish(false) end
  self.diagnostics.messages = self.diagnostics.messages + 1

  if message.type == "worker_ready" then
    local worker = self.workers[message.worker_id]
    if worker then worker.ready = true end
    return finish(true)
  end

  if message.type == "worker_shutdown" then
    local worker = self.workers[message.worker_id]
    if worker then worker.shutdown = true end
    return finish(true)
  end

  local job = message.job_id and self.jobs[message.job_id]
  if not job then return finish(false) end

  job.messages = job.messages + 1
  if job.status == "queued" or job.status == "cancelling" then
    job.status = job.cancel_requested and "cancelling" or "running"
    job.started_at = job.started_at or now()
  end

  if self:is_stale(job, message) then
    self.diagnostics.stale = self.diagnostics.stale + 1
    invoke(job, "on_stale", message, job.handle)
    if is_terminal_type(message.type) then
      mark_terminal(job, "stale")
      release_terminal_job(job)
    end
    return finish(true)
  end

  if message.type == "progress" then
    invoke(job, "on_progress", message, job.handle)
  elseif message.type == "result" or message.type == "chunk" then
    invoke(job, "on_result", message, job.handle)
  elseif message.type == "log" then
    invoke(job, "on_log", message, job.handle)
  elseif message.type == "error" then
    self.diagnostics.failed = self.diagnostics.failed + 1
    mark_terminal(job, "failed")
    invoke(job, "on_error", message, job.handle)
    release_terminal_job(job)
  elseif message.type == "cancelled" then
    self.diagnostics.cancelled = self.diagnostics.cancelled + 1
    mark_terminal(job, "cancelled")
    invoke(job, "on_cancelled", message, job.handle)
    release_terminal_job(job)
  elseif message.type == "final" or message.type == "complete" then
    self.diagnostics.completed = self.diagnostics.completed + 1
    mark_terminal(job, "complete")
    if message.type == "final" then
      invoke(job, "on_result", message, job.handle)
    end
    invoke(job, "on_complete", message, job.handle)
    release_terminal_job(job)
  end

  return finish(true)
end

function worker_pool:drain(options)
  options = options or {}
  local max_messages = options.max_messages or DEFAULT_DRAIN_MAX_MESSAGES
  local max_ms = options.max_ms or DEFAULT_DRAIN_BUDGET_MS
  local started = now()
  local deadline = started + (math.max(0, max_ms) / 1000)
  local count = 0
  local stats = {
    messages = 0,
    dispatch_ms = 0,
    callback_ms = 0,
    callbacks = 0,
    slowest_dispatch_ms = 0,
    slowest_message_type = "",
    slowest_callback_ms = 0,
    slowest_callback_name = "",
  }

  local function note_dispatch(message_stats)
    if not message_stats then return end
    stats.dispatch_ms = stats.dispatch_ms + (message_stats.dispatch_ms or 0)
    stats.callback_ms = stats.callback_ms + (message_stats.callback_ms or 0)
    stats.callbacks = stats.callbacks + (message_stats.callbacks or 0)
    if (message_stats.dispatch_ms or 0) > stats.slowest_dispatch_ms then
      stats.slowest_dispatch_ms = message_stats.dispatch_ms or 0
      stats.slowest_message_type = message_stats.message_type or ""
    end
    if (message_stats.slowest_callback_ms or 0) > stats.slowest_callback_ms then
      stats.slowest_callback_ms = message_stats.slowest_callback_ms or 0
      stats.slowest_callback_name = message_stats.slowest_callback_name or ""
    end
  end

  local function finish()
    stats.messages = count
    stats.elapsed_ms = (now() - started) * 1000
    self.last_drain_stats = stats
    return count, stats
  end

  while count < max_messages do
    local did_work = false
    if self.native then
      local ok, messages = pcall(function() return self.native:drain({ max_messages = 1 }) end)
      local message = ok and messages and messages[1]
      if message ~= nil then
        local native_job_id = message.job_id
        local job_id = self.native_jobs[native_job_id]
        if job_id then
          message.native_job_id = native_job_id
          message.job_id = job_id
          message.worker_id = "native"
          local _, message_stats = self:dispatch_message(message)
          note_dispatch(message_stats)
          if is_terminal_type(message.type) then self.native_jobs[native_job_id] = nil end
        end
        count = count + 1
        did_work = true
        if count >= max_messages then return finish() end
        if max_ms >= 0 and now() >= deadline then return finish() end
      end
    end
    for _, worker in ipairs(self.workers) do
      local message = worker.output:first()
      if message ~= nil then
        worker.output:pop()
        local _, message_stats = self:dispatch_message(message)
        note_dispatch(message_stats)
        count = count + 1
        did_work = true
        if count >= max_messages then return finish() end
        if max_ms >= 0 and now() >= deadline then return finish() end
      end
    end
    if not did_work then break end
  end

  return finish()
end

function worker_pool:shutdown(options)
  options = options or {}
  if self.closed then return true end
  self.closed = true

  if options.cancel_running ~= false then
    for _, job in pairs(self.jobs) do
      if not job.finished_at then self:cancel(job.handle) end
    end
  end

  for _, worker in ipairs(self.workers) do
    worker.input:push({ type = "shutdown" })
  end

  local timeout_ms = options.timeout_ms or 1000
  local deadline = now() + math.max(0, timeout_ms) / 1000
  repeat
    self:drain({ max_ms = 2, max_messages = options.max_messages or 256 })
    local all_shutdown = true
    for _, worker in ipairs(self.workers) do
      if not worker.shutdown then
        all_shutdown = false
        break
      end
    end
    if all_shutdown then break end
    if coroutine.isyieldable and coroutine.isyieldable() then
      coroutine.yield(0.001)
    elseif system and system.sleep then
      system.sleep(0.001)
    end
  until now() >= deadline

  for _, worker in ipairs(self.workers) do
    if worker.shutdown then
      local ok, err = pcall(function() return worker.thread:wait() end)
      if not ok then
        log_quiet("worker_pool %s worker %d wait failed: %s", tostring(self.name), worker.id, tostring(err))
      end
    else
      log_quiet("worker_pool %s worker %d did not shut down within %dms; leaving thread detached by runtime", tostring(self.name), worker.id, timeout_ms)
    end
    worker.input:clear()
    worker.output:clear()
  end

  if self.native then
    local ok, err = pcall(function() self.native:shutdown({ cancel_running = options.cancel_running ~= false }) end)
    if not ok then log_quiet("worker_pool %s native shutdown failed: %s", tostring(self.name), tostring(err)) end
    self.native = nil
    self.native_jobs = {}
  end

  for _, job in pairs(self.jobs) do
    if job.cancel_channel then job.cancel_channel:clear() end
    job.native_cancel_token = nil
    job.native_cancel_token_name = nil
  end
  log_quiet("worker_pool %s shut down", tostring(self.name))
  return true
end

function worker_pool.diagnostics(pool)
  return common.merge({}, pool and pool.diagnostics or {})
end

return worker_pool
