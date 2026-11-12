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
local function execution_pool() return worker_pool.named("sql-execution", { worker_count = 2 }) end
-- Settings: session, autocommit, explain and max_rows. A result can name the
-- session that the run opened.
function M.execute(options, text, callback, settings)
  local config = require "core.config"
  settings = settings or {}
  return submit(execution_pool(), {
    kind = "plugins.sql_server.worker",
    payload = { operation = "execute", options = options, text = text, session = settings.session,
      autocommit = settings.autocommit ~= false, explain = settings.explain == true,
      max_rows = settings.max_rows or config.plugins.sql_server.max_rows,
      timeout_seconds = config.plugins.sql_server.timeout_seconds },
    on_result = function(message) callback(message.payload.value) end,
    on_error = function() callback({ error = "SQL execution worker failed." }) end,
    on_cancelled = function(message)
      local value = message.payload and message.payload.value
      callback(type(value) == "table" and value or { cancelled = true })
    end,
  })
end
-- Calls back with the new transaction count, or nil, an error and whether the
-- session ended.
function M.end_transaction(session, commit, callback)
  return submit(execution_pool(), {
    kind = "plugins.sql_server.worker",
    payload = { operation = "end_transaction", session = session, commit = commit },
    on_result = function(message)
      local value = message.payload.value or {}
      callback(value.transaction_count, message.payload.error, value.ended)
    end,
    on_error = function() callback(nil, "SQL transaction worker failed.") end,
  })
end
-- The server rolls back an open transaction when its session closes.
function M.close_session(session)
  return submit(execution_pool(), {
    kind = "plugins.sql_server.worker",
    payload = { operation = "close_session", session = session },
  })
end
-- The columns of one table or view, for a database with more columns than the catalog loads.
function M.read_columns(options, object, callback)
  return submit(worker_pool.named("sql-server", { worker_count = 1 }), {
    kind = "plugins.sql_server.worker",
    payload = { operation = "columns", options = options, schema = object.schema, name = object.name },
    on_result = function(message) callback(message.payload.value, message.payload.error) end,
    on_error = function() callback(nil, "SQL column worker failed.") end,
  })
end
function M.read_definition(options, object, callback)
  return submit(worker_pool.named("sql-server", { worker_count = 1 }), {
    kind = "plugins.sql_server.worker",
    payload = { operation = "definition", options = options, schema = object.schema, name = object.name },
    on_result = function(message) callback(message.payload.value, message.payload.error) end,
    on_error = function() callback(nil, "SQL definition worker failed.") end,
  })
end
return M
