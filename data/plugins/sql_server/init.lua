-- mod-version:3
local core = require "core"
local command = require "core.command"
local Editor = require "core.editor"
local panes = require "core.panes"
local worker_pool = require "core.worker_pool"
local backend = require "plugins.sql_server.backend"
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
function M.is_saving() return saving or pending_save or false end
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
  if c.job then c.job:cancel(); c.job = nil end
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
  M.disconnect(id)
  c[key] = value
  save(); changed()
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
    core.log_quiet("SQL Server: metadata connection=%s state=%s", id, c.state)
  end
  local handle, err = backend.read_schema(options, finish)
  if not handle then finish(nil, err or "Could not start metadata read.")
  elseif c.state == "Connecting" then c.job = handle end
  return handle ~= nil
end
function M.bind(buffer, id)
  if not M.find(id) then return false end
  if buffer.sql_connection_id ~= id then cancel_run(buffer.sql_execution) end
  buffer.sql_connection_id = id
  buffer:set_language_mode("sql", { reason = "SQL Query" })
  changed()
  return true
end
function M.connection_for(buffer)
  return buffer and M.find(buffer.sql_connection_id)
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

function M.run(editor, whole_buffer)
  local buffer = editor.buffer
  if buffer.sql_execution and buffer.sql_execution.active then return false end
  local line1, col1, line2, col2 = buffer:get_selection(true)
  if whole_buffer then
    line1, col1, line2, col2 = 1, 1, #buffer.lines, #buffer.lines[#buffer.lines]
  elseif line1 == line2 and col1 == col2 then
    return false
  end
  local bytes = col2 - col1
  for line = line1, line2 - 1 do
    bytes = bytes + #buffer.lines[line]
    if bytes > 256 * 1024 then break end
  end
  if bytes > 256 * 1024 then core.error("SQL exceeds the 256 KiB batch limit."); return false end
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
  run.view = view
  buffer.sql_execution, active_runs[run] = run, true
  view:begin_run(function() cancel_run(run) end)
  buffer:add_metadata_listener("sql_execution", function(_, event)
    if event.kind == "close" then cancel_run(run) end
  end)
  local function finish(data)
    if not run.active then return end
    run.active, run.handle, active_runs[run] = false, nil, nil
    buffer:remove_metadata_listener("sql_execution")
    if run.cancelled or c.generation ~= run.generation then data = { cancelled = true } end
    if buffer.sql_execution == run and not view.closed then view:complete(data) end
    core.log_quiet("SQL Server: execution connection=%s cancelled=%s failed=%s seconds=%.3f",
      c.id, tostring(data.cancelled == true), tostring(data.error ~= nil), system.get_time() - run.started)
  end
  local handle, err = backend.execute({ server = c.server, database = c.database, user = c.user,
    password = passwords[c], integrated = c.integrated, trust_certificate = c.trust_certificate, encrypt = c.encrypt }, text, finish)
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
})
command.add(function()
  local view = core.active_view
  return M.is_sql(view), view
end, {
  ["sql_server:choose_connection"] = command.palette(function(view)
    return require("plugins.sql_server.connection").choose(M, view)
  end),
  ["sql_server:run_selection"] = command.palette(function(view) return M.run(view, false) end),
  ["sql_server:run_buffer"] = command.palette(function(view) return M.run(view, true) end),
  ["sql_server:expand_star"] = command.palette(function(view)
    return require("plugins.sql_server.intelligence").expand_star(view, M)
  end),
})
for _, action in ipairs({ "select", "create", "alter", "insert", "update", "delete" }) do
  command.add(function() return M.is_sql(core.active_view), core.active_view end, {
    ["sql_server:generate_" .. action] = command.palette(function(view)
      return require("plugins.sql_server.source").generate(M, view, action)
    end),
  })
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
  load_generation = load_generation + 1
  loaded, loading, M.connections = false, false, {}
  changed()
  return set_project(...)
end
require("plugins.sql_server.intelligence").install(M)
return M
