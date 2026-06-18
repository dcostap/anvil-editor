local core = require "core"
local common = require "core.common"
local Doc = require "core.doc"
local lsp_json = require "core.lsp.json"
local uri = require "core.lsp.uri"

local documents = {}

local DEFAULT_MAX_FILE_BYTES = 1024 * 1024
local DEFAULT_DEBOUNCE_SECONDS = 0.2
local DEFAULT_SNAPSHOT_LIMIT = 16

local clients = setmetatable({}, { __mode = "k" })
local patched = false

local function quiet_log(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function now()
  return system.get_time()
end

local function doc_path(doc)
  local path = doc.abs_filename or doc.filename
  if not path or path == "" then return nil end
  if not common.is_absolute_path(path) and system.absolute_path then
    path = system.absolute_path(path)
  end
  return common.normalize_path(path)
end

local function doc_uri(doc)
  local path = doc_path(doc)
  if not path then return nil end
  return uri.path_to_uri(path)
end

local function doc_text(doc)
  return table.concat(doc.lines or {})
end

local function doc_change_id(doc)
  if doc.get_change_id then return doc:get_change_id() end
  return nil
end

local function client_bucket(client)
  local bucket = clients[client]
  if not bucket then
    bucket = { by_uri = {}, by_doc = setmetatable({}, { __mode = "k" }) }
    clients[client] = bucket
  end
  return bucket
end

local function remove_doc_state(bucket, state)
  if bucket.by_uri[state.uri] == state then
    bucket.by_uri[state.uri] = nil
  end
  local list = bucket.by_doc[state.doc]
  if list then
    for i = #list, 1, -1 do
      if list[i] == state then table.remove(list, i) end
    end
    if #list == 0 then bucket.by_doc[state.doc] = nil end
  end
end

local function add_doc_state(bucket, state)
  bucket.by_uri[state.uri] = state
  local list = bucket.by_doc[state.doc]
  if not list then
    list = {}
    bucket.by_doc[state.doc] = list
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
    doc_change_id = doc_change_id(state.doc),
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
  state.last_synced_change_id = doc_change_id(state.doc)
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
  state.last_synced_change_id = doc_change_id(state.doc)
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
    quiet_log("LSP document sync disabled for %s: %s", tostring(state.uri), tostring(reason))
  end
  state.disabled_reason = reason
  state.pending_full_sync = false
  state.pending_due_at = nil
end

function documents.attach(client, doc, opts)
  opts = opts or {}
  local document_uri = opts.uri or doc_uri(doc)
  if not document_uri then
    quiet_log("LSP document sync skipped: document has no file URI")
    return nil, "document has no file URI"
  end

  local bucket = client_bucket(client)
  local existing = bucket.by_uri[document_uri]
  if existing then return existing end

  local state = {
    client = client,
    doc = doc,
    uri = document_uri,
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
    include_save_text = opts.include_save_text == true,
    options = opts,
  }
  add_doc_state(bucket, state)

  if not is_supported(client, opts) then
    disable_state(state, "unsupported")
    return state
  end

  local text = doc_text(doc)
  if is_too_large(state, text) then
    disable_state(state, "too_large")
    return state
  end

  local ok, err = send_did_open(state, text)
  if not ok then
    disable_state(state, err or "didOpen failed")
  end
  return state
end

function documents.detach(client, doc_or_uri)
  local bucket = clients[client]
  if not bucket then return true end
  local states = {}
  if type(doc_or_uri) == "string" then
    local state = bucket.by_uri[doc_or_uri]
    if state then states[1] = state end
  else
    local list = bucket.by_doc[doc_or_uri]
    if list then for i, state in ipairs(list) do states[i] = state end end
  end
  for _, state in ipairs(states) do
    send_did_close(state)
    remove_doc_state(bucket, state)
  end
  return true
end

function documents.state(client, doc_or_uri)
  local bucket = clients[client]
  if not bucket then return nil end
  if type(doc_or_uri) == "string" then return bucket.by_uri[doc_or_uri] end
  local list = bucket.by_doc[doc_or_uri]
  return list and list[1] or nil
end

function documents.states_for_doc(doc)
  local out = {}
  for _, bucket in pairs(clients) do
    local list = bucket.by_doc[doc]
    if list then
      for _, state in ipairs(list) do out[#out + 1] = state end
    end
  end
  return out
end

function documents.on_text_transaction(doc, _transaction)
  local change_id = doc_change_id(doc)
  for _, state in ipairs(documents.states_for_doc(doc)) do
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
  local text = doc_text(state.doc)
  if is_too_large(state, text) then
    send_did_close(state)
    disable_state(state, "too_large")
    return true
  end
  return send_did_change(state, text)
end

function documents.flush(client, doc_or_uri)
  if doc_or_uri then
    local state = documents.state(client, doc_or_uri)
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

function documents.flush_before_request(client, doc_or_uri)
  return documents.flush(client, doc_or_uri)
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

function documents.did_save(client, doc_or_uri)
  local state = documents.state(client, doc_or_uri)
  if not state or state.disabled_reason or not state.opened then return true end
  local params = { textDocument = { uri = state.uri } }
  if state.include_save_text then params.text = doc_text(state.doc) end
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
    if state.snapshots[i].doc_change_id == change_id then return state.snapshots[i] end
  end
  return nil
end

function documents.on_doc_metadata_changed(doc, _reason)
  for _, state in ipairs(documents.states_for_doc(doc)) do
    local new_uri = doc_uri(doc)
    if new_uri and new_uri ~= state.uri then
      local client = state.client
      local opts = state.options
      documents.detach(client, state.uri)
      documents.attach(client, doc, opts)
    end
  end
end

function documents.on_doc_close(doc)
  for _, state in ipairs(documents.states_for_doc(doc)) do
    documents.detach(state.client, state.uri)
  end
end

local function patch_doc()
  if patched then return end
  patched = true

  local old_set_filename = Doc.set_filename
  function Doc:set_filename(...)
    local result = old_set_filename(self, ...)
    documents.on_doc_metadata_changed(self, "filename")
    return result
  end

  local old_load = Doc.load
  function Doc:load(...)
    local result = old_load(self, ...)
    documents.on_doc_metadata_changed(self, "load")
    return result
  end

  local old_reset_syntax = Doc.reset_syntax
  function Doc:reset_syntax(...)
    local result = old_reset_syntax(self, ...)
    if self.lines then documents.on_doc_metadata_changed(self, "syntax") end
    return result
  end

  local old_on_text_transaction = Doc.on_text_transaction
  function Doc:on_text_transaction(transaction)
    old_on_text_transaction(self, transaction)
    documents.on_text_transaction(self, transaction)
  end

  local old_on_close = Doc.on_close
  function Doc:on_close(...)
    documents.on_doc_close(self)
    return old_on_close(self, ...)
  end
end

patch_doc()

return documents
