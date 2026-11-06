-- Runs only in a worker Lua state. No Editor or UI objects enter this module.
local M = {}
function M.run(payload, context)
  if context.cancelled() then return end
  local result, err
  if payload.operation == "execute" then
    result = require("sql_server_native").execute(payload.options, payload.text,
      payload.max_rows, payload.timeout_seconds, context.cancel_token_name)
    payload.options.password = nil
    for _, model in ipairs(result.results) do
      model.distinct_values = require("plugins.tabular_data_preview.parser").distinct_values(model, context.cancelled)
      if not model.distinct_values then return end
    end
  elseif payload.operation == "schema" then
    result, err = require("sql_server_native").read_schema(payload.options)
    payload.options.password = nil
  else
    USERDIR = payload.userdir
    local storage = require "core.storage"
    if payload.operation == "load" then
      result, err = storage.load("sql_server", payload.key)
      if result == nil and not err then result = { connections = {} } end
    elseif payload.operation == "save" then
      result, err = storage.save("sql_server", payload.key, payload.value)
    else
      error("Unknown SQL worker operation")
    end
  end
  context.send { type = "final", payload = { value = result, error = err } }
end
return M
