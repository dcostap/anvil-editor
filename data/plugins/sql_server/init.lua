-- mod-version:3
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local panes = require "core.panes"
local worker_pool = require "core.worker_pool"
local backend = require "plugins.sql_server.backend"
local session = require "plugins.sql_server.session"
local M = { connections = {}, generation = 0 }
local loaded, loading, storage_key, saving, pending_save
local serial = 0
local load_generation = 0
local passwords, active_runs = {}, {}

local function cancel_run(run)
  if not run or not run.active or run.cancelled then return false end
  run.cancelled = true
  if run.view and not run.view.closed then
    run.view.message, run.view.cancel_query = "Cancelling SQL…", nil
    core.redraw = true
  end
  if run.handle then run.handle:cancel() end
  return true
end

local function changed()
  M.generation = M.generation + 1
  core.redraw = true
end
local function store_job(operation, value, callback)
  return worker_pool.named("sql-settings", { worker_count = 1 }):submit {
    kind = "plugins.sql_server.worker",
    payload = { operation = operation, userdir = USERDIR, key = storage_key, value = value },
    on_result = function(message)
      local result = message.payload or {}
      callback(result.value, result.error)
    end,
    on_error = function() callback(nil, "Database settings worker failed.") end,
  }
end
local function snapshot()
  local entries = {}
  for i, c in ipairs(M.connections) do
    entries[i] = { id = c.id, name = c.name, server = c.server, database = c.database,
      integrated = c.integrated, user = c.user, trust_certificate = c.trust_certificate, encrypt = c.encrypt }
  end
  return { connections = entries }
end
local function save()
  pending_save = true
  if saving then return end
  pending_save, saving = false, true
  local handle, err = store_job("save", snapshot(), function(ok, error)
    saving = false
    M.save_error = not ok and (error or "Could not save database settings.") or nil
    if M.save_error then core.error("%s", M.save_error) end
    changed()
    if pending_save then save() end
  end)
  if not handle then saving = false; M.save_error = tostring(err); core.error("%s", M.save_error) end
end
function M.ready() return loaded == true end
function M.is_saving() return saving or pending_save or require("plugins.sql_server.history").is_saving() end
-- Only accepted shutdown or a Project switch may wait for file writes.
local function flush_settings()
  local deadline = system.get_time() + 15
  while M.is_saving() and system.get_time() < deadline do
    worker_pool.named("sql-settings"):drain({ max_ms = 2, max_messages = 64 })
    system.sleep(0.001)
  end
  if M.is_saving() or M.save_error then
    core.error("Database settings did not finish saving. Keep Anvil open and try again.")
    return false
  end
  return true
end
function M.load()
  if loaded or loading then return end
  loading = true
  load_generation = load_generation + 1
  local generation = load_generation
  storage_key = require("plugins.untitled_recovery").project_key(require("core.machine_project").root_key(core.root_project().path))
  local handle, err = store_job("load", nil, function(value, error)
    if generation ~= load_generation then return end
    loading = false
    if error then M.load_error = error; changed(); return end
    local entries = type(value) == "table" and value.connections
    if type(entries) ~= "table" then M.load_error = "Invalid database settings."; changed(); return end
    local ids = {}
    for _, c in ipairs(entries) do
      if type(c) ~= "table" or type(c.id) ~= "string" or ids[c.id] then
        M.load_error = "Invalid database connection record."; changed(); return
      end
      for _, key in ipairs({ "name", "server", "database", "user" }) do
        if type(c[key]) ~= "string" then M.load_error = "Invalid database connection record."; changed(); return end
      end
      ids[c.id] = true
    end
    for _, c in ipairs(entries) do
      c.password, c.catalog, c.job = nil, nil, nil
      c.state, c.generation = "Disconnected", 0
    end
    M.connections, loaded, M.load_error = entries, true, nil
    changed()
  end)
  if not handle then loading = false; M.load_error = tostring(err); changed() end
end
function M.find(id)
  for _, c in ipairs(M.connections) do if c.id == id then return c end end
end
function M.add_connection()
  if not loaded then return nil end
  serial = serial + 1
  local c = { id = string.format("%s-%d-%d", system.get_process_id(), system.get_time() * 1000000, serial),
    name = "New Connection", server = "", database = "", integrated = true, user = "", trust_certificate = false, encrypt = true,
    state = "Disconnected", generation = 0 }
  M.connections[#M.connections + 1] = c
  save(); changed()
  return c
end
function M.disconnect(id)
  local c = M.find(id)
  if not c then return false end
  c.generation = c.generation + 1
  passwords[c] = nil
  local source = package.loaded["plugins.sql_server.source"]
  if source then source.cancel_connection(c) end
  for run in pairs(active_runs) do if run.connection == c then cancel_run(run) end end
  session.close_connection(c)
  if c.job then c.job:cancel(); c.job = nil end
  if c.refreshing then c.refreshing:cancel(); c.refreshing = nil end
  c.catalog, c.password, c.error, c.state = nil, nil, nil, "Disconnected"
  changed()
  core.log_quiet("SQL Server: disconnected connection=%s", c.id)
  return true
end
function M.update(id, key, value)
  local c = M.find(id)
  if not c then return false, "Connection not found." end
  if key == "integrated" or key == "trust_certificate" or key == "encrypt" then
    if type(value) ~= "boolean" then return false end
  elseif key == "name" or key == "server" or key == "database" or key == "user" then
    if type(value) ~= "string" or #value > 1024 or value:find("[%z\r\n]") then return false, "Invalid connection field." end
    if key == "name" and not value:find("%S") then return false, "Enter a name." end
  else return false end
  if c[key] == value then return true end
  if #session.pending(c) > 0 then return false, "Commit or roll back the open transactions first." end
  M.disconnect(id)
  c[key] = value
  save(); changed()
  return true
end
-- Explicit actions that end sessions ask about open transactions first.
function M.after_transactions(id, action)
  local c = M.find(id)
  if not c then return false end
  session.confirm(session.pending(c), action)
  return true
end
function M.remove(id)
  for i, c in ipairs(M.connections) do
    if c.id == id then M.disconnect(id); table.remove(M.connections, i); save(); changed(); return true end
  end
  return false
end
function M.connect(id, password)
  local c = M.find(id)
  if not c then return false end
  M.disconnect(id)
  if c.server == "" or c.database == "" then
    c.state, c.error = "Failed", "Enter a server and database."; changed(); return false
  end
  local generation = c.generation
  c.state = "Connecting"
  changed()
  local options = { server = c.server, database = c.database, user = c.user, password = password,
    integrated = c.integrated, trust_certificate = c.trust_certificate, encrypt = c.encrypt }
  local function finish(catalog, error)
    if M.find(id) ~= c or c.generation ~= generation then return end
    c.job, c.password = nil, nil
    c.catalog, c.error = catalog, error
    passwords[c] = catalog and not c.integrated and password or nil
    c.state = catalog and "Ready" or "Failed"
    changed()
    core.log_quiet("SQL Server: metadata connection=%s state=%s objects=%s columns_loaded=%s truncated=%s metadata_error=%s",
      id, c.state, catalog and #catalog.objects or 0, tostring(catalog and catalog.columns_loaded),
      tostring(catalog and catalog.objects_truncated), tostring(catalog and catalog.metadata_error ~= nil))
  end
  local handle, err = backend.read_schema(options, finish)
  if not handle then finish(nil, err or "Could not start metadata read.")
  elseif c.state == "Connecting" then c.job = handle end
  return handle ~= nil
end
-- Reads the catalog again while the connection stays Ready. SQL Sessions, their
-- transactions and temporary tables stay. A failed read keeps the old catalog.
function M.refresh_schema(id)
  local c = M.find(id)
  if not c or c.state ~= "Ready" or c.refreshing then return false end
  local generation = c.generation
  local options = { server = c.server, database = c.database, user = c.user, password = passwords[c],
    integrated = c.integrated, trust_certificate = c.trust_certificate, encrypt = c.encrypt }
  local done = false
  local function finish(catalog, error)
    done = true
    if M.find(id) ~= c or c.generation ~= generation then return end
    c.refreshing = nil
    if catalog then c.catalog = catalog; changed() end
    core.log_quiet("SQL Server: metadata refresh connection=%s ok=%s objects=%s error=%s", id,
      tostring(catalog ~= nil), catalog and #catalog.objects or 0, tostring(error ~= nil))
  end
  local handle = backend.read_schema(options, finish)
  if handle and not done then c.refreshing = handle end
  return handle ~= nil
end
-- The columns of a catalog table or view. A database with more columns than the catalog loads
-- reads each object's columns on first use: `done(columns)` then runs when they arrive, and not
-- after a disconnect. A failed read gives no columns until the next connect.
local column_waiters = setmetatable({}, { __mode = "k" })
function M.object_columns(c, object, done)
  if object.columns then
    if done then done(object.columns) end
    return object.columns
  end
  local waiters = column_waiters[object]
  if waiters then
    if done then waiters[#waiters + 1] = done end
    return
  end
  waiters = { done }
  column_waiters[object] = waiters
  local catalog, generation = c.catalog, c.generation
  local function finish(columns, error)
    column_waiters[object] = nil
    if c.catalog ~= catalog or c.generation ~= generation then return end
    if not columns then core.log_quiet("SQL Server: column read failed connection=%s: %s", c.id, tostring(error)) end
    object.columns = columns or {}
    changed()
    for _, fn in ipairs(waiters) do fn(object.columns) end
  end
  local handle, err = backend.read_columns(M.connection_options(c), object, finish)
  if not handle then finish(nil, err) end
end
function M.bind(buffer, id)
  if not M.find(id) then return false end
  if buffer.sql_connection_id ~= id then cancel_run(buffer.sql_execution) end
  buffer.sql_connection_id = id
  buffer:set_language_mode("sql", { reason = "SQL Query" })
  changed()
  return true
end
-- A SQL Editor without its own connection uses the Project's only connection.
-- This only finds the connection. It never connects.
function M.connection_for(buffer)
  if not buffer then return end
  local c = buffer.sql_connection_id and M.find(buffer.sql_connection_id)
  if c or not (buffer.syntax and buffer.syntax.name == "SQL") then return c end
  M.load()
  if #M.connections == 1 then return M.connections[1] end
end

function M.is_sql(view)
  return view and view:extends(Editor) and view.buffer.syntax.name == "SQL"
end
function M.connection_options(c)
  return { server = c.server, database = c.database, user = c.user, password = passwords[c],
    integrated = c.integrated, trust_certificate = c.trust_certificate, encrypt = c.encrypt }
end
function M.with_connection(view, action)
  return require("plugins.sql_server.connection").with_connection(M, view, action)
end

-- A Query's row limit: nil uses the configured limit, a number replaces it, and
-- false turns it off up to the native maximum.
M.ROW_LIMIT_MAX = 100000
function M.row_limit(buffer)
  if buffer.sql_row_limit == false then return M.ROW_LIMIT_MAX end
  return buffer.sql_row_limit or config.plugins.sql_server.max_rows
end
local function row_limit_message(buffer)
  core.status_bar:show_message("i", require("core.style").text, buffer.sql_row_limit == false
    and string.format("Row limit off. Results stop at %d rows.", M.ROW_LIMIT_MAX)
    or string.format("Row limit %d. Run again to apply it.", M.row_limit(buffer)))
  core.redraw = true
  return true
end
command.add(function(buffer, limit)
  return type(buffer) == "table" and buffer.lines ~= nil and (limit == false
    or type(limit) == "number" and limit % 1 == 0 and limit >= 1 and limit <= M.ROW_LIMIT_MAX), buffer, limit
end, {
  ["sql_server:set_row_limit"] = function(buffer, limit)
    if limit == config.plugins.sql_server.max_rows then limit = nil end
    buffer.sql_row_limit = limit
    return row_limit_message(buffer)
  end,
})

-- The database that a Query's session moved to with USE, or nil. The catalog
-- describes only the connection's database.
function M.other_database(buffer)
  local c, s = M.connection_for(buffer), session.get(buffer)
  if c and s and s.connection == c and s.database and s.database:lower() ~= c.database:lower() then return s.database end
end

-- The native limit of a run's text.
M.TEXT_LIMIT = 64 * 1024 * 1024

-- A Query's timeout in seconds: nil uses the configured timeout, and 0 means none.
M.TIMEOUT_MAX = 86400
function M.timeout(buffer)
  return buffer.sql_timeout or config.plugins.sql_server.timeout_seconds
end

-- The line of the last run's error moves with edits, as a range marker.
function M.set_error_line(buffer, line)
  if buffer.sql_error then require("core.range_marker").remove(buffer.sql_error) end
  buffer.sql_error = nil
  if not line then return end
  line = math.max(1, math.min(line, #buffer.lines))
  buffer.sql_error = require("core.range_marker").new(buffer, { line1 = line, col1 = 1, line2 = line,
    col2 = #buffer.lines[line], kind = "sql_error" })
end
function M.error_line(buffer)
  local range = buffer.sql_error and buffer.sql_error:range()
  return range and range.line1
end

-- Runs the selection, or the whole Buffer with opts.whole_buffer. With
-- opts.explain, SQL Server returns estimated plans and runs nothing.
function M.run(editor, opts)
  opts = opts or {}
  local buffer = editor.buffer
  local s = session.get(buffer)
  if (buffer.sql_execution and buffer.sql_execution.active) or (s and s.busy) then return false end
  local line1, col1, line2, col2 = buffer:get_selection(true)
  if opts.whole_buffer then
    line1, col1, line2, col2 = 1, 1, #buffer.lines, #buffer.lines[#buffer.lines]
  elseif line1 == line2 and col1 == col2 then
    return false
  end
  local bytes = col2 - col1
  for line = line1, line2 - 1 do
    bytes = bytes + #buffer.lines[line]
    if bytes > M.TEXT_LIMIT then break end
  end
  if bytes > M.TEXT_LIMIT then core.error("SQL exceeds the 64 MiB limit of a run."); return false end
  local text = buffer:get_text(line1, col1, line2, col2)
  if not text:find("%S") then return false end
  return M.with_connection(editor, function(c)
  if buffer.sql_execution and buffer.sql_execution.active then return false end
  local run = { active = true, connection = c, generation = c.generation, started = system.get_time() }
  local view = buffer.sql_results
  if not view or view.closed or not panes.pane_for_view(view) then
    view = panes.place(function() return require("plugins.sql_server.results")(c.name) end,
      { pane = panes.pane_for_view(editor), placement = "split", direction = "down", focus = false })
    if not view then return false end
    buffer.sql_results = view
  end
  run.view, view.source_buffer = view, buffer
  buffer.sql_execution, active_runs[run] = run, true
  M.set_error_line(buffer, nil)
  view:begin_run(function() cancel_run(run) end, opts.explain, text)
  buffer:add_metadata_listener("sql_execution", function(_, event)
    if event.kind == "close" then run.closed = true; cancel_run(run) end
  end)
  local function finish(data)
    if not run.active then return end
    run.active, run.handle, active_runs[run] = false, nil, nil
    buffer:remove_metadata_listener("sql_execution")
    session.adopt(buffer, c, run.generation, data, not run.closed and M.connection_for(buffer) == c)
    if run.cancelled or c.generation ~= run.generation then
      data = { cancelled = true, messages = data.messages, transaction_count = data.transaction_count }
    end
    if data.error_line then M.set_error_line(buffer, line1 + data.error_line - 1) end
    if data.schema_changed and c.generation == run.generation then M.refresh_schema(c.id) end
    if buffer.sql_execution == run and not view.closed then view:complete(data) end
    if not opts.explain then
      require("plugins.sql_server.history").record(storage_key, { text = text, connection = c.id, name = c.name,
        seconds = system.get_time() - run.started,
        status = data.cancelled and "Cancelled" or data.error and "Error" or "OK" })
    end
    core.log_quiet("SQL Server: execution connection=%s cancelled=%s failed=%s explain=%s seconds=%.3f",
      c.id, tostring(data.cancelled == true), tostring(data.error ~= nil), tostring(opts.explain == true),
      system.get_time() - run.started)
  end
  local handle, err = backend.execute(M.connection_options(c), text, finish, {
    session = session.for_run(buffer, c), autocommit = buffer.sql_auto_commit ~= false,
    explain = opts.explain, max_rows = M.row_limit(buffer), timeout = M.timeout(buffer) })
  if not handle then finish({ error = err or "Could not start SQL execution." })
  elseif run.active then run.handle = handle; if run.cancelled then handle:cancel() end end
  return handle ~= nil
  end)
end
function M.new_query(id)
  if id and (not loaded or not M.find(id)) then return nil end
  local buffer = core.open_buffer()
  require("plugins.untitled_tabs").tag_buffer(buffer)
  buffer:set_language_mode("sql", { reason = "New SQL Query" })
  if id then M.bind(buffer, id) end
  local editor = Editor(buffer)
  panes.place(function() return editor end, { placement = "new", focus = true })
  return editor
end

-- The connection is document state, not a second document type. The existing
-- View state saves it for Untitled queries and for queries saved with Save As.
local editor_new = Editor.new
function Editor:new(...)
  editor_new(self, ...)
  if self.buffer.sql_connection_id then M.load() end
  self:add_owned_feature("sql-connection", {
    get_state = function(_, view) return view.buffer.sql_connection_id end,
    set_state = function(_, view, id)
      if type(id) == "string" then view.buffer.sql_connection_id = id; M.load() end
    end,
  })
end

-- A SQL Query can keep its Editor in navigation history while a definition
-- shows. Explicit Pane Close still uses the normal Untitled discard check.
local editor_can_suspend = Editor.can_suspend
function Editor:can_suspend()
  return self.buffer.sql_connection_id ~= nil or editor_can_suspend(self)
end

-- Closing the last View of a SQL Query ends its session. Ask first when its
-- transaction is open.
local editor_can_close = Editor.can_close
function Editor:can_close(approve, ...)
  local s = session.get(self.buffer)
  if s and s.transaction_count ~= 0 and #core.get_views_referencing_buffer(self.buffer) <= 1 then
    local args = table.pack(...)
    return session.confirm({ self.buffer }, function() editor_can_close(self, approve, table.unpack(args, 1, args.n)) end)
  end
  return editor_can_close(self, approve, ...)
end
local confirm_close_buffers = core.confirm_close_buffers
function core.confirm_close_buffers(buffers, close_fn, cancel_fn, ...)
  local closing, pending = {}, {}
  for _, buffer in ipairs(buffers) do closing[buffer] = true end
  for _, buffer in ipairs(session.pending()) do if closing[buffer] then pending[#pending + 1] = buffer end end
  local args = table.pack(...)
  return session.confirm(pending, function()
    return confirm_close_buffers(buffers, close_fn, cancel_fn, table.unpack(args, 1, args.n))
  end, cancel_fn and function() cancel_fn(table.unpack(args, 1, args.n)) end)
end

function M.open_definition(view, opts)
  return require("plugins.sql_server.source").open(M, view, nil, opts)
end

local language = require "core.commands.language"
local activate_symbol = language.activate_symbol
function language.activate_symbol(view, opts)
  if M.is_sql(view) then return M.open_definition(view, opts) end
  return activate_symbol(view, opts)
end

command.add(nil, {
  ["sql_server:manage"] = command.palette(function() return require("plugins.sql_server.dialog").open() end),
  ["sql_server:new_query"] = command.palette(function() return M.new_query() end),
  ["sql_server:history"] = command.palette(function()
    M.load()
    require("plugins.sql_server.history").open(M, storage_key)
  end),
  ["sql_server:clear_history"] = command.palette(function()
    M.load()
    require("plugins.sql_server.history").clear(storage_key)
  end),
})
command.add(function()
  local view = core.active_view
  return M.is_sql(view), view
end, {
  ["sql_server:choose_connection"] = command.palette(function(view)
    return require("plugins.sql_server.connection").choose(M, view)
  end),
  ["sql_server:run_selection"] = command.palette(function(view) return M.run(view) end),
  ["sql_server:run_buffer"] = command.palette(function(view) return M.run(view, { whole_buffer = true }) end),
  ["sql_server:explain_selection"] = command.palette(function(view) return M.run(view, { explain = true }) end),
  ["sql_server:toggle_auto_commit"] = command.palette(function(view)
    local buffer = view.buffer
    if buffer.sql_auto_commit ~= false then
      buffer.sql_auto_commit = false
      core.status_bar:show_message("i", require("core.style").text, "Auto Commit off")
      core.redraw = true
      return true
    end
    -- Auto Commit cannot turn on inside a transaction, so end it first.
    local s = session.get(buffer)
    session.confirm(s and s.transaction_count ~= 0 and { buffer } or {}, function()
      buffer.sql_auto_commit = nil
      core.status_bar:show_message("i", require("core.style").text, "Auto Commit on")
      core.redraw = true
    end)
    return true
  end),
  ["sql_server:set_timeout"] = command.palette(function(view)
    local buffer = view.buffer
    local function seconds(text)
      local n = tonumber(text)
      return n and n % 1 == 0 and n >= 0 and n <= M.TIMEOUT_MAX and n or nil
    end
    core.global_prompt_bar:enter("Query Timeout in Seconds (0 for None)", {
      text = tostring(M.timeout(buffer)), select_text = true,
      validate = function(text) return seconds(text) ~= nil end,
      submit = function(text)
        local n = seconds(text)
        buffer.sql_timeout = n ~= config.plugins.sql_server.timeout_seconds and n or nil
        core.status_bar:show_message("i", require("core.style").text,
          n == 0 and "No timeout. Run again to apply it." or string.format("Timeout %d s. Run again to apply it.", n))
        core.redraw = true
      end,
    })
    return true
  end),
  ["sql_server:toggle_row_limit"] = command.palette(function(view)
    view.buffer.sql_row_limit = view.buffer.sql_row_limit ~= false and false or nil
    return row_limit_message(view.buffer)
  end),
  ["sql_server:disconnect"] = command.palette(function(view)
    local c = M.connection_for(view.buffer)
    if not c or c.state == "Disconnected" then return false end
    return M.after_transactions(c.id, function() M.disconnect(c.id) end)
  end),
  ["sql_server:expand_star"] = command.palette(function(view)
    return require("plugins.sql_server.intelligence").expand_star(view, M)
  end),
  ["sql_server:format"] = command.palette(function(view)
    return require("plugins.sql_server.format").format(view)
  end),
})
command.add(function()
  local view = core.active_view
  local s = M.is_sql(view) and session.get(view.buffer)
  return s and not s.busy and (s.transaction_count ~= 0 or view.buffer.sql_auto_commit == false), view
end, {
  ["sql_server:commit"] = command.palette(function(view) return session.end_transaction(view.buffer, true) end),
  ["sql_server:rollback"] = command.palette(function(view) return session.end_transaction(view.buffer, false) end),
})
command.add(function()
  local view = core.active_view
  return M.is_sql(view) and M.error_line(view.buffer) ~= nil, view
end, {
  ["sql_server:go_to_error"] = command.palette(function(view)
    local line = M.error_line(view.buffer)
    view.buffer:set_selection(line, 1)
    view:scroll_to_line(line, true)
    return true
  end),
})
for _, action in ipairs({ "select", "create", "alter", "insert", "update", "delete" }) do
  command.add(function() return M.is_sql(core.active_view), core.active_view end, {
    ["sql_server:generate_" .. action] = command.palette(function(view)
      return require("plugins.sql_server.source").generate(M, view, action)
    end),
  })
end
command.add(function() return M.is_sql(core.active_view), core.active_view end, {
  ["sql_server:symbol_actions"] = command.palette(function(view)
    return require("plugins.sql_server.source").symbol_actions(M, view)
  end),
  ["sql_server:design_table"] = command.palette(function(view)
    return require("plugins.sql_server.design_dialog").open(M, view)
  end),
  ["sql_server:new_table"] = command.palette(function(view)
    return require("plugins.sql_server.design_dialog").new_table(M, view)
  end),
})
-- Menu items carry the object and where it came from: a SQL Editor, or a Ready
-- connection from Project Symbol Search. So they act on the chosen symbol.
local function object_args(from, object, action)
  if type(from) ~= "table" or type(object) ~= "table" then return false end
  local valid
  if M.find(from.id) == from then valid = from.state == "Ready" else valid = M.is_sql(from) and not from.closed end
  return valid, from, object, action
end
command.add(object_args, {
  ["sql_server:script_object"] = function(from, object, action)
    return require("plugins.sql_server.source").generate(M, from, action, object)
  end,
  ["sql_server:open_object"] = function(from, object)
    return require("plugins.sql_server.source").open(M, from, object)
  end,
  ["sql_server:table_design"] = function(from, object)
    return require("plugins.sql_server.design_dialog").open(M, from, object)
  end,
})

-- A SQL Editor's Context Menu starts with the actions of the symbol at the
-- caret, then the run commands, then the normal text commands.
local editor_context_menu = Editor.context_menu
function Editor:context_menu(x, y)
  local items = editor_context_menu(self, x, y)
  if not items or not M.is_sql(self) then return items end
  local icons = require("core.context_menu").icons
  local sql_items = {}
  local object = require("plugins.sql_server.intelligence").object_at(self, M)
  if object then
    sql_items[1] = { label = object.schema .. "." .. object.name, icon = icons.table,
      items = require("plugins.sql_server.source").action_items(self, object) }
  end
  if self.buffer:has_selection() then
    sql_items[#sql_items + 1] = { label = "Run Selection", icon = icons.run, command = "sql_server:run_selection" }
    sql_items[#sql_items + 1] = { label = "Explain Selection", icon = icons.search, command = "sql_server:explain_selection" }
  end
  sql_items[#sql_items + 1] = { label = "Run Buffer", icon = icons.run, command = "sql_server:run_buffer" }
  if not self.buffer.read_only then
    sql_items[#sql_items + 1] = { label = "Format SQL", icon = icons.format, command = "sql_server:format" }
  end
  sql_items[#sql_items + 1] = "-"
  for i, item in ipairs(sql_items) do table.insert(items, i, item) end
  return items
end
command.add(function()
  local view = core.active_view
  local run = view and view.buffer and view.buffer.sql_execution
  return (run and run.active and not run.cancelled) or (view and view.cancel_query ~= nil), view, run
end, {
  ["sql_server:cancel"] = function(view, run)
    if run then cancel_run(run) else view.cancel_query() end
  end,
})
local exit = core.exit
function core.exit(quit_fn, force)
  if force and not flush_settings() then return end
  if force then for _, c in ipairs(M.connections) do M.disconnect(c.id) end end
  return exit(quit_fn, force)
end
local set_project = core.set_project
function core.set_project(...)
  if not flush_settings() then return false end
  for _, c in ipairs(M.connections) do M.disconnect(c.id) end
  require("plugins.sql_server.history").reset()
  load_generation = load_generation + 1
  loaded, loading, M.connections = false, false, {}
  changed()
  local result = set_project(...)
  if result then M.connect_on_open() end
  return result
end
-- A Project connects its connections when it opens. Windows authentication
-- connects at once, also in a background Project. A SQL login asks for its
-- password once, when the Project shows and no other Dialog is open. A failed
-- connect only sets the connection's state.
local open_generation = 0
function M.connect_on_open()
  if not config.plugins.sql_server.connect_on_open then return end
  open_generation = open_generation + 1
  local generation = open_generation
  core.add_thread(function()
    while core.workspace_restored == false do coroutine.yield(0.05) end
    M.load()
    while not loaded and not M.load_error and generation == open_generation do coroutine.yield(0.05) end
    if generation ~= open_generation or not loaded then return end
    local logins = {}
    for _, c in ipairs(M.connections) do
      if c.state == "Disconnected" and c.server ~= "" and c.database ~= "" then
        if c.integrated then M.connect(c.id) else logins[#logins + 1] = c end
      end
    end
    core.log_quiet("SQL Server: connecting on open connections=%d logins=%d", #M.connections, #logins)
    local dialog = require "core.ui.dialog"
    for _, c in ipairs(logins) do
      while generation == open_generation and (dialog.current() or not system.window_should_render(core.window)) do
        coroutine.yield(0.1)
      end
      if generation ~= open_generation then return end
      if M.find(c.id) == c and c.state == "Disconnected" then
        require("plugins.sql_server.connection").password_prompt(c, function(password)
          if M.find(c.id) == c and c.state ~= "Connecting" then M.connect(c.id, password) end
        end)
      end
    end
  end)
end
M.connect_on_open()
-- The SQL Query's connection and transaction state, like the SQL Commander
-- status of DbVisualizer. A click chooses the connection.
do
  local style = require "core.style"
  core.status_bar:add_item {
    name = "sql:connection",
    alignment = core.status_bar.Item.RIGHT,
    predicate = function(view) return M.is_sql(view) end,
    get_item = function(_, view)
      local c = M.connection_for(view.buffer)
      if not c then return { style.dim, "No SQL connection" } end
      local parts = { c.state == "Ready" and style.text or style.dim, c.name }
      if c.state ~= "Ready" then
        table.insert(parts, c.state == "Failed" and style.error or style.dim)
        table.insert(parts, " · " .. c.state)
      elseif c.catalog and c.catalog.metadata_error then
        table.insert(parts, style.warn); table.insert(parts, " · No Metadata")
      end
      local s = session.get(view.buffer)
      local database = M.other_database(view.buffer)
      if database then table.insert(parts, style.warn); table.insert(parts, " · Database " .. database) end
      if view.buffer.sql_auto_commit == false then table.insert(parts, style.dim); table.insert(parts, " · Auto Commit Off") end
      if s and s.transaction_count ~= 0 then
        table.insert(parts, style.warn)
        table.insert(parts, s.transaction_count and " · Transaction Open" or " · Transaction Unknown")
      end
      local timeout = M.timeout(view.buffer)
      if timeout > 0 then table.insert(parts, style.dim); table.insert(parts, " · Timeout " .. timeout .. " s") end
      if view.buffer.sql_row_limit == false then table.insert(parts, style.dim); table.insert(parts, " · No Row Limit")
      elseif view.buffer.sql_row_limit then
        table.insert(parts, style.dim); table.insert(parts, " · Row Limit " .. view.buffer.sql_row_limit)
      end
      return parts
    end,
    tooltip = function(_, view)
      local c = M.connection_for(view.buffer)
      if not c then return "Choose a SQL connection" end
      local text = c.database .. " @ " .. c.server .. " · " .. c.state
      return c.catalog and c.catalog.metadata_error and (text .. " · " .. c.catalog.metadata_error) or text
    end,
    command = "sql_server:choose_connection",
  }
end
require("plugins.sql_server.intelligence").install(M)
return M
