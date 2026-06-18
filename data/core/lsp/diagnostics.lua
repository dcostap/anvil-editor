local common = require "core.common"
local position = require "core.lsp.position"
local uri = require "core.lsp.uri"

local diagnostics = {}

local stores = setmetatable({}, { __mode = "k" })

local function server_id_for(client, opts)
  opts = opts or {}
  return opts.server_id
    or client.server_id
    or client.id
    or (client.definition and client.definition.id)
    or "lsp"
end

local function now()
  return system.get_time()
end

local function doc_uri(doc)
  local path = doc and (doc.abs_filename or doc.filename)
  if not path or path == "" then return nil end
  if not common.is_absolute_path(path) and system.absolute_path then
    path = system.absolute_path(path)
  end
  return uri.path_to_uri(common.normalize_path(path))
end

local function path_from_uri(document_uri)
  local path = uri.uri_to_path(document_uri)
  return path and common.normalize_path(path) or nil
end

local function store_for(client, opts)
  local store = stores[client]
  if not store then
    store = {
      client = client,
      server_id = server_id_for(client, opts),
      by_uri = {},
    }
    stores[client] = store
  elseif opts and opts.server_id then
    store.server_id = opts.server_id
  end
  return store
end

function diagnostics.store(client)
  return stores[client]
end

local function document_state(client, document_uri)
  local ok, documents = pcall(require, "core.lsp.documents")
  if not ok or not documents or not documents.state then return nil end
  return documents.state(client, document_uri)
end

local function is_stale_for_state(version, state)
  if version == nil then return false end
  if not state then return false end
  return state.lsp_version ~= version
end

local function normalize_diagnostic(raw, document_uri, version, received_at, store, state)
  raw = type(raw) == "table" and raw or {}
  local code_description = raw.codeDescription or raw.code_description
  local related_information = raw.relatedInformation or raw.related_information
  local stale = is_stale_for_state(version, state)
  return {
    uri = document_uri,
    path = path_from_uri(document_uri),
    lsp_range = raw.range,
    severity = raw.severity,
    code = raw.code,
    codeDescription = code_description,
    code_description = code_description,
    source = raw.source,
    message = raw.message,
    tags = raw.tags,
    relatedInformation = related_information,
    related_information = related_information,
    data = raw.data,
    server_id = store.server_id,
    version = version,
    received_at = received_at,
    stale = stale,
    current = not stale,
    raw = raw,
  }
end

local function refresh_entry_staleness(client, entry)
  local state = document_state(client, entry.uri)
  for _, item in ipairs(entry.diagnostics) do
    item.stale = is_stale_for_state(item.version, state)
    item.current = not item.stale
  end
end

function diagnostics.handle_publish_diagnostics(client, params, opts)
  params = type(params) == "table" and params or {}
  local text_document = type(params.textDocument) == "table" and params.textDocument or {}
  local document_uri = text_document.uri or params.uri
  if type(document_uri) ~= "string" or document_uri == "" then
    return nil, "publishDiagnostics missing textDocument.uri"
  end

  local version = text_document.version
  local received_at = now()
  local store = store_for(client, opts)
  local state = document_state(client, document_uri)
  local normalized = {}
  for _, raw in ipairs(type(params.diagnostics) == "table" and params.diagnostics or {}) do
    normalized[#normalized + 1] = normalize_diagnostic(raw, document_uri, version, received_at, store, state)
  end

  store.by_uri[document_uri] = {
    uri = document_uri,
    path = path_from_uri(document_uri),
    version = version,
    diagnostics = normalized,
    received_at = received_at,
    server_id = store.server_id,
  }
  return store.by_uri[document_uri]
end

function diagnostics.attach_client(client, opts)
  store_for(client, opts)
  if type(client.on_notification) == "function" then
    client:on_notification("textDocument/publishDiagnostics", function(params)
      return diagnostics.handle_publish_diagnostics(client, params, opts)
    end)
  end
  return client
end

function diagnostics.get(client, doc_or_uri)
  local store = stores[client]
  if not store then return {} end
  local document_uri = type(doc_or_uri) == "string" and doc_or_uri or doc_uri(doc_or_uri)
  if not document_uri then return {} end
  local entry = store.by_uri[document_uri]
  if not entry then return {} end
  refresh_entry_staleness(client, entry)
  return entry.diagnostics, entry
end

function diagnostics.all(client)
  local store = stores[client]
  if not store then return {} end
  local out = {}
  for _, entry in pairs(store.by_uri) do
    refresh_entry_staleness(client, entry)
    for _, item in ipairs(entry.diagnostics) do out[#out + 1] = item end
  end
  return out
end

function diagnostics.current(client, doc_or_uri)
  local items = diagnostics.get(client, doc_or_uri)
  local out = {}
  for _, item in ipairs(items) do
    if not item.stale then out[#out + 1] = item end
  end
  return out
end

function diagnostics.doc_range(item, doc, encoding, bias)
  if not item or not item.lsp_range or not doc then return nil end
  encoding = encoding or item.position_encoding
  if not encoding then
    for client, store in pairs(stores) do
      if store.server_id == item.server_id and store.by_uri[item.uri] then
        encoding = client.position_encoding
        break
      end
    end
  end
  encoding = encoding or "utf-16"
  local converted = position.range_lsp_to_doc(doc, item.lsp_range, encoding, bias)
  item.doc_range = converted
  item.doc_range_encoding = encoding
  return converted
end

function diagnostics.clear_uri(client, document_uri)
  local store = stores[client]
  if not store then return 0 end
  if not document_uri then return 0 end
  local existed = store.by_uri[document_uri] ~= nil
  store.by_uri[document_uri] = nil
  return existed and 1 or 0
end

function diagnostics.clear_client(client)
  local store = stores[client]
  if not store then return 0 end
  local count = 0
  for document_uri in pairs(store.by_uri) do
    store.by_uri[document_uri] = nil
    count = count + 1
  end
  stores[client] = nil
  return count
end

function diagnostics.clear_doc(doc)
  local document_uri = doc_uri(doc)
  if not document_uri then return 0 end
  local count = 0
  for client in pairs(stores) do
    count = count + diagnostics.clear_uri(client, document_uri)
  end
  return count
end

local ok, documents = pcall(require, "core.lsp.documents")
if ok and documents and documents.register_doc_close_handler then
  documents.register_doc_close_handler("diagnostics", diagnostics.clear_doc)
end

return diagnostics
