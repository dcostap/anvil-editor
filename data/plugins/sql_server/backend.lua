local worker_pool = require "core.worker_pool"
local M = {}
local function submit(pool, spec)
  local handle, err = pool:submit(spec)
  if not handle then return nil, err end
  return { cancel = function() return pool:cancel(handle) end }
end

-- The database boundary. Tests replace this function, not the Editor or completion.
function M.read_schema(options, callback)
  return submit(worker_pool.named("sql-server", { worker_count = 1 }), {
    kind = "plugins.sql_server.worker",
    payload = { operation = "schema", options = options },
    on_result = function(message)
      local result = message.payload or {}
      callback(result.value, result.error)
    end,
    on_error = function() callback(nil, "SQL Server worker failed.") end,
  })
end
function M.execute(options, text, callback)
  local config = require "core.config"
  return submit(worker_pool.named("sql-execution", { worker_count = 2 }), {
    kind = "plugins.sql_server.worker",
    payload = { operation = "execute", options = options, text = text,
      max_rows = config.plugins.sql_server.max_rows, timeout_seconds = config.plugins.sql_server.timeout_seconds },
    on_result = function(message) callback(message.payload.value) end,
    on_error = function() callback({ error = "SQL execution worker failed." }) end,
    on_cancelled = function() callback({ cancelled = true }) end,
  })
end
return M
