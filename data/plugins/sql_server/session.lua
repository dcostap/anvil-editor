-- A SQL Session is one server connection for one SQL Editor's Buffer, like a
-- DbVisualizer SQL Commander tab. Temporary tables, SET options and open
-- transactions stay between runs. The first run opens it. Disconnect, a
-- settings change and Buffer close end it; the server then rolls back.
local core = require "core"
local backend = require "plugins.sql_server.backend"
local M = {}
-- Buffer -> { id, connection, generation, transaction_count, database, busy }
local sessions = setmetatable({}, { __mode = "k" })

local function changed() core.redraw = true end

function M.get(buffer) return sessions[buffer] end

-- The session ID for a run, or nil to open a new session.
function M.for_run(buffer, c)
  local s = sessions[buffer]
  if s and (s.connection ~= c or s.generation ~= c.generation) then M.close(buffer); s = nil end
  return s and s.id
end

function M.close(buffer)
  local s = sessions[buffer]
  if not s then return end
  sessions[buffer] = nil
  buffer:remove_metadata_listener("sql_session")
  backend.close_session(s.id)
  core.log_quiet("SQL Server: closed session connection=%s open_transactions=%s", s.connection.id, tostring(s.transaction_count))
  changed()
end

-- Takes the session that a run reports. A run that the user left keeps no session.
function M.adopt(buffer, c, generation, data, keep)
  local s = sessions[buffer]
  if data.session_lost then
    if s then sessions[buffer] = nil; buffer:remove_metadata_listener("sql_session") end
    changed()
    return
  end
  if not data.session then return end
  if not keep or c.generation ~= generation then
    if not (s and s.id == data.session) then backend.close_session(data.session) end
    return
  end
  if not s or s.id ~= data.session then
    if s then M.close(buffer) end
    s = { id = data.session, connection = c, generation = generation }
    sessions[buffer] = s
    buffer:add_metadata_listener("sql_session", function(_, event)
      if event.kind == "close" then M.close(buffer) end
    end)
  end
  s.transaction_count = data.transaction_count
  s.database = data.database or s.database
  changed()
end

function M.close_connection(c)
  local buffers = {}
  for buffer, s in pairs(sessions) do if s.connection == c then buffers[#buffers + 1] = buffer end end
  for _, buffer in ipairs(buffers) do M.close(buffer) end
end

-- Buffers whose sessions may hold uncommitted changes. An unknown count, such
-- as after a cancelled run, counts as open.
function M.pending(c)
  local buffers = {}
  for buffer, s in pairs(sessions) do
    if (not c or s.connection == c) and s.transaction_count ~= 0 then buffers[#buffers + 1] = buffer end
  end
  return buffers
end

function M.end_transaction(buffer, commit, done)
  local s = sessions[buffer]
  if not s or s.busy or (buffer.sql_execution and buffer.sql_execution.active) then
    if done then done(false, s and "Wait for the running SQL to finish." or "This SQL Query has no session.") end
    return false
  end
  s.busy = true
  changed()
  local handle, err = backend.end_transaction(s.id, commit, function(count, error, ended)
    s.busy = false
    if sessions[buffer] == s then
      s.transaction_count = count
      if ended then sessions[buffer] = nil; buffer:remove_metadata_listener("sql_session") end
    end
    core.log_quiet("SQL Server: %s connection=%s ok=%s", commit and "commit" or "rollback", s.connection.id, tostring(count ~= nil))
    if error then core.error("%s", error) end
    changed()
    if done then done(count ~= nil, error) end
  end)
  if not handle then
    s.busy = false
    core.error("%s", err or "Could not start the transaction request.")
    if done then done(false, err) end
  end
  return handle ~= nil
end

-- Asks what to do with open transactions before an action that ends their
-- sessions, like DbVisualizer's Pending Transactions question. Commit and Roll
-- Back finish each transaction first; Cancel keeps everything. A failed
-- Commit or Roll Back also cancels the action.
function M.confirm(buffers, proceed, cancel)
  if #buffers == 0 then return proceed() end
  cancel = cancel or function() end
  local text = #buffers == 1 and "A SQL Query has an open transaction. Its changes are not committed."
    or string.format("%d SQL Queries have open transactions. Their changes are not committed.", #buffers)
  core.nag_view:show("Open Transaction", text, {
    { text = "Commit", default_yes = true },
    { text = "Roll Back" },
    { text = "Cancel", default_no = true },
  }, function(item)
    if item.text == "Cancel" then return cancel() end
    local remaining, failed = #buffers, false
    for _, buffer in ipairs(buffers) do
      M.end_transaction(buffer, item.text == "Commit", function(ok)
        failed = failed or not ok
        remaining = remaining - 1
        if remaining > 0 then return end
        if failed then cancel() else proceed() end
      end)
    end
  end)
end

return M
