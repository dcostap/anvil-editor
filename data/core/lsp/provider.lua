local core = require "core"
local language_intelligence = require "core.language_intelligence"
local documents = require "core.lsp.documents"
local position = require "core.lsp.position"

local provider = {}

provider.id = "lsp"
provider.name = "LSP"
provider.priority = 100
provider.kind = "semantic-project"
provider.features = {
  document_outline = true,
}

local clients = setmetatable({}, { __mode = "k" })
local cache = setmetatable({}, { __mode = "k" })
local inflight = setmetatable({}, { __mode = "k" })

local SYMBOL_KIND = {
  [1] = "file",
  [2] = "module",
  [3] = "namespace",
  [4] = "package",
  [5] = "class",
  [6] = "method",
  [7] = "property",
  [8] = "field",
  [9] = "constructor",
  [10] = "enum",
  [11] = "interface",
  [12] = "function",
  [13] = "variable",
  [14] = "constant",
  [15] = "string",
  [16] = "number",
  [17] = "boolean",
  [18] = "array",
  [19] = "object",
  [20] = "key",
  [21] = "null",
  [22] = "enum_member",
  [23] = "struct",
  [24] = "event",
  [25] = "operator",
  [26] = "type_parameter",
}

local function quiet_log(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function client_supports_document_symbols(client)
  local capabilities = client.capabilities or client.server_capabilities or {}
  return capabilities.documentSymbolProvider ~= nil and capabilities.documentSymbolProvider ~= false
end

function provider.is_available(doc, feature)
  if feature ~= "document_outline" then return false end
  for client in pairs(clients) do
    local state = documents.state(client, doc)
    if state and state.opened and not state.disabled_reason and client_supports_document_symbols(client) then
      return true
    end
  end
  return false
end

local function client_generation(client)
  return client.generation or 0
end

local function bucket_for(tbl, client, uri)
  local by_uri = tbl[client]
  if not by_uri then
    by_uri = {}
    tbl[client] = by_uri
  end
  local bucket = by_uri[uri]
  if not bucket then
    bucket = {}
    by_uri[uri] = bucket
  end
  return bucket
end

local function line_byte_offset(doc, line, col)
  local offset = 0
  line = math.max(1, math.min(line or 1, #(doc.lines or { "\n" })))
  for i = 1, line - 1 do
    offset = offset + #(doc.lines[i] or "")
  end
  return offset + math.max(0, (col or 1) - 1)
end

local function range_to_doc(doc, lsp_range, encoding)
  local converted = position.range_lsp_to_doc(doc, lsp_range, encoding)
  converted.start = { line = converted.line1, col = converted.col1 }
  converted["end"] = { line = converted.line2, col = converted.col2 }
  return converted
end

local function symbol_kind_name(kind)
  if type(kind) == "number" then return SYMBOL_KIND[kind] or tostring(kind) end
  return kind
end

local function make_symbol(doc, raw, range, selection_range, kind, name)
  local start_byte = line_byte_offset(doc, range.line1, range.col1)
  local end_byte = line_byte_offset(doc, range.line2, range.col2)
  return {
    name = tostring(name or raw.name or ""),
    kind = symbol_kind_name(kind or raw.kind),
    detail = raw.detail,
    start_line = range.line1,
    start_col = range.col1,
    end_line = range.line2,
    end_col = range.col2,
    start_byte = start_byte,
    end_byte = end_byte,
    range = range,
    name_range = selection_range or range,
    children = {},
    origin = "lsp",
  }
end

local function append_document_symbol(doc, raw, encoding, out, parent_index, depth)
  local range = range_to_doc(doc, raw.range or raw.selectionRange, encoding)
  local selection = raw.selectionRange and range_to_doc(doc, raw.selectionRange, encoding) or range
  local symbol = make_symbol(doc, raw, range, selection, raw.kind, raw.name)
  symbol.depth = depth or 0
  if parent_index then
    symbol.parent = parent_index
    symbol.parent_name = out[parent_index] and out[parent_index].name or nil
    out[parent_index].children[#out[parent_index].children + 1] = #out + 1
  end
  out[#out + 1] = symbol
  symbol.index = #out
  for _, child in ipairs(type(raw.children) == "table" and raw.children or {}) do
    append_document_symbol(doc, child, encoding, out, symbol.index, symbol.depth + 1)
  end
end

local function location_range(raw)
  local location = raw.location or {}
  return location.range or raw.range
end

local function compare_symbols(a, b)
  if a.start_byte ~= b.start_byte then return a.start_byte < b.start_byte end
  if a.end_byte ~= b.end_byte then return a.end_byte > b.end_byte end
  return tostring(a.name) < tostring(b.name)
end

local function contains(parent, child)
  return parent.start_byte <= child.start_byte and parent.end_byte >= child.end_byte
    and (parent.start_byte ~= child.start_byte or parent.end_byte ~= child.end_byte)
end

local function assign_flat_parents(symbols)
  table.sort(symbols, compare_symbols)
  local stack = {}
  for i, symbol in ipairs(symbols) do
    symbol.index = i
    symbol.children = {}
    while #stack > 0 and not contains(stack[#stack], symbol) do stack[#stack] = nil end
    local parent = stack[#stack]
    if parent then
      symbol.parent = parent.index
      symbol.parent_name = parent.name
      symbol.depth = (parent.depth or 0) + 1
      parent.children[#parent.children + 1] = i
    else
      symbol.depth = 0
    end
    stack[#stack + 1] = symbol
  end
end

function provider.map_document_symbols(doc, result, encoding, document_uri)
  local out = {}
  result = type(result) == "table" and result or {}
  local hierarchical = false
  for _, item in ipairs(result) do
    if item.range or item.selectionRange or item.children then hierarchical = true break end
  end

  if hierarchical then
    for _, item in ipairs(result) do
      if item.name and (item.range or item.selectionRange) then
        append_document_symbol(doc, item, encoding or "utf-16", out, nil, 0)
      end
    end
  else
    for _, item in ipairs(result) do
      local location = item.location or {}
      local item_uri = location.uri or item.uri
      if (not document_uri or not item_uri or item_uri == document_uri) and item.name and location_range(item) then
        local range = range_to_doc(doc, location_range(item), encoding or "utf-16")
        out[#out + 1] = make_symbol(doc, item, range, range, item.kind, item.name)
      end
    end
    assign_flat_parents(out)
  end
  return out
end

function provider.register_client(client, opts)
  opts = opts or {}
  clients[client] = {
    client = client,
    server_id = opts.server_id or client.server_id or client.id or "lsp",
  }
  return client
end

function provider.unregister_client(client)
  clients[client] = nil
  cache[client] = nil
  inflight[client] = nil
end

local function matching_clients(doc)
  local out = {}
  for client in pairs(clients) do
    local state = documents.state(client, doc)
    if state and state.opened and not state.disabled_reason and client_supports_document_symbols(client) then
      out[#out + 1] = { client = client, state = state }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.client.server_id or a.client.id or a.client) < tostring(b.client.server_id or b.client.id or b.client)
  end)
  return out
end

local function latest_cache(client, uri, current_version)
  local by_version = cache[client] and cache[client][uri]
  if not by_version then return nil end
  local latest
  for version, entry in pairs(by_version) do
    if version == current_version then return entry, "fresh" end
    if not latest or version > latest.version then latest = entry end
  end
  return latest, latest and "stale" or nil
end

local function request_key(state)
  return tostring(state.lsp_version)
end

function provider.schedule_document_symbols(client, state, doc)
  local pending = bucket_for(inflight, client, state.uri)
  local key = request_key(state)
  if pending[key] then return false, "in-flight" end
  if type(client.send_request) ~= "function" then return nil, "client has no request API" end

  pending[key] = true
  local requested_version = state.lsp_version
  local requested_generation = client_generation(client)
  local ok, err = client:send_request("textDocument/documentSymbol", {
    textDocument = { uri = state.uri },
  }, function(result, error_obj)
    pending[key] = nil
    local current_state = documents.state(client, state.uri)
    if error_obj then
      quiet_log("LSP documentSymbol failed for %s: %s", state.uri, tostring(error_obj.message or error_obj.code))
      return
    end
    if client_generation(client) ~= requested_generation then
      quiet_log("LSP documentSymbol dropped stale generation response for %s", state.uri)
      return
    end
    if not current_state or current_state.lsp_version ~= requested_version then
      quiet_log("LSP documentSymbol dropped stale version response for %s", state.uri)
      return
    end
    local symbols = provider.map_document_symbols(doc, result, client.position_encoding or "utf-16", state.uri)
    bucket_for(cache, client, state.uri)[requested_version] = {
      version = requested_version,
      symbols = symbols,
      received_at = system.get_time(),
      generation = requested_generation,
    }
  end, { generation = requested_generation })
  if not ok then
    pending[key] = nil
    return nil, err
  end
  return true
end

function provider.clear()
  clients = setmetatable({}, { __mode = "k" })
  cache = setmetatable({}, { __mode = "k" })
  inflight = setmetatable({}, { __mode = "k" })
end

function provider.document_outline(doc, opts)
  opts = opts or {}
  local matches = matching_clients(doc)
  if #matches == 0 then return nil, "unavailable", "unavailable" end

  local first_reason = "pending"
  for _, item in ipairs(matches) do
    local client, state = item.client, item.state
    local entry, status = latest_cache(client, state.uri, state.lsp_version)
    if status == "fresh" then
      return entry.symbols, nil, "fresh"
    elseif status == "stale" then
      provider.schedule_document_symbols(client, state, doc)
      return entry.symbols, "refresh scheduled", "stale"
    end

    local ok, reason = provider.schedule_document_symbols(client, state, doc)
    if ok == false then
      first_reason = reason or "pending"
    elseif ok == nil then
      first_reason = reason or "unavailable"
    else
      first_reason = "pending"
    end
  end
  return nil, first_reason, first_reason == "unavailable" and "unavailable" or "pending"
end

language_intelligence.register_provider(provider)

return provider
