local core = require "core"
local common = require "core.common"
local Buffer = require "core.buffer"
local lsp_json = require "core.lsp.json"
local uri = require "core.lsp.uri"

local documents = {}

local DEFAULT_MAX_FILE_BYTES = 1024 * 1024
local DEFAULT_DEBOUNCE_SECONDS = 0.2
local DEFAULT_SNAPSHOT_LIMIT = 16

local clients = setmetatable({}, { __mode = "k" })
local buffer_close_handlers = {}
local buffer_metadata_handlers = {}
local content_loaded = setmetatable({}, { __mode = "k" })
local content_loading = setmetatable({}, { __mode = "k" })
local patched = false

local function quiet_log(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function now()
  return system.get_time()
end

local function buffer_path(buffer)
  local path = buffer.abs_filename or buffer.filename
  if not path or path == "" then return nil end
  if not common.is_absolute_path(path) and system.absolute_path then
    path = system.absolute_path(path)
  end
  return common.normalize_path(path)
end

local function buffer_uri(buffer)
  local path = buffer_path(buffer)
  if not path then return nil end
  return uri.path_to_uri(path)
end

local function buffer_text(buffer)
  return table.concat(buffer.lines or {})
end

local function buffer_change_id(buffer)
  if buffer.get_change_id then return buffer:get_change_id() end
  return nil
end

local function client_bucket(client)
  local bucket = clients[client]
  if not bucket then
    bucket = { by_uri = {}, by_buffer = setmetatable({}, { __mode = "k" }) }
    clients[client] = bucket
  end
  return bucket
end

local function remove_buffer_state(bucket, state)
  if bucket.by_uri[state.uri] == state then
    bucket.by_uri[state.uri] = nil
  end
  local list = bucket.by_buffer[state.buffer]
  if list then
    for i = #list, 1, -1 do
      if list[i] == state then table.remove(list, i) end
    end
    if #list == 0 then bucket.by_buffer[state.buffer] = nil end
  end
end

local function add_buffer_state(bucket, state)
  bucket.by_uri[state.uri] = state
  local list = bucket.by_buffer[state.buffer]
  if not list then
    list = {}
    bucket.by_buffer[state.buffer] = list
  end
  list[#list + 1] = state
end

local function send_notification(client, method, params)
  if type(client.send_notification) == "function" then
    return client:send_notification(method, params)
  elseif type(client.notify) == "function" then
    return client:notify(method, params)
  end
  return nil, "client does not implement send_notification"
end

local function server_save_capability(client)
  local sync = client and client.capabilities and client.capabilities.textDocumentSync
  if type(sync) ~= "table" then return nil end
  return sync.save
end

local function server_supports_save(client)
  local save = server_save_capability(client)
  return save == true or type(save) == "table"
end

local function server_includes_save_text(client)
  local save = server_save_capability(client)
  return type(save) == "table" and save.includeText == true
end

local function language_id(client, opts)
  return opts.language_id or client.language_id
end

local function max_file_bytes(client, opts)
  return opts.max_file_bytes or client.max_file_bytes or DEFAULT_MAX_FILE_BYTES
end

local function is_supported(client, opts)
  if opts.supported == false or client.supported == false then return false end
  return language_id(client, opts) ~= nil
end

local function is_too_large(state, text)
  return #text > state.max_file_bytes
end

local function push_snapshot(state, kind, text)
  state.snapshots[#state.snapshots + 1] = {
    kind = kind,
    buffer_change_id = buffer_change_id(state.buffer),
    lsp_version = state.lsp_version,
    text_length = text and #text or nil,
    synced_at = now(),
  }
  while #state.snapshots > state.snapshot_limit do
    table.remove(state.snapshots, 1)
  end
end

local function send_did_open(state, text)
  local ok, err = send_notification(state.client, "textDocument/didOpen", {
    textDocument = {
      uri = state.uri,
      languageId = state.language_id,
      version = state.lsp_version,
      text = text,
    },
  })
  if not ok then return nil, err end
  state.opened = true
  state.pending_full_sync = false
  state.last_synced_change_id = buffer_change_id(state.buffer)
  push_snapshot(state, "open", text)
  return true
end

local function send_did_change(state, text)
  state.lsp_version = state.lsp_version + 1
  local ok, err = send_notification(state.client, "textDocument/didChange", {
    textDocument = {
      uri = state.uri,
      version = state.lsp_version,
    },
    contentChanges = lsp_json.array({ { text = text } }),
  })
  if not ok then return nil, err end
  state.pending_full_sync = false
  state.pending_due_at = nil
  state.last_synced_change_id = buffer_change_id(state.buffer)
  push_snapshot(state, "change", text)
  return true
end

local function send_did_close(state)
  if not state.opened or state.closing then return true end
  state.closing = true
  local ok, err = send_notification(state.client, "textDocument/didClose", {
    textDocument = { uri = state.uri },
  })
  state.opened = false
  push_snapshot(state, "close")
  return ok, err
end

local function disable_state(state, reason)
  if state.disabled_reason ~= reason then
    quiet_log("LSP buffer sync disabled for %s: %s", tostring(state.uri), tostring(reason))
  end
  state.disabled_reason = reason
  state.pending_full_sync = false
  state.pending_due_at = nil
end

function documents.attach(client, buffer, opts)
  opts = opts or {}
  local buffer_uri = opts.uri or buffer_uri(buffer)
  if not buffer_uri then
    quiet_log("LSP buffer sync skipped: buffer has no file URI")
    return nil, "buffer has no file URI"
  end

  local bucket = client_bucket(client)
  local existing = bucket.by_uri[buffer_uri]
  if existing then return existing end

  local state = {
    client = client,
    buffer = buffer,
    uri = buffer_uri,
    language_id = language_id(client, opts),
    lsp_version = 0,
    last_synced_change_id = nil,
    snapshots = {},
    snapshot_limit = opts.snapshot_limit or DEFAULT_SNAPSHOT_LIMIT,
    pending_full_sync = false,
    pending_due_at = nil,
    opened = false,
    closing = false,
    disabled_reason = nil,
    max_file_bytes = max_file_bytes(client, opts),
    debounce_seconds = opts.debounce_seconds or client.debounce_seconds or DEFAULT_DEBOUNCE_SECONDS,
    supports_save = opts.supports_save == true
      or opts.include_save_text == true
      or server_supports_save(client),
    include_save_text = opts.include_save_text == true
      or (opts.include_save_text == nil and server_includes_save_text(client)),
    did_save_after_open = opts.did_save_after_open == true,
    options = opts,
  }
  add_buffer_state(bucket, state)

  if not is_supported(client, opts) then
    disable_state(state, "unsupported")
    return state
  end

  local text = buffer_text(buffer)
  if is_too_large(state, text) then
    disable_state(state, "too_large")
    return state
  end

  local ok, err = send_did_open(state, text)
  if not ok then
    disable_state(state, err or "didOpen failed")
    return state
  end
  if state.did_save_after_open and state.supports_save then
    local clean_saved_file = not buffer.new_file and (not buffer.is_dirty or not buffer:is_dirty())
    if clean_saved_file then
      ok, err = documents.did_save(client, buffer)
      if not ok then
        quiet_log("LSP didSave-after-open failed for %s: %s", tostring(state.uri), tostring(err))
      end
    else
      quiet_log("LSP didSave-after-open skipped for dirty or new buffer %s", tostring(state.uri))
    end
  end
  return state
end

function documents.detach(client, buffer_or_uri)
  local bucket = clients[client]
  if not bucket then return true end
  local states = {}
  if type(buffer_or_uri) == "string" then
    buffer_or_uri = uri.normalize_file_uri(buffer_or_uri)
    local state = bucket.by_uri[buffer_or_uri]
    if state then states[1] = state end
  else
    local list = bucket.by_buffer[buffer_or_uri]
    if list then for i, state in ipairs(list) do states[i] = state end end
  end
  for _, state in ipairs(states) do
    send_did_close(state)
    remove_buffer_state(bucket, state)
  end
  return true
end

function documents.state(client, buffer_or_uri)
  local bucket = clients[client]
  if not bucket then return nil end
  if type(buffer_or_uri) == "string" then return bucket.by_uri[uri.normalize_file_uri(buffer_or_uri)] end
  local list = bucket.by_buffer[buffer_or_uri]
  return list and list[1] or nil
end

function documents.states_for_buffer(buffer)
  local out = {}
  for _, bucket in pairs(clients) do
    local list = bucket.by_buffer[buffer]
    if list then
      for _, state in ipairs(list) do out[#out + 1] = state end
    end
  end
  return out
end

function documents.on_text_transaction(buffer, _transaction)
  local change_id = buffer_change_id(buffer)
  for _, state in ipairs(documents.states_for_buffer(buffer)) do
    if state.opened and not state.disabled_reason then
      state.pending_full_sync = true
      state.pending_change_id = change_id
      state.pending_due_at = now() + state.debounce_seconds
    end
  end
end

function documents.flush_state(state)
  if not state or state.disabled_reason or not state.opened then return true end
  if not state.pending_full_sync then return true end
  local text = buffer_text(state.buffer)
  if is_too_large(state, text) then
    send_did_close(state)
    disable_state(state, "too_large")
    return true
  end
  return send_did_change(state, text)
end

function documents.flush(client, buffer_or_uri)
  if buffer_or_uri then
    local state = documents.state(client, buffer_or_uri)
    return documents.flush_state(state)
  end
  local bucket = clients[client]
  if not bucket then return true end
  for _, state in pairs(bucket.by_uri) do
    local ok, err = documents.flush_state(state)
    if not ok then return nil, err end
  end
  return true
end

function documents.flush_before_request(client, buffer_or_uri)
  return documents.flush(client, buffer_or_uri)
end

function documents.update(time)
  time = time or now()
  for _, bucket in pairs(clients) do
    for _, state in pairs(bucket.by_uri) do
      if state.pending_full_sync and state.pending_due_at and state.pending_due_at <= time then
        documents.flush_state(state)
      end
    end
  end
end

function documents.did_save(client, buffer_or_uri)
  local state = documents.state(client, buffer_or_uri)
  if not state or state.disabled_reason or not state.opened or not state.supports_save then return true end
  local params = { textDocument = { uri = state.uri } }
  if state.include_save_text then params.text = buffer_text(state.buffer) end
  push_snapshot(state, "save", params.text)
  return send_notification(client, "textDocument/didSave", params)
end

function documents.is_current(state, lsp_version, change_id)
  if not state then return false end
  if lsp_version ~= nil and lsp_version ~= state.lsp_version then return false end
  if change_id ~= nil and change_id ~= state.last_synced_change_id then return false end
  return true
end

function documents.snapshot_for_version(state, lsp_version)
  if not state then return nil end
  for i = #state.snapshots, 1, -1 do
    if state.snapshots[i].lsp_version == lsp_version then return state.snapshots[i] end
  end
  return nil
end

function documents.snapshot_for_change_id(state, change_id)
  if not state then return nil end
  for i = #state.snapshots, 1, -1 do
    if state.snapshots[i].buffer_change_id == change_id then return state.snapshots[i] end
  end
  return nil
end

function documents.is_content_ready(buffer)
  if not buffer then return false end
  if content_loading[buffer] then return false end
  if buffer.new_file then return true end
  local path = buffer_path(buffer)
  if not path then return true end
  if not system.get_file_info(path) then return true end
  return content_loaded[buffer] == true
end

function documents.on_buffer_metadata_changed(buffer, reason)
  for _, state in ipairs(documents.states_for_buffer(buffer)) do
    local new_uri = buffer_uri(buffer)
    if new_uri and new_uri ~= state.uri then
      local client = state.client
      local opts = state.options
      documents.detach(client, state.uri)
      documents.attach(client, buffer, opts)
    end
  end
  for id, handler in pairs(buffer_metadata_handlers) do
    local ok, err = pcall(handler, buffer, reason)
    if not ok then
      quiet_log("LSP buffer metadata handler %s failed: %s", tostring(id), tostring(err))
    end
  end
end

function documents.register_buffer_metadata_changed_handler(id, fn)
  assert(type(id) == "string" and id ~= "", "buffer metadata handler id must be a non-empty string")
  assert(type(fn) == "function", "buffer metadata handler must be a function")
  buffer_metadata_handlers[id] = fn
end

function documents.unregister_buffer_metadata_changed_handler(id)
  buffer_metadata_handlers[id] = nil
end

function documents.register_buffer_close_handler(id, fn)
  assert(type(id) == "string" and id ~= "", "buffer close handler id must be a non-empty string")
  assert(type(fn) == "function", "buffer close handler must be a function")
  buffer_close_handlers[id] = fn
end

function documents.unregister_buffer_close_handler(id)
  buffer_close_handlers[id] = nil
end

function documents.on_buffer_close(buffer)
  for _, state in ipairs(documents.states_for_buffer(buffer)) do
    documents.detach(state.client, state.uri)
  end
  for id, handler in pairs(buffer_close_handlers) do
    local ok, err = pcall(handler, buffer)
    if not ok then
      quiet_log("LSP buffer close handler %s failed: %s", tostring(id), tostring(err))
    end
  end
end

local function patch_buffer()
  if patched then return end
  patched = true

  local old_set_filename = Buffer.set_filename
  function Buffer:set_filename(...)
    local result = old_set_filename(self, ...)
    documents.on_buffer_metadata_changed(self, "filename")
    return result
  end

  local old_load = Buffer.load
  function Buffer:load(...)
    content_loading[self] = true
    content_loaded[self] = false
    local result = { pcall(old_load, self, ...) }
    content_loading[self] = nil
    if not result[1] then error(result[2], 0) end
    content_loaded[self] = true
    documents.on_buffer_metadata_changed(self, "load")
    return table.unpack(result, 2)
  end

  local old_reset_syntax = Buffer.reset_syntax
  function Buffer:reset_syntax(...)
    local result = old_reset_syntax(self, ...)
    if self.lines then documents.on_buffer_metadata_changed(self, "syntax") end
    return result
  end

  local old_on_text_transaction = Buffer.on_text_transaction
  function Buffer:on_text_transaction(transaction)
    old_on_text_transaction(self, transaction)
    documents.on_text_transaction(self, transaction)
  end

  local old_save = Buffer.save
  function Buffer:save(...)
    local result = { old_save(self, ...) }
    for _, state in ipairs(documents.states_for_buffer(self)) do
      local ok, err = documents.flush_state(state)
      if ok then
        ok, err = documents.did_save(state.client, self)
      end
      if not ok then
        quiet_log("LSP didSave failed for %s: %s", tostring(state.uri), tostring(err))
      end
    end
    return table.unpack(result)
  end

  local old_on_close = Buffer.on_close
  function Buffer:on_close(...)
    documents.on_buffer_close(self)
    return old_on_close(self, ...)
  end
end

patch_buffer()

return documents
