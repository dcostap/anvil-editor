-- Worker-side entrypoint for core.worker_pool Lua workers.
--
-- This module intentionally avoids requiring core/UI modules. It runs inside a
-- separate Lua state created by thread.create and communicates through channels
-- using small, envelope-shaped messages.

local native_ok, native_pool = pcall(require, "worker_pool_native")
if not native_ok then native_pool = nil end

local worker_bootstrap = {}

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

local function channel_first(channel)
  if not channel then return nil end
  return channel:first()
end

local function cancelled(cancel_channel, cancel_token)
  if cancel_token and cancel_token:cancelled() then return true end
  return channel_first(cancel_channel) ~= nil
end

local function handler_module_name(kind)
  kind = tostring(kind or "")
  if kind:find("%.", 1) then return kind end
  return "core.workers." .. kind
end

local function send(output, msg)
  -- Use supply instead of push so a worker cannot enqueue unbounded output while
  -- the UI is intentionally draining under a frame budget. The worker blocks
  -- until the main thread pops this message, providing simple backpressure for
  -- the Lua facade.
  output:supply(msg)
end

function worker_bootstrap.run(options)
  options = options or {}
  local worker_id = options.worker_id or 0
  local input = thread.get_channel(assert(options.input_name, "missing input channel"))
  local output = thread.get_channel(assert(options.output_name, "missing output channel"))
  local handler_cache = {}

  send(output, {
    type = "worker_ready",
    worker_id = worker_id,
    time = now(),
  })

  while true do
    local message = input:wait()
    input:pop()

    if type(message) == "table" and message.type == "shutdown" then
      send(output, {
        type = "worker_shutdown",
        worker_id = worker_id,
        time = now(),
      })
      return 0
    end

    if type(message) == "table" and message.type == "run" then
      local cancel_channel = message.cancel_channel_name
        and thread.get_channel(message.cancel_channel_name)
        or nil
      local cancel_token
      if native_pool and message.cancel_token_name then
        local ok, token = pcall(native_pool.open_cancel_token, message.cancel_token_name)
        if ok then cancel_token = token end
      end
      local terminal_sent = false

      local function envelope(out)
        out = out or {}
        out.job_id = out.job_id or message.job_id
        out.kind = out.kind or message.kind
        out.generation = out.generation or message.generation
        out.project_paths_generation = out.project_paths_generation or message.project_paths_generation
        out.phase = out.phase or message.phase
        out.worker_id = out.worker_id or worker_id
        out.time = out.time or now()
        if out.type == "final" or out.type == "complete" or out.type == "error" or out.type == "cancelled" then
          terminal_sent = true
        end
        return out
      end

      if cancelled(cancel_channel, cancel_token) then
        send(output, envelope({ type = "cancelled", payload = { before_start = true } }))
      else
        local ok, err = pcall(function()
          local module_name = handler_module_name(message.kind)
          local handler = handler_cache[module_name]
          if handler == nil then
            handler = assert(require(module_name))
            handler_cache[module_name] = handler
          end
          assert(type(handler.run) == "function", module_name .. ".run must be a function")

          handler.run(message.payload or {}, {
            job_id = message.job_id,
            kind = message.kind,
            generation = message.generation,
            project_paths_generation = message.project_paths_generation,
            phase = message.phase,
            worker_id = worker_id,
            cancel_token_name = message.cancel_token_name,
            cancelled = function() return cancelled(cancel_channel, cancel_token) end,
            send = function(out)
              if cancelled(cancel_channel, cancel_token) and out and out.type ~= "cancelled" then
                return false, "cancelled"
              end
              send(output, envelope(out))
              return true
            end,
          })
        end)

        if not ok then
          send(output, envelope({ type = "error", error = tostring(err) }))
        elseif not terminal_sent then
          if cancelled(cancel_channel, cancel_token) then
            send(output, envelope({ type = "cancelled" }))
          else
            send(output, envelope({ type = "complete" }))
          end
        end
        cancel_token = nil
      end
    end
  end
end

return worker_bootstrap
