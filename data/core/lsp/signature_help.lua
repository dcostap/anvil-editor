local core = require "core"
local documents = require "core.lsp.documents"
local lsp_json = require "core.lsp.json"
local position = require "core.lsp.position"

local signature_help = {}

local cache = setmetatable({}, { __mode = "k" })
local inflight = setmetatable({}, { __mode = "k" })
local request_serial = 0

local function quiet_log(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function client_capabilities(client)
  return client.capabilities or client.server_capabilities or {}
end

local function capability(client)
  local value = client_capabilities(client).signatureHelpProvider
  if value == true then return {} end
  if type(value) == "table" then return value end
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

local function request_key(line, col, opts)
  opts = opts or {}
  return table.concat({
    tostring(line or 1),
    tostring(col or 1),
    tostring(opts.trigger_kind or "manual"),
    tostring(opts.trigger_character or ""),
    tostring(opts.retrigger == true),
  }, ":")
end

local function cancel_inflight(client, uri, reason)
  local pending = inflight[client] and inflight[client][uri]
  if not pending then return 0 end
  local count = 0
  for key, entry in pairs(pending) do
    pending[key] = nil
    count = count + 1
    if client.requests and client.requests.cancel and entry.id then
      client.requests:cancel(entry.id, reason or "superseded signature-help request")
    end
    if type(client.send_notification) == "function" and entry.id then
      pcall(function()
        client:send_notification("$/cancelRequest", { id = entry.id })
      end)
    end
  end
  return count
end

function signature_help.normalize_documentation(value)
  if value == nil or lsp_json.is_null(value) then return nil end
  if type(value) == "string" then return value end
  if type(value) == "table" then
    if type(value.value) == "string" then return value.value end
    if type(value[1]) == "string" then return value[1] end
  end
  return tostring(value)
end

local function label_text(label, signature_label)
  if type(label) == "string" then return label end
  if type(label) == "table" and type(signature_label) == "string" then
    local first = tonumber(label[1]) or tonumber(label.start)
    local last = tonumber(label[2]) or tonumber(label["end"])
    if first and last and last > first then
      return signature_label:sub(first + 1, last)
    end
  end
  return ""
end

local function normalize_parameter(raw, signature_label, active)
  raw = type(raw) == "table" and raw or {}
  return {
    label = label_text(raw.label, signature_label),
    documentation = signature_help.normalize_documentation(raw.documentation),
    active = active == true,
    raw = raw,
  }
end

local function clamp_active(index, count)
  index = tonumber(index) or 0
  index = math.floor(index) + 1
  if count <= 0 then return nil end
  if index < 1 then index = 1 end
  if index > count then index = count end
  return index
end

function signature_help.map_result(_client, _doc, result)
  if result == nil or lsp_json.is_null(result) then return { signatures = {}, empty = true } end
  if type(result) ~= "table" then return { signatures = {}, empty = true } end
  local raw_signatures = type(result.signatures) == "table" and result.signatures or {}
  local active_signature = clamp_active(result.activeSignature, #raw_signatures) or 1
  local mapped = {
    signatures = {},
    active_signature = active_signature,
    active_parameter = nil,
    empty = #raw_signatures == 0,
    raw = result,
  }
  for i, raw in ipairs(raw_signatures) do
    raw = type(raw) == "table" and raw or {}
    local label = tostring(raw.label or "")
    local params = {}
    local raw_params = type(raw.parameters) == "table" and raw.parameters or {}
    local raw_active_param = result.activeParameter
    if raw.activeParameter ~= nil then raw_active_param = raw.activeParameter end
    local active_param = clamp_active(raw_active_param, #raw_params)
    for p, param in ipairs(raw_params) do
      params[#params + 1] = normalize_parameter(param, label, active_param == p)
    end
    mapped.signatures[#mapped.signatures + 1] = {
      label = label,
      documentation = signature_help.normalize_documentation(raw.documentation),
      parameters = params,
      active = i == active_signature,
      raw = raw,
    }
    if i == active_signature then mapped.active_parameter = active_param end
  end
  return mapped
end

function signature_help.format(mapped)
  if not mapped or mapped.empty or #(mapped.signatures or {}) == 0 then return "" end
  local sig = mapped.signatures[mapped.active_signature or 1] or mapped.signatures[1]
  if not sig then return "" end
  local parts = { sig.label }
  if sig.documentation and sig.documentation ~= "" then parts[#parts + 1] = sig.documentation end
  local active_param = sig.parameters and sig.parameters[mapped.active_parameter or 0]
  if active_param then
    local param_text = active_param.label
    if active_param.documentation and active_param.documentation ~= "" then
      param_text = param_text .. " — " .. active_param.documentation
    end
    if param_text ~= "" then parts[#parts + 1] = "Parameter: " .. param_text end
  end
  return table.concat(parts, "\n")
end

function signature_help.available_clients(doc)
  local out = {}
  for _, state in ipairs(documents.states_for_doc(doc)) do
    local client = state.client
    if state.opened and not state.disabled_reason and capability(client) then
      out[#out + 1] = { client = client, state = state }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.client.server_id or a.client.id or a.client) < tostring(b.client.server_id or b.client.id or b.client)
  end)
  return out
end

function signature_help.show(mapped)
  local text = signature_help.format(mapped)
  if text == "" then
    quiet_log("LSP signature help: no information")
    return false, "empty"
  end
  if core.log then core.log("LSP signature help: %s", text) end
  return true
end

function signature_help.latest(client, uri, key, version)
  local bucket = cache[client] and cache[client][uri]
  local by_version = bucket and bucket[key]
  return by_version and by_version[version] or nil
end

function signature_help.request(doc, opts)
  opts = opts or {}
  local matches = signature_help.available_clients(doc)
  if #matches == 0 then return nil, "unavailable", "unavailable" end
  local line, col = opts.line, opts.col
  if not line or not col then line, col = doc:get_selection() end
  local key = request_key(line, col, opts)
  local first_reason = "pending"
  for _, match in ipairs(matches) do
    local client, state = match.client, match.state
    documents.flush_before_request(client, state.uri)
    state = documents.state(client, state.uri) or state
    local entry = signature_help.latest(client, state.uri, key, state.lsp_version)
    if entry then
      if opts.show ~= false then signature_help.show(entry.signature_help) end
      return entry.signature_help, nil, "fresh"
    end
    local ok, reason = signature_help.schedule(client, state, doc, line, col, opts)
    if ok == nil then first_reason = reason or "unavailable" else first_reason = "pending" end
  end
  return nil, first_reason, first_reason == "unavailable" and "unavailable" or "pending"
end

local function request_context(opts)
  opts = opts or {}
  local kind = opts.trigger_kind
  if kind == nil then
    kind = opts.trigger_character and 2 or (opts.retrigger and 3 or 1)
  end
  local context = {
    triggerKind = kind,
    isRetrigger = opts.retrigger == true,
  }
  if opts.trigger_character then context.triggerCharacter = opts.trigger_character end
  if opts.active_signature_help then context.activeSignatureHelp = opts.active_signature_help end
  return context
end

function signature_help.schedule(client, state, doc, line, col, opts)
  opts = opts or {}
  if type(client.send_request) ~= "function" then return nil, "client has no request API" end
  cancel_inflight(client, state.uri, "superseded signature-help request")
  local key = request_key(line, col, opts)
  local pending = bucket_for(inflight, client, state.uri)
  request_serial = request_serial + 1
  local token = request_serial
  local requested_version = state.lsp_version
  local requested_generation = client_generation(client)
  local params = {
    textDocument = { uri = state.uri },
    position = position.doc_to_lsp(doc, line, col, client.position_encoding or "utf-16"),
    context = request_context(opts),
  }
  local id, err = client:send_request("textDocument/signatureHelp", params, function(result, error_obj)
    local current = pending[key]
    if current and current.token == token then pending[key] = nil end
    local current_state = documents.state(client, state.uri)
    if error_obj then
      quiet_log("LSP signatureHelp failed for %s: %s", state.uri, tostring(error_obj.message or error_obj.code))
      return
    end
    if not current or current.token ~= token then
      quiet_log("LSP signatureHelp dropped cancelled response for %s", state.uri)
      return
    end
    if client_generation(client) ~= requested_generation then
      quiet_log("LSP signatureHelp dropped stale generation response for %s", state.uri)
      return
    end
    if not current_state or current_state.lsp_version ~= requested_version then
      quiet_log("LSP signatureHelp dropped stale version response for %s", state.uri)
      return
    end
    local mapped = signature_help.map_result(client, doc, result)
    local by_key = bucket_for(cache, client, state.uri)
    by_key[key] = by_key[key] or {}
    by_key[key][requested_version] = {
      version = requested_version,
      line = line,
      col = col,
      signature_help = mapped,
      received_at = system.get_time(),
      generation = requested_generation,
    }
    if opts.show ~= false then signature_help.show(mapped) end
  end, { generation = requested_generation })
  if not id then return nil, err end
  pending[key] = {
    id = id,
    token = token,
    line = line,
    col = col,
    version = requested_version,
    generation = requested_generation,
  }
  return true
end

function signature_help.start_current_position(view, opts)
  view = view or core.active_view
  if not view or not view.doc then return nil, "no active document", "unavailable" end
  return signature_help.request(view.doc, opts)
end

function signature_help.clear_client(client)
  cache[client] = nil
  inflight[client] = nil
end

function signature_help.clear()
  cache = setmetatable({}, { __mode = "k" })
  inflight = setmetatable({}, { __mode = "k" })
  request_serial = 0
end

return signature_help
