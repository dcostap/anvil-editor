local core = require "core"
local common = require "core.common"
local language_intelligence = require "core.language_intelligence"
local documents = require "core.lsp.documents"
local lsp_json = require "core.lsp.json"
local position = require "core.lsp.position"
local uri = require "core.lsp.uri"

local provider = {}

provider.id = "lsp"
provider.name = "LSP"
provider.priority = 100
provider.kind = "semantic-project"
provider.features = {
  document_outline = true,
  definitions = true,
  declarations = true,
  references = true,
}

local clients = setmetatable({}, { __mode = "k" })
local cache = setmetatable({}, { __mode = "k" })
local inflight = setmetatable({}, { __mode = "k" })
local navigation_cache = setmetatable({}, { __mode = "k" })
local navigation_inflight = setmetatable({}, { __mode = "k" })

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

local function capability_enabled(value)
  return value ~= nil and value ~= false
end

local function client_capabilities(client)
  return client.capabilities or client.server_capabilities or {}
end

local function client_supports_document_symbols(client)
  return capability_enabled(client_capabilities(client).documentSymbolProvider)
end

local function feature_supported(client, feature)
  local capabilities = client_capabilities(client)
  if feature == "document_outline" then
    return client_supports_document_symbols(client)
  elseif feature == "definitions" then
    return capability_enabled(capabilities.definitionProvider)
  elseif feature == "declarations" then
    return capability_enabled(capabilities.declarationProvider)
  elseif feature == "references" then
    return capability_enabled(capabilities.referencesProvider)
  end
  return false
end

function provider.is_available(doc, feature)
  if not provider.features[feature] then return false end
  for client in pairs(clients) do
    local state = documents.state(client, doc)
    if state and state.opened and not state.disabled_reason and feature_supported(client, feature) then
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

local function matching_clients(doc, feature)
  local out = {}
  for client in pairs(clients) do
    local state = documents.state(client, doc)
    if state and state.opened and not state.disabled_reason and feature_supported(client, feature or "document_outline") then
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
  navigation_cache = setmetatable({}, { __mode = "k" })
  navigation_inflight = setmetatable({}, { __mode = "k" })
end

function provider.document_outline(doc, opts)
  opts = opts or {}
  local matches = matching_clients(doc, "document_outline")
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

local NAV_METHODS = {
  definitions = "textDocument/definition",
  declarations = "textDocument/declaration",
  references = "textDocument/references",
}

local function request_position(doc, line1, col1)
  if (line1 == nil or col1 == nil) and doc and doc.get_selection then
    line1, col1 = doc:get_selection()
  end
  return line1 or 1, col1 or 1
end

local function navigation_position_key(feature, line, col, opts)
  opts = opts or {}
  local suffix = ""
  if feature == "references" then
    suffix = opts.include_declaration == false and ":nodecl" or ":decl"
  end
  return table.concat({ feature, tostring(line or 1), tostring(col or 1), suffix }, ":")
end

local function navigation_bucket(tbl, client, document_uri, key)
  local by_uri = bucket_for(tbl, client, document_uri)
  local bucket = by_uri[key]
  if not bucket then
    bucket = {}
    by_uri[key] = bucket
  end
  return bucket
end

local function latest_navigation_cache(client, document_uri, key, current_version)
  local by_key = navigation_cache[client] and navigation_cache[client][document_uri]
  local by_version = by_key and by_key[key]
  if not by_version then return nil end
  local latest
  for version, entry in pairs(by_version) do
    if version == current_version then return entry, "fresh" end
    if not latest or version > latest.version then latest = entry end
  end
  return latest, latest and "stale" or nil
end

local function target_doc_for_uri(client, target_uri, current_doc, current_uri)
  if target_uri == current_uri then return current_doc end
  local state = documents.state(client, target_uri)
  return state and state.doc or nil
end

local function map_location(client, current_doc, current_uri, raw, feature)
  if type(raw) ~= "table" then return nil end
  local target_uri = raw.uri or (raw.targetUri)
  local raw_range = raw.range or raw.targetRange
  local raw_selection = raw.selectionRange or raw.targetSelectionRange or raw_range
  if not target_uri or not raw_range then return nil end
  local target_doc = target_doc_for_uri(client, target_uri, current_doc, current_uri)
  local converted_range = target_doc and range_to_doc(target_doc, raw_range, client.position_encoding or "utf-16") or nil
  local converted_selection = target_doc and raw_selection and range_to_doc(target_doc, raw_selection, client.position_encoding or "utf-16") or converted_range
  local path = uri.uri_to_path(target_uri)
  if path then path = common.normalize_path(path) end
  return {
    uri = target_uri,
    path = path,
    range = converted_range,
    selection_range = converted_selection,
    lsp_range = raw_range,
    lsp_selection_range = raw_selection,
    server_id = client.server_id or client.id or "lsp",
    origin = "lsp",
    source = "lsp",
    kind = feature,
  }
end

local function map_navigation_response(client, doc, state, result, feature)
  if result == nil or lsp_json.is_null(result) then return {} end
  local items
  if type(result) == "table" and (result.uri or result.targetUri) then
    items = { result }
  elseif type(result) == "table" then
    items = result
  else
    return {}
  end
  local out = {}
  for _, raw in ipairs(items) do
    local mapped = map_location(client, doc, state.uri, raw, feature)
    if mapped then out[#out + 1] = mapped end
  end
  return out
end

function provider.map_locations(client, doc, state, result, feature)
  return map_navigation_response(client, doc, state, result, feature or "location")
end

function provider.schedule_navigation_request(feature, client, state, doc, line, col, opts)
  local method = NAV_METHODS[feature]
  if not method then return nil, "unknown feature" end
  if type(client.send_request) ~= "function" then return nil, "client has no request API" end
  opts = opts or {}
  local pos_key = navigation_position_key(feature, line, col, opts)
  local pending = navigation_bucket(navigation_inflight, client, state.uri, pos_key)
  local version_key = tostring(state.lsp_version)
  if pending[version_key] then return false, "in-flight" end

  local params = {
    textDocument = { uri = state.uri },
    position = position.doc_to_lsp(doc, line, col, client.position_encoding or "utf-16"),
  }
  if feature == "references" then
    params.context = { includeDeclaration = opts.include_declaration ~= false }
  end

  pending[version_key] = true
  local requested_version = state.lsp_version
  local requested_generation = client_generation(client)
  local ok, err = client:send_request(method, params, function(result, error_obj)
    pending[version_key] = nil
    local current_state = documents.state(client, state.uri)
    if error_obj then
      quiet_log("LSP %s failed for %s: %s", method, state.uri, tostring(error_obj.message or error_obj.code))
      return
    end
    if client_generation(client) ~= requested_generation then
      quiet_log("LSP %s dropped stale generation response for %s", method, state.uri)
      return
    end
    if not current_state or current_state.lsp_version ~= requested_version then
      quiet_log("LSP %s dropped stale version response for %s", method, state.uri)
      return
    end
    local mapped = map_navigation_response(client, doc, state, result, feature)
    navigation_bucket(navigation_cache, client, state.uri, pos_key)[requested_version] = {
      version = requested_version,
      results = mapped,
      received_at = system.get_time(),
      generation = requested_generation,
      line = line,
      col = col,
      feature = feature,
    }
  end, { generation = requested_generation })
  if not ok then
    pending[version_key] = nil
    return nil, err
  end
  return true
end

local function navigation(feature, doc, line1, col1, line2, col2, opts)
  opts = opts or {}
  local matches = matching_clients(doc, feature)
  if #matches == 0 then return nil, "unavailable", "unavailable" end
  local line, col = request_position(doc, line1, col1)
  local pos_key = navigation_position_key(feature, line, col, opts)
  local first_reason = "pending"
  for _, item in ipairs(matches) do
    local client, state = item.client, item.state
    local entry, status = latest_navigation_cache(client, state.uri, pos_key, state.lsp_version)
    if status == "fresh" then
      return entry.results, nil, "fresh"
    elseif status == "stale" then
      provider.schedule_navigation_request(feature, client, state, doc, line, col, opts)
      return entry.results, "refresh scheduled", "stale"
    end
    local ok, reason = provider.schedule_navigation_request(feature, client, state, doc, line, col, opts)
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

function provider.definitions(doc, line1, col1, line2, col2, opts)
  return navigation("definitions", doc, line1, col1, line2, col2, opts)
end

function provider.declarations(doc, line1, col1, line2, col2, opts)
  return navigation("declarations", doc, line1, col1, line2, col2, opts)
end

function provider.references(doc, line1, col1, line2, col2, opts)
  return navigation("references", doc, line1, col1, line2, col2, opts)
end

language_intelligence.register_provider(provider)

return provider
