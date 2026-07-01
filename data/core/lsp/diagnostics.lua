local core = require "core"
local command = require "core.command"
local common = require "core.common"
local position = require "core.lsp.position"
local diagnostic_markers = require "core.lsp.diagnostic_markers"
local uri = require "core.lsp.uri"

local diagnostics = {}

local stores = setmetatable({}, { __mode = "k" })
local generation = 0

local function bump_generation()
  generation = generation + 1
  return generation
end

function diagnostics.generation()
  return generation
end

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

local function doc_change_id(doc)
  if doc and doc.get_change_id then return doc:get_change_id() end
  return nil
end

local function is_authoritative_at_receipt(version, state)
  if not state then return true end
  if version ~= nil and state.lsp_version ~= version then return false end
  local change_id = doc_change_id(state.doc)
  return change_id ~= nil and change_id == state.last_synced_change_id
end

local function is_stale_for_state(version, state, received_change_id, authoritative_at_receipt)
  if not state then return false end
  if version ~= nil then
    if state.lsp_version ~= version then return true end
    return doc_change_id(state.doc) ~= state.last_synced_change_id
  end
  if authoritative_at_receipt == false then return true end
  if received_change_id ~= nil and doc_change_id(state.doc) ~= received_change_id then return true end
  return false
end

local function normalize_diagnostic(raw, document_uri, version, received_at, store, state, client)
  raw = type(raw) == "table" and raw or {}
  local code_description = raw.codeDescription or raw.code_description
  local related_information = raw.relatedInformation or raw.related_information
  local received_change_id = state and doc_change_id(state.doc) or nil
  local authoritative = is_authoritative_at_receipt(version, state)
  local stale = is_stale_for_state(version, state, received_change_id, authoritative)
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
    received_change_id = received_change_id,
    authoritative_at_receipt = authoritative,
    position_encoding = client and client.position_encoding or nil,
    stale = stale,
    current = not stale,
    raw = raw,
  }
end

local function refresh_entry_staleness(client, entry)
  local state = document_state(client, entry.uri)
  for _, item in ipairs(entry.diagnostics) do
    item.stale = is_stale_for_state(item.version, state, item.received_change_id, item.authoritative_at_receipt)
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
  document_uri = uri.normalize_file_uri(document_uri)

  local version = text_document.version
  local received_at = now()
  local store = store_for(client, opts)
  local state = document_state(client, document_uri)
  local normalized = {}
  for _, raw in ipairs(type(params.diagnostics) == "table" and params.diagnostics or {}) do
    normalized[#normalized + 1] = normalize_diagnostic(raw, document_uri, version, received_at, store, state, client)
  end

  store.by_uri[document_uri] = {
    uri = document_uri,
    path = path_from_uri(document_uri),
    version = version,
    diagnostics = normalized,
    received_at = received_at,
    server_id = store.server_id,
  }
  bump_generation()
  diagnostic_markers.on_publish(client, document_uri, version, normalized)
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
  local document_uri = type(doc_or_uri) == "string" and uri.normalize_file_uri(doc_or_uri) or doc_uri(doc_or_uri)
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

function diagnostics.current_for_doc(doc)
  local document_uri = doc_uri(doc)
  if not document_uri then return {} end
  local out = {}
  for client in pairs(stores) do
    local items = diagnostics.current(client, document_uri)
    for _, item in ipairs(items) do out[#out + 1] = item end
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
  if existed then
    diagnostic_markers.clear_uri(client, document_uri)
    bump_generation()
  end
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
  diagnostic_markers.clear_client(client)
  if count > 0 then bump_generation() end
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

local function diagnostic_position(item, doc)
  local range = diagnostics.doc_range(item, doc)
  if not range then return nil end
  return range.line1, range.col1, range.line2, range.col2
end

local function compare_diagnostics(a, b)
  if a.line1 ~= b.line1 then return a.line1 < b.line1 end
  if a.col1 ~= b.col1 then return a.col1 < b.col1 end
  return tostring(a.message or "") < tostring(b.message or "")
end

function diagnostics.current_document_items(doc)
  local items = {}
  for _, item in ipairs(diagnostics.current_for_doc(doc)) do
    local line1, col1, line2, col2 = diagnostic_position(item, doc)
    if line1 then
      items[#items + 1] = {
        diagnostic = item,
        line1 = line1,
        col1 = col1,
        line2 = line2,
        col2 = col2,
      }
    end
  end
  table.sort(items, compare_diagnostics)
  return items
end

local function after_cursor(item, line, col)
  return item.line1 > line or (item.line1 == line and item.col1 > col)
end

local function before_cursor(item, line, col)
  return item.line1 < line or (item.line1 == line and item.col1 < col)
end

function diagnostics.next_in_doc(doc, line, col, direction)
  local items = diagnostics.current_document_items(doc)
  if #items == 0 then return nil, "no-diagnostics" end
  line, col = doc:sanitize_position(line or 1, col or 1)
  direction = direction or 1
  if direction < 0 then
    for i = #items, 1, -1 do
      if before_cursor(items[i], line, col) then return items[i] end
    end
    return items[#items]
  end
  for _, item in ipairs(items) do
    if after_cursor(item, line, col) then return item end
  end
  return items[1]
end

function diagnostics.navigate(view, direction)
  local doc = view and view.doc
  if not doc then return nil, "no-document" end
  local line, col = doc:get_selection(true)
  local item, reason = diagnostics.next_in_doc(doc, line, col, direction)
  if not item then return nil, reason end
  doc:set_selection(item.line1, item.col1, item.line2, item.col2)
  if view.scroll_to_make_visible then
    view:scroll_to_make_visible(item.line1, item.col1, true, {
      range_line2 = item.line2,
      range_col2 = item.col2,
    })
  elseif view.scroll_to_line then
    view:scroll_to_line(item.line1, true, true)
  end
  local diagnostic = item.diagnostic
  if core and core.log then
    core.log("LSP diagnostic: %s", tostring(diagnostic.message or diagnostic.code or "diagnostic"))
  end
  return item
end

function diagnostics.summary(doc)
  local items = diagnostics.current_document_items(doc)
  if #items == 0 then return "No current LSP diagnostics" end
  local counts = {}
  for _, item in ipairs(items) do
    local severity = item.diagnostic.severity or "unknown"
    counts[severity] = (counts[severity] or 0) + 1
  end
  return string.format("%d current LSP diagnostic%s", #items, #items == 1 and "" or "s"), counts
end

local function is_doc_view(value)
  return type(value) == "table" and value.doc ~= nil
end

local function active_or_arg_view(view)
  if is_doc_view(view) then return view end
  if is_doc_view(core.active_view) then return core.active_view end
end

local function command_predicate(view)
  local docview = active_or_arg_view(view)
  return docview ~= nil, docview
end

command.add(command_predicate, {
  ["lsp:next-diagnostic"] = function(view)
    local item, reason = diagnostics.navigate(view, 1)
    if not item and core.log then core.log("LSP diagnostics: %s", reason or "none") end
  end,
  ["lsp:previous-diagnostic"] = function(view)
    local item, reason = diagnostics.navigate(view, -1)
    if not item and core.log then core.log("LSP diagnostics: %s", reason or "none") end
  end,
  ["lsp:show-document-diagnostics"] = function(view)
    if core.log then core.log("%s", diagnostics.summary(view.doc)) end
  end,
})

local ok, documents = pcall(require, "core.lsp.documents")
if ok and documents and documents.register_doc_close_handler then
  documents.register_doc_close_handler("diagnostics", diagnostics.clear_doc)
end

return diagnostics
