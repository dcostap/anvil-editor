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
  render_tokens = true,
  invalidate_render_cache = true,
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
local semantic_cache = setmetatable({}, { __mode = "k" })
local semantic_inflight = setmetatable({}, { __mode = "k" })
local semantic_line_cache = setmetatable({}, { __mode = "k" })

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

local function doc_change_id(doc)
  if doc and doc.get_change_id then return doc:get_change_id() end
  return nil
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
  elseif feature == "render_tokens" or feature == "invalidate_render_cache" then
    local semantic = capabilities.semanticTokensProvider
    if type(semantic) ~= "table" then return false end
    return semantic.full == true or type(semantic.full) == "table"
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
  navigation_cache[client] = nil
  navigation_inflight[client] = nil
  semantic_cache[client] = nil
  semantic_inflight[client] = nil
  semantic_line_cache[client] = nil
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
  semantic_cache = setmetatable({}, { __mode = "k" })
  semantic_inflight = setmetatable({}, { __mode = "k" })
  semantic_line_cache = setmetatable({}, { __mode = "k" })
  language_intelligence.register_provider(provider)
end

local SEMANTIC_TOKEN_TYPE_MAP = {
  namespace = "type",
  type = "type",
  class = "class",
  enum = "type",
  interface = "interface",
  struct = "type",
  typeParameter = "type",
  parameter = "parameter",
  variable = "variable",
  property = "property",
  enumMember = "constant",
  event = "function",
  function_ = "function",
  method = "function.method",
  macro = "function",
  keyword = "keyword",
  modifier = "keyword2",
  comment = "comment",
  string = "string",
  number = "number",
  regexp = "string",
  operator = "operator",
  decorator = "annotation",
}
SEMANTIC_TOKEN_TYPE_MAP["function"] = "function"

local function semantic_capability(client)
  local capabilities = client_capabilities(client)
  local semantic = capabilities.semanticTokensProvider
  if type(semantic) ~= "table" then return nil end
  if not (semantic.full == true or type(semantic.full) == "table") then return nil end
  local legend = type(semantic.legend) == "table" and semantic.legend or {}
  return semantic, {
    tokenTypes = type(legend.tokenTypes) == "table" and legend.tokenTypes or {},
    tokenModifiers = type(legend.tokenModifiers) == "table" and legend.tokenModifiers or {},
  }
end

local function semantic_legend_key(legend)
  legend = legend or {}
  return table.concat(legend.tokenTypes or {}, "\31") .. "\30" .. table.concat(legend.tokenModifiers or {}, "\31")
end

local function semantic_modifiers(bitset, legend)
  local out = {}
  for i, modifier in ipairs(legend.tokenModifiers or {}) do
    local flag = 2 ^ (i - 1)
    if math.floor((tonumber(bitset) or 0) / flag) % 2 >= 1 then out[modifier] = true end
  end
  return out
end

function provider.semantic_style(token_type, modifiers)
  modifiers = modifiers or {}
  if modifiers.readonly and (token_type == "variable" or token_type == "property") then
    return "constant"
  end
  return SEMANTIC_TOKEN_TYPE_MAP[token_type] or token_type or "normal"
end

local function line_start_offsets(doc)
  local offsets = {}
  local offset = 0
  for i = 1, #(doc.lines or {}) do
    offsets[i] = offset
    offset = offset + #(doc.lines[i] or "")
  end
  offsets[#(doc.lines or {}) + 1] = offset
  return offsets
end

function provider.decode_semantic_tokens(doc, data, legend, encoding)
  local out = {}
  if type(data) ~= "table" then return out end
  legend = legend or {}
  encoding = encoding or "utf-16"
  local current_line = 0
  local current_start = 0
  local starts = line_start_offsets(doc)
  for i = 1, #data, 5 do
    local delta_line = tonumber(data[i]) or 0
    local delta_start = tonumber(data[i + 1]) or 0
    local length = tonumber(data[i + 2]) or 0
    local token_type_index = tonumber(data[i + 3]) or 0
    local modifier_bits = tonumber(data[i + 4]) or 0
    current_line = current_line + delta_line
    if delta_line == 0 then
      current_start = current_start + delta_start
    else
      current_start = delta_start
    end
    local token_type = (legend.tokenTypes or {})[token_type_index + 1]
    local modifiers = semantic_modifiers(modifier_bits, legend)
    local line1, col1 = position.lsp_to_doc(doc, { line = current_line, character = current_start }, encoding)
    local line2, col2 = position.lsp_to_doc(doc, { line = current_line, character = current_start + length }, encoding, "right")
    if line1 == line2 and col2 > col1 then
      out[#out + 1] = {
        line1 = line1,
        col1 = col1,
        line2 = line2,
        col2 = col2,
        start_byte = (starts[line1] or 0) + col1 - 1,
        end_byte = (starts[line2] or 0) + col2 - 1,
        token_type = token_type,
        token_modifiers = modifiers,
        style = provider.semantic_style(token_type, modifiers),
      }
    end
  end
  return out
end

local function add_token(tokens, token_type, text)
  if text == "" then return end
  local n = #tokens
  if n >= 2 and tokens[n - 1] == token_type then
    tokens[n] = tokens[n] .. text
  else
    tokens[n + 1] = token_type
    tokens[n + 2] = text
  end
end

local function base_spans(text, base_tokens, line_start)
  local spans = {}
  local offset = line_start
  for i = 1, #(base_tokens or {}), 2 do
    local token_type = base_tokens[i] or "normal"
    local token_text = base_tokens[i + 1] or ""
    local next_offset = offset + #token_text
    if next_offset > offset then
      spans[#spans + 1] = { start_byte = offset, end_byte = next_offset, style = token_type }
    end
    offset = next_offset
  end
  if #spans == 0 then spans[1] = { start_byte = line_start, end_byte = line_start + #text, style = "normal" } end
  return spans
end

local function semantic_winner(spans, start_byte, end_byte)
  local winner
  for _, span in ipairs(spans or {}) do
    if span.start_byte <= start_byte and span.end_byte >= end_byte then
      if not winner or (span.end_byte - span.start_byte) <= (winner.end_byte - winner.start_byte) then
        winner = span
      end
    end
  end
  return winner
end

local function base_winner(spans, start_byte, end_byte)
  for _, span in ipairs(spans or {}) do
    if span.start_byte <= start_byte and span.end_byte >= end_byte then return span end
  end
end

function provider.overlay_semantic_tokens(text, base_tokens, line_start, semantic_spans)
  line_start = line_start or 0
  local line_end = line_start + #(text or "")
  local boundaries = { line_start, line_end }
  local base = base_spans(text or "", base_tokens, line_start)
  for _, span in ipairs(base) do
    boundaries[#boundaries + 1] = math.max(line_start, math.min(line_end, span.start_byte))
    boundaries[#boundaries + 1] = math.max(line_start, math.min(line_end, span.end_byte))
  end
  for _, span in ipairs(semantic_spans or {}) do
    local s = math.max(line_start, math.min(line_end, span.start_byte or 0))
    local e = math.max(line_start, math.min(line_end, span.end_byte or 0))
    if e > s then
      boundaries[#boundaries + 1] = s
      boundaries[#boundaries + 1] = e
    end
  end
  table.sort(boundaries)
  local tokens = {}
  local last
  for _, boundary in ipairs(boundaries) do
    if boundary ~= last then
      if last and boundary > last then
        local semantic = semantic_winner(semantic_spans, last, boundary)
        local base_span = base_winner(base, last, boundary)
        local style = semantic and semantic.style or (base_span and base_span.style) or "normal"
        add_token(tokens, style, (text or ""):sub(last - line_start + 1, boundary - line_start))
      end
      last = boundary
    end
  end
  if #tokens == 0 then tokens = { "normal", text or "" } end
  return tokens
end

local function semantic_cache_bucket(client, document_uri, legend_key)
  local by_uri = semantic_cache[client]
  if not by_uri then by_uri = {}; semantic_cache[client] = by_uri end
  local by_legend = by_uri[document_uri]
  if not by_legend then by_legend = {}; by_uri[document_uri] = by_legend end
  local by_version = by_legend[legend_key]
  if not by_version then by_version = {}; by_legend[legend_key] = by_version end
  return by_version
end

local function semantic_latest(client, document_uri, legend_key, version)
  local by_uri = semantic_cache[client]
  local by_legend = by_uri and by_uri[document_uri]
  local by_version = by_legend and by_legend[legend_key]
  return by_version and by_version[version] or nil
end

local function semantic_line_cache_bucket(client, document_uri, legend_key)
  local by_uri = semantic_line_cache[client]
  if not by_uri then by_uri = {}; semantic_line_cache[client] = by_uri end
  local by_legend = by_uri[document_uri]
  if not by_legend then by_legend = {}; by_uri[document_uri] = by_legend end
  local by_line = by_legend[legend_key]
  if not by_line then by_line = {}; by_legend[legend_key] = by_line end
  return by_line
end

local function base_render_tokens(doc, line_idx)
  local tokens = language_intelligence.without_provider("lsp", function()
    return language_intelligence.render_tokens(doc, line_idx)
  end)
  if tokens then return tokens end
  if doc and doc.highlighter and doc.highlighter.get_line then
    local line = doc.highlighter:get_line(line_idx)
    return line and line.tokens or nil
  end
  return { "normal", doc and doc.lines and doc.lines[line_idx] or "" }
end

function provider.schedule_semantic_tokens(client, state, doc)
  local _semantic, legend = semantic_capability(client)
  if not legend then return nil, "semantic tokens unsupported" end
  if type(client.send_request) ~= "function" then return nil, "client has no request API" end
  documents.flush_before_request(client, state.uri)
  state = documents.state(client, state.uri) or state
  local legend_key = semantic_legend_key(legend)
  local pending = bucket_for(semantic_inflight, client, state.uri)
  local key = tostring(state.lsp_version) .. ":" .. legend_key
  if pending[key] then return false, "in-flight" end
  pending[key] = true
  local requested_version = state.lsp_version
  local requested_change_id = state.last_synced_change_id
  local requested_generation = client_generation(client)
  local ok, err = client:send_request("textDocument/semanticTokens/full", {
    textDocument = { uri = state.uri },
  }, function(result, error_obj)
    pending[key] = nil
    local current_state = documents.state(client, state.uri)
    if error_obj then
      quiet_log("LSP semanticTokens/full failed for %s: %s", state.uri, tostring(error_obj.message or error_obj.code))
      return
    end
    if client_generation(client) ~= requested_generation then
      quiet_log("LSP semanticTokens/full dropped stale generation response for %s", state.uri)
      return
    end
    if not current_state or current_state.lsp_version ~= requested_version then
      quiet_log("LSP semanticTokens/full dropped stale version response for %s", state.uri)
      return
    end
    if current_state.last_synced_change_id ~= requested_change_id
    or doc_change_id(current_state.doc) ~= current_state.last_synced_change_id then
      quiet_log("LSP semanticTokens/full dropped locally stale response for %s", state.uri)
      return
    end
    result = type(result) == "table" and result or {}
    local decoded = provider.decode_semantic_tokens(doc, result.data or result, legend, client.position_encoding or "utf-16")
    semantic_cache_bucket(client, state.uri, legend_key)[requested_version] = {
      version = requested_version,
      doc_change_id = requested_change_id,
      legend_key = legend_key,
      legend = legend,
      tokens = decoded,
      received_at = system.get_time(),
      generation = requested_generation,
    }
    semantic_line_cache[client] = nil
    if doc.highlighter and doc.highlighter.invalidate_render_cache then
      doc.highlighter:invalidate_render_cache()
    end
  end, { generation = requested_generation })
  if not ok then
    pending[key] = nil
    return nil, err
  end
  return true
end

function provider.render_tokens(doc, line_idx, opts)
  opts = opts or {}
  local matches = matching_clients(doc, "render_tokens")
  if #matches == 0 then return nil, "unavailable", "unavailable" end
  for _, item in ipairs(matches) do
    local client, state = item.client, item.state
    local _semantic, legend = semantic_capability(client)
    local legend_key = semantic_legend_key(legend)
    local entry = semantic_latest(client, state.uri, legend_key, state.lsp_version)
    local current_change_id = doc_change_id(doc)
    local entry_current = entry
      and entry.doc_change_id == state.last_synced_change_id
      and current_change_id == state.last_synced_change_id
    if entry_current then
      local text = doc:get_utf8_line(line_idx) or ""
      local starts = line_start_offsets(doc)
      local line_start = starts[line_idx] or 0
      local line_end = line_start + #text
      local line_cache = semantic_line_cache_bucket(client, state.uri, legend_key)
      local line_key = table.concat({ tostring(state.lsp_version), tostring(entry.doc_change_id), tostring(line_idx), text }, "\0")
      local cached = line_cache[line_idx]
      if cached and cached.key == line_key then return cached.tokens, nil, "fresh" end
      local spans = {}
      for _, token in ipairs(entry.tokens or {}) do
        local s = math.max(line_start, math.min(line_end, token.start_byte or 0))
        local e = math.max(line_start, math.min(line_end, token.end_byte or 0))
        if e > s then
          spans[#spans + 1] = { start_byte = s, end_byte = e, style = token.style }
        end
      end
      local tokens = provider.overlay_semantic_tokens(text, base_render_tokens(doc, line_idx), line_start, spans)
      line_cache[line_idx] = { key = line_key, tokens = tokens }
      return tokens, nil, "fresh"
    elseif entry then
      quiet_log("LSP semantic token cache is locally stale for %s", state.uri)
    end
    provider.schedule_semantic_tokens(client, state, doc)
  end
  return nil, "pending", "pending"
end

function provider.invalidate_render_cache(doc, first_line, last_line)
  for client in pairs(semantic_line_cache) do
    local state = documents.state(client, doc)
    if state and semantic_line_cache[client] then
      if not first_line then
        semantic_line_cache[client][state.uri] = nil
      else
        local by_uri = semantic_line_cache[client][state.uri]
        if by_uri then
          for _, by_line in pairs(by_uri) do
            for line = first_line, last_line or first_line do by_line[line] = nil end
          end
        end
      end
    end
  end
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
    position_encoding = client.position_encoding or "utf-16",
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
