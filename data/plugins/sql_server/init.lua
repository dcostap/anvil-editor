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
    name = "SQL Server", server = "", database = "", integrated = true, user = "", trust_certificate = false, encrypt = true,
    state = "Disconnected", generation = 0 }
  M.connections[#M.connections + 1] = c
  save(); changed()
  return c
end
function M.disconnect(id)
  local c = M.find(id)
  if not c then return false end
  c.generation = c.generation + 1
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
  buffer.sql_connection_id = id
  buffer:set_language_mode("sql", { reason = "SQL Query" })
  changed()
  return true
end
function M.connection_for(buffer)
  return buffer and M.find(buffer.sql_connection_id)
end
function M.new_query(id)
  if not loaded or not M.find(id) then return nil end
  local buffer = core.open_buffer()
  require("plugins.untitled_tabs").tag_buffer(buffer)
  M.bind(buffer, id)
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
  local t = require("plugins.sql_server.intelligence").table_at(view, M)
  if not t then
    core.warn("No table definition is available. Connect or refresh metadata in Databases.")
    return false
  end
  local function quote(text) return "[" .. text:gsub("]", "]]") .. "]" end
  local title = t.schema .. "." .. t.name
  local lines = { "-- " .. quote(t.schema) .. "." .. quote(t.name), "-- Columns (not a CREATE script)", "" }
  for _, column in ipairs(t.columns) do
    lines[#lines + 1] = quote(column.name) .. "  " .. column.type
      .. (column.nullable and " NULL" or " NOT NULL")
      .. (column.identity and " IDENTITY" or "") .. (column.primary_key and " PRIMARY KEY" or "")
  end
  local definition = require("core.textview").from_text(table.concat(lines, "\n"), { name = title })
  definition.buffer:set_language_mode("sql", { reason = "SQL definition" })
  if opts and opts.placement then
    panes.place(function() return definition end, opts)
  else
    local pane, err = panes.present(definition, { focus = true })
    if not pane then definition:on_close(); core.warn("%s", err); return false end
  end
  return true
end

local language = require "core.commands.language"
local activate_symbol = language.activate_symbol
function language.activate_symbol(view, opts)
  if view and view.buffer and view.buffer.sql_connection_id then return M.open_definition(view, opts) end
  return activate_symbol(view, opts)
end

command.add(nil, {
  ["sql_server:manage"] = command.palette(function() return require("plugins.sql_server.dialog").open() end),
})
local exit = core.exit
function core.exit(quit_fn, force)
  if force and not flush_settings() then return end
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
