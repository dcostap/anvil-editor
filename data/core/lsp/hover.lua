local core = require "core"
local documents = require "core.lsp.documents"
local lsp_json = require "core.lsp.json"
local position = require "core.lsp.position"

local hover = {}

local cache = setmetatable({}, { __mode = "k" })
local inflight = setmetatable({}, { __mode = "k" })
local request_serial = 0

local function quiet_log(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function client_capabilities(client)
  return client.capabilities or client.server_capabilities or {}
end

local function hover_capability(client)
  local value = client_capabilities(client).hoverProvider
  return value ~= nil and value ~= false
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

local function request_key(line, col)
  return tostring(line or 1) .. ":" .. tostring(col or 1)
end

local function cancel_inflight(client, uri, reason)
  local pending = inflight[client] and inflight[client][uri]
  if not pending then return 0 end
  local count = 0
  for key, entry in pairs(pending) do
    pending[key] = nil
    count = count + 1
    if client.requests and client.requests.cancel and entry.id then
      client.requests:cancel(entry.id, reason or "superseded hover request")
    end
    if type(client.send_notification) == "function" and entry.id then
      pcall(function()
        client:send_notification("$/cancelRequest", { id = entry.id })
      end)
    end
  end
  return count
end

local function normalize_marked_string(value)
  if type(value) == "string" then return value end
  if type(value) == "table" then
    if type(value.value) == "string" then
      if type(value.language) == "string" and value.language ~= "" then
        return string.format("```%s\n%s\n```", value.language, value.value)
      end
      return value.value
    end
  end
end

function hover.normalize_contents(contents)
  if contents == nil or lsp_json.is_null(contents) then return "" end
  if type(contents) == "string" then return contents end
  if type(contents) ~= "table" then return tostring(contents) end
  if type(contents.kind) == "string" and type(contents.value) == "string" then
    return contents.value
  end
  local marked = normalize_marked_string(contents)
  if marked then return marked end
  local parts = {}
  for _, item in ipairs(contents) do
    local text = hover.normalize_contents(item)
    if text and text ~= "" then parts[#parts + 1] = text end
  end
  return table.concat(parts, "\n\n")
end

function hover.map_result(client, doc, result)
  if result == nil or lsp_json.is_null(result) then
    return { text = "", empty = true }
  end
  if type(result) ~= "table" then
    local text = hover.normalize_contents(result)
    return { text = text, empty = text == "" }
  end
  local text = hover.normalize_contents(result.contents)
  local mapped = {
    text = text,
    empty = text == "",
    raw = result,
  }
  if result.range then
    mapped.range = position.range_lsp_to_doc(doc, result.range, client.position_encoding or "utf-16")
    mapped.lsp_range = result.range
  end
  return mapped
end

function hover.available_clients(doc)
  local out = {}
  for _, state in ipairs(documents.states_for_doc(doc)) do
    local client = state.client
    if state.opened and not state.disabled_reason and hover_capability(client) then
      out[#out + 1] = { client = client, state = state }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.client.server_id or a.client.id or a.client) < tostring(b.client.server_id or b.client.id or b.client)
  end)
  return out
end

function hover.show(mapped)
  if not mapped or mapped.empty or mapped.text == "" then
    quiet_log("LSP hover: no information")
    return false, "empty"
  end
  if core.log then core.log("LSP hover: %s", mapped.text) end
  return true
end

function hover.latest(client, uri, key, version)
  local bucket = cache[client] and cache[client][uri]
  local by_version = bucket and bucket[key]
  return by_version and by_version[version] or nil
end

function hover.request(doc, opts)
  opts = opts or {}
  local matches = hover.available_clients(doc)
  if #matches == 0 then return nil, "unavailable", "unavailable" end
  local line, col = opts.line, opts.col
  if not line or not col then line, col = doc:get_selection() end
  local key = request_key(line, col)
  local first_reason = "pending"
  for _, match in ipairs(matches) do
    local client, state = match.client, match.state
    documents.flush_before_request(client, state.uri)
    state = documents.state(client, state.uri) or state
    local entry = hover.latest(client, state.uri, key, state.lsp_version)
    if entry then
      if opts.show ~= false then hover.show(entry.hover) end
      return entry.hover, nil, "fresh"
    end
    local ok, reason = hover.schedule(client, state, doc, line, col, opts)
    if ok == nil then first_reason = reason or "unavailable" else first_reason = "pending" end
  end
  return nil, first_reason, first_reason == "unavailable" and "unavailable" or "pending"
end

function hover.schedule(client, state, doc, line, col, opts)
  opts = opts or {}
  if type(client.send_request) ~= "function" then return nil, "client has no request API" end
  cancel_inflight(client, state.uri, "superseded hover request")
  local key = request_key(line, col)
  local pending = bucket_for(inflight, client, state.uri)
  request_serial = request_serial + 1
  local token = request_serial
  local requested_version = state.lsp_version
  local requested_generation = client_generation(client)
  local params = {
    textDocument = { uri = state.uri },
    position = position.doc_to_lsp(doc, line, col, client.position_encoding or "utf-16"),
  }
  local id, err = client:send_request("textDocument/hover", params, function(result, error_obj)
    local current = pending[key]
    if current and current.token == token then pending[key] = nil end
    local current_state = documents.state(client, state.uri)
    if error_obj then
      quiet_log("LSP hover failed for %s: %s", state.uri, tostring(error_obj.message or error_obj.code))
      return
    end
    if not current or current.token ~= token then
      quiet_log("LSP hover dropped cancelled response for %s", state.uri)
      return
    end
    if client_generation(client) ~= requested_generation then
      quiet_log("LSP hover dropped stale generation response for %s", state.uri)
      return
    end
    if not current_state or current_state.lsp_version ~= requested_version then
      quiet_log("LSP hover dropped stale version response for %s", state.uri)
      return
    end
    local mapped = hover.map_result(client, doc, result)
    local by_key = bucket_for(cache, client, state.uri)
    by_key[key] = by_key[key] or {}
    by_key[key][requested_version] = {
      version = requested_version,
      line = line,
      col = col,
      hover = mapped,
      received_at = system.get_time(),
      generation = requested_generation,
    }
    if opts.show ~= false then hover.show(mapped) end
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

function hover.start_current_position(view, opts)
  view = view or core.active_view
  if not view or not view.doc then return nil, "no active document", "unavailable" end
  return hover.request(view.doc, opts)
end

function hover.clear_client(client)
  cache[client] = nil
  inflight[client] = nil
end

function hover.clear()
  cache = setmetatable({}, { __mode = "k" })
  inflight = setmetatable({}, { __mode = "k" })
  request_serial = 0
end

return hover
