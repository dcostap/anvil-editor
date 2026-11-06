local worker_pool = require "core.worker_pool"
local M = {}

-- The database boundary. Tests replace this function, not the Editor or completion.
function M.read_schema(options, callback)
  return worker_pool.named("sql-server", { worker_count = 1 }):submit {
    kind = "plugins.sql_server.worker",
    payload = { operation = "schema", options = options },
    on_result = function(message)
      local result = message.payload or {}
      callback(result.value, result.error)
    end,
    on_error = function() callback(nil, "SQL Server worker failed.") end,
  }
end
return M
