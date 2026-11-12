-- Runs only in a worker Lua state. No Editor or UI objects enter this module.
local M = {}
function M.run(payload, context)
  if context.cancelled() and payload.operation ~= "close_session" then return end
  local result, err
  if payload.operation == "execute" then
    result = require("sql_server_native").execute(payload.options, payload.text, {
      session = payload.session, autocommit = payload.autocommit, explain = payload.explain,
      max_rows = payload.max_rows, timeout = payload.timeout_seconds, token = context.cancel_token_name })
    payload.options.password = nil
    for _, model in ipairs(result.results) do
      model.distinct_values = require("plugins.tabular_data_preview.parser").distinct_values(model, context.cancelled)
      if not model.distinct_values then break end
    end
    -- A cancelled job can send only a cancel message. It still names the
    -- session, so the UI can use or close it.
    if context.cancelled() then
      context.send { type = "cancelled", payload = { value = { cancelled = true, session = result.session,
        session_lost = result.session_lost, transaction_count = result.transaction_count, messages = result.messages } } }
      return
    end
  elseif payload.operation == "end_transaction" then
    local count, ended
    count, err, ended = require("sql_server_native").end_transaction(payload.session, payload.commit)
    result = { transaction_count = count, ended = ended }
  elseif payload.operation == "close_session" then
    require("sql_server_native").close_session(payload.session)
    result = true
  elseif payload.operation == "definition" then
    result, err = require("sql_server_native").read_definition(payload.options, payload.schema, payload.name, context.cancel_token_name)
    payload.options.password = nil
  elseif payload.operation == "columns" then
    result, err = require("sql_server_native").read_columns(payload.options, payload.schema, payload.name)
    payload.options.password = nil
  elseif payload.operation == "schema" then
    result, err = require("sql_server_native").read_schema(payload.options)
    payload.options.password = nil
  else
    USERDIR = payload.userdir
    local storage = require "core.storage"
    local module = payload.module or "sql_server"
    if payload.operation == "load" then
      result, err = storage.load(module, payload.key)
      if result == nil and not err then result = module == "sql_server" and { connections = {} } or {} end
    elseif payload.operation == "save" then
      result, err = storage.save(module, payload.key, payload.value)
    else
      error("Unknown SQL worker operation")
    end
  end
  context.send { type = "final", payload = { value = result, error = err } }
end
return M
