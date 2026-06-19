local core = require "core"
local common = require "core.common"
local core_config = require "core.config"
local client_mod = require "core.lsp.client"
local config = require "core.lsp.config"
local completion = require "core.lsp.completion"
local diagnostics = require "core.lsp.diagnostics"
local documents = require "core.lsp.documents"
local hover = require "core.lsp.hover"
local provider = require "core.lsp.provider"
local signature_help = require "core.lsp.signature_help"

local manager = {}

local clients_by_key = {}
local function running_tests()
  for _, arg in ipairs(ARGS or {}) do
    if arg == "test" then return true end
  end
  return false
end
local auto_start = not running_tests()
local definitions = nil
local sync_options = {}
local pump_thread_started = false
local recent_attempts = {}
local RECENT_ATTEMPT_LIMIT = 20

local function quiet_log(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function doc_path(doc)
  local path = doc and (doc.abs_filename or doc.filename)
  if not path or path == "" then return nil end
  if not common.is_absolute_path(path) and system.absolute_path then
    path = system.absolute_path(path)
  end
  return common.normalize_path(path)
end

local function doc_dir(path)
  return path and common.dirname(path) or nil
end

local function copy_array(value)
  local out = {}
  if type(value) == "table" then
    for i, item in ipairs(value) do out[i] = item end
  end
  return out
end

local function copy_table(value)
  local out = {}
  if type(value) == "table" then
    for key, item in pairs(value) do
      if type(item) == "table" then
        out[key] = copy_table(item)
      else
        out[key] = item
      end
    end
  end
  return out
end

local function merged_server_definitions()
  if definitions ~= nil then return definitions end
  local merged = copy_table(config.DEFAULT_SERVER_DEFINITIONS)
  local lsp_cfg = type(core_config.lsp) == "table" and core_config.lsp or nil
  local overrides = lsp_cfg and lsp_cfg.servers or nil
  if type(overrides) == "table" then
    for id, override in pairs(overrides) do
      if type(override) == "table" then
        local base = type(merged[id]) == "table" and copy_table(merged[id]) or {}
        for key, value in pairs(override) do base[key] = value end
        if base.id == nil and type(id) == "string" then base.id = id end
        merged[id] = base
      elseif override == false then
        merged[id] = nil
      end
    end
  end
  return merged
end

local function merge_env(base, extra)
  local out = {}
  for key, value in pairs(base or {}) do out[key] = value end
  for key, value in pairs(extra or {}) do out[key] = value end
  return out
end

local function command_with_executable(command, executable)
  if type(command) == "table" then
    local out = copy_array(command)
    out[1] = executable or out[1]
    return out
  end
  return executable or command
end

local function cwd_for(selection, path)
  local definition = selection.definition
  if definition.cwd_policy == "fixed" and definition.fixed_cwd then return definition.fixed_cwd end
  if definition.cwd_policy == "document" then return doc_dir(path) end
  return selection.root and selection.root.root or doc_dir(path)
end

local function client_options(selection, path)
  local definition = selection.definition
  return {
    wait = false,
    root_uri = selection.root and selection.root.root_uri or nil,
    root_path = selection.root and selection.root.root or nil,
    initialization_options = definition.initialization_options,
    initialize_timeout = definition.request_timeout,
    env = merge_env(nil, definition.env),
    cwd = cwd_for(selection, path),
  }
end

local function attach_document(entry, doc)
  if not entry or not entry.client or not doc then return nil, "missing client or document" end
  if entry.client.state ~= "ready" then
    entry.pending_docs[doc] = true
    return false, "pending"
  end
  if documents.state(entry.client, doc) then return true end
  local state, err = documents.attach(entry.client, doc, {
    language_id = entry.definition.language_id,
    debounce_seconds = sync_options.debounce_seconds,
    max_file_bytes = sync_options.max_file_bytes,
    include_save_text = sync_options.include_save_text,
  })
  if not state then
    quiet_log("LSP manager failed to attach %s to %s: %s", tostring(doc_path(doc)), entry.identity.key, tostring(err))
    return nil, err
  end
  entry.docs[doc] = true
  quiet_log("LSP manager attached %s to %s", tostring(state.uri), entry.identity.key)
  return state
end

local function attach_pending_docs(entry)
  if not entry or not entry.client or entry.client.state ~= "ready" then return end
  for doc in pairs(entry.pending_docs) do
    entry.pending_docs[doc] = nil
    attach_document(entry, doc)
  end
end

local function record_attempt(definition, path, status, detail)
  local server_id = definition and definition.id or "<unknown>"
  local entry = {
    server_id = server_id,
    path = path,
    status = status or "unavailable",
    detail = detail,
    at = system.get_time(),
  }
  recent_attempts[#recent_attempts + 1] = entry
  while #recent_attempts > RECENT_ATTEMPT_LIMIT do table.remove(recent_attempts, 1) end
  return entry
end

local function start_pump_thread()
  if pump_thread_started or not core.add_background_thread then return end
  pump_thread_started = true
  core.add_background_thread(function()
    while true do
      manager.update()
      if next(clients_by_key) == nil then
        pump_thread_started = false
        return
      end
      coroutine.yield(0.02)
    end
  end, manager)
end

local function create_entry(selection, path, opts)
  local command = command_with_executable(selection.definition.command, selection.executable)
  quiet_log("LSP manager starting %s for root %s", selection.definition.id,
    tostring(selection.root and selection.root.root or doc_dir(path)))
  local c, err, partial = client_mod.start(command, client_options(selection, path))
  c = c or partial
  if not c then
    quiet_log("LSP manager failed to start %s: %s", selection.definition.id, tostring(err))
    record_attempt(selection.definition, path, "start failed", err)
    return nil, err
  end
  c.server_id = selection.definition.id
  c.id = selection.identity.key
  c.identity = selection.identity
  c.definition = selection.definition
  c.language_id = selection.definition.language_id

  local entry = {
    key = selection.identity.key,
    client = c,
    definition = selection.definition,
    root = selection.root,
    identity = selection.identity,
    docs = setmetatable({}, { __mode = "k" }),
    pending_docs = setmetatable({}, { __mode = "k" }),
    started_at = system.get_time(),
    last_error = err,
  }
  clients_by_key[entry.key] = entry
  diagnostics.attach_client(c, { server_id = selection.definition.id })
  provider.register_client(c, { server_id = selection.definition.id })
  start_pump_thread()
  return entry
end

local function selected_servers_for_doc(doc, opts)
  local path = doc_path(doc)
  if not path then return nil, "document has no filename" end
  opts = opts or {}
  local select_options = opts.select_options or opts
  local selected, err = config.select_for_path(merged_server_definitions(), path, select_options)
  if not selected then return nil, err end
  return selected, nil, path
end

function manager.set_server_definitions(new_definitions)
  definitions = new_definitions
end

function manager.set_auto_start(enabled)
  auto_start = enabled == true
end

function manager.set_sync_options(opts)
  sync_options = opts or {}
end

function manager.entries()
  return clients_by_key
end

function manager.entry_for_identity(identity_or_key)
  local key = type(identity_or_key) == "table" and identity_or_key.key or identity_or_key
  return key and clients_by_key[key] or nil
end

function manager.client_for_doc(doc)
  for _, entry in pairs(clients_by_key) do
    if documents.state(entry.client, doc) or entry.pending_docs[doc] then return entry.client, entry end
  end
end

function manager.ensure_doc(doc, opts)
  opts = opts or {}
  if opts.auto and documents.is_content_ready and not documents.is_content_ready(doc) then
    quiet_log("LSP manager deferred auto-start for %s until document contents are loaded", tostring(doc_path(doc)))
    return nil, "document contents not loaded"
  end
  local selected, err, path = selected_servers_for_doc(doc, opts)
  if not selected then
    quiet_log("LSP manager skipped document: %s", tostring(err))
    return nil, err
  end
  local attached = {}
  for _, selection in ipairs(selected) do
    if selection.available == false then
      local detail = selection.command or (selection.executable_status and selection.executable_status.command) or selection.reason
      quiet_log("LSP manager server %s unavailable for %s: %s",
        selection.definition and selection.definition.id or "<unknown>", tostring(path), tostring(selection.reason))
      record_attempt(selection.definition, path, selection.reason or "unavailable", detail)
    elseif selection.identity then
      local entry = clients_by_key[selection.identity.key]
      if not entry or entry.client.failed or entry.client.exited then
        if entry then manager.stop_entry(entry, { no_shutdown = true }) end
        entry, err = create_entry(selection, path, opts)
      else
        quiet_log("LSP manager reusing %s for %s", selection.identity.key, tostring(path))
      end
      if entry then
        attach_document(entry, doc)
        attached[#attached + 1] = entry
      end
    end
  end
  if #attached == 0 then return nil, "no available LSP server" end
  return attached
end

function manager.start_current_document(view)
  view = view or core.active_view
  if not view or not view.doc then return nil, "no active document" end
  return manager.ensure_doc(view.doc)
end

function manager.on_doc_metadata_changed(doc)
  if doc and doc.disable_language_services then return end
  if auto_start then manager.ensure_doc(doc, { auto = true }) end
end

function manager.update()
  documents.update()
  for key, entry in pairs(clients_by_key) do
    local c = entry.client
    if c and not c.exited and not c.failed then
      local ok, err = c:pump_once()
      if ok == nil then
        entry.last_error = err
        quiet_log("LSP manager pump failed for %s: %s", key, tostring(err))
      end
      if c.state == "ready" then attach_pending_docs(entry) end
    elseif c and c.failed then
      entry.last_error = c.error
      quiet_log("LSP manager removing failed client %s: %s", key, tostring(c.error))
      manager.stop_entry(entry, { no_shutdown = true })
    end
  end
end

function manager.pump_until(timeout, predicate, scan)
  timeout = timeout or 3
  scan = scan or 0.01
  local start = system.get_time()
  while system.get_time() - start < timeout do
    manager.update()
    if not predicate or predicate() then return true end
    system.sleep(scan)
  end
  return nil, "timeout"
end

function manager.stop_entry(entry, opts)
  opts = opts or {}
  if type(entry) == "string" then entry = clients_by_key[entry] end
  if not entry then return true end
  clients_by_key[entry.key] = nil
  for doc in pairs(entry.docs) do documents.detach(entry.client, doc) end
  for doc in pairs(entry.pending_docs) do entry.pending_docs[doc] = nil end
  completion.clear_client(entry.client)
  diagnostics.clear_client(entry.client)
  hover.clear_client(entry.client)
  provider.unregister_client(entry.client)
  signature_help.clear_client(entry.client)
  if not opts.no_shutdown and entry.client and entry.client.state ~= "exited" then
    entry.client:shutdown(opts.timeout or 1, opts.scan or 0.01)
  end
  return true
end

function manager.shutdown_all(opts)
  for key in pairs(clients_by_key) do manager.stop_entry(key, opts) end
  return true
end

function manager.restart_doc(doc, opts)
  local selected, err = selected_servers_for_doc(doc, opts)
  if selected then
    for _, selection in ipairs(selected) do
      if selection.identity then manager.stop_entry(selection.identity.key, opts) end
    end
  elseif err then
    quiet_log("LSP manager restart skipped: %s", tostring(err))
  end
  return manager.ensure_doc(doc, opts)
end

function manager.restart_current_document(view)
  view = view or core.active_view
  if not view or not view.doc then return nil, "no active document" end
  return manager.restart_doc(view.doc)
end

function manager.status()
  local lines = {}
  for key, entry in pairs(clients_by_key) do
    local c = entry.client
    lines[#lines + 1] = string.format("%s: %s%s", key, c and c.state or "missing",
      c and c.error and (" (" .. tostring(c.error) .. ")") or "")
  end
  table.sort(lines)
  for _, attempt in ipairs(recent_attempts) do
    local detail = attempt.detail and (" " .. tostring(attempt.detail)) or ""
    local status = tostring(attempt.status):gsub("_", " ")
    lines[#lines + 1] = string.format("%s for %s: %s%s",
      tostring(attempt.server_id), tostring(attempt.path), status, detail)
  end
  if #lines == 0 then return "No LSP clients" end
  return table.concat(lines, "\n")
end

function manager.reset_for_tests()
  manager.shutdown_all({ timeout = 0.2 })
  definitions = nil
  sync_options = {}
  recent_attempts = {}
  auto_start = false
end

if documents.register_doc_metadata_changed_handler then
  documents.register_doc_metadata_changed_handler("manager", function(doc, reason)
    manager.on_doc_metadata_changed(doc, reason)
  end)
end

return manager
