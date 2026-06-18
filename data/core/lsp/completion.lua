local core = require "core"
local common = require "core.common"
local documents = require "core.lsp.documents"
local lsp_json = require "core.lsp.json"
local position = require "core.lsp.position"

local completion = {}

local cache = setmetatable({}, { __mode = "k" })
local inflight = setmetatable({}, { __mode = "k" })
local request_serial = 0

local COMPLETION_KIND = {
  [1] = "text",
  [2] = "method",
  [3] = "function",
  [4] = "constructor",
  [5] = "field",
  [6] = "variable",
  [7] = "class",
  [8] = "interface",
  [9] = "module",
  [10] = "property",
  [11] = "unit",
  [12] = "value",
  [13] = "enum",
  [14] = "keyword",
  [15] = "snippet",
  [16] = "color",
  [17] = "file",
  [18] = "reference",
  [19] = "folder",
  [20] = "enum_member",
  [21] = "constant",
  [22] = "struct",
  [23] = "event",
  [24] = "operator",
  [25] = "type_parameter",
}

local function quiet_log(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function client_capabilities(client)
  return client.capabilities or client.server_capabilities or {}
end

local function completion_capability(client)
  local provider = client_capabilities(client).completionProvider
  if provider == true then return {} end
  if type(provider) == "table" then return provider end
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
  return table.concat({ tostring(line or 1), tostring(col or 1), tostring(opts.trigger_character or ""), tostring(opts.trigger_kind or "manual") }, ":")
end

local function cancel_inflight(client, uri, reason)
  local pending = inflight[client] and inflight[client][uri]
  if not pending then return 0 end
  local count = 0
  for key, entry in pairs(pending) do
    pending[key] = nil
    count = count + 1
    if client.requests and client.requests.cancel and entry.id then
      client.requests:cancel(entry.id, reason or "superseded completion request")
    end
    if type(client.send_notification) == "function" and entry.id then
      pcall(function()
        client:send_notification("$/cancelRequest", { id = entry.id })
      end)
    end
  end
  return count
end

local function documentation_text(value)
  if type(value) == "string" then return value end
  if type(value) == "table" then return value.value or value[1] end
end

local function item_text(item)
  return item.insertText or item.label or ""
end

local function lsp_text_edit(item)
  local edit = item.textEdit
  if type(edit) ~= "table" then return nil end
  if edit.range then return edit end
  if edit.replace then return { range = edit.replace, newText = edit.newText } end
  if edit.insert then return { range = edit.insert, newText = edit.newText } end
end

local function replace_partial(doc, text)
  local ok, autocomplete = pcall(require, "plugins.autocomplete")
  local partial, line1, col1, line2, col2
  if ok and autocomplete and autocomplete.get_partial_symbol then
    partial, line1, col1, line2, col2 = autocomplete.get_partial_symbol()
  else
    line2, col2 = doc:get_selection()
    line1, col1 = line2, col2
  end
  local edits = {}
  local final_by_idx = {}
  for idx in doc:get_selections(true) do
    edits[#edits + 1] = {
      line1 = line1,
      col1 = col1,
      line2 = line2,
      col2 = col2,
      text = text,
      idx = idx,
    }
    final_by_idx[idx] = "end"
  end
  if #edits == 0 then return false end
  doc:apply_edits(edits, {
    type = "insert",
    selections = doc:selections_after_edits(edits, final_by_idx),
    last_selection = doc.last_selection,
    merge_cursors = false,
  })
  return true
end

local function apply_text_edit(doc, client, edit)
  if not edit or not edit.range then return false end
  local range = position.range_lsp_to_doc(doc, edit.range, client.position_encoding or "utf-16")
  doc:apply_edits({ {
    line1 = range.line1,
    col1 = range.col1,
    line2 = range.line2,
    col2 = range.col2,
    text = edit.newText or "",
  } }, { type = "insert" })
  return true
end

local function make_onselect(doc, client, raw)
  return function()
    local edit = lsp_text_edit(raw)
    if edit then return apply_text_edit(doc, client, edit) end
    return replace_partial(doc, item_text(raw))
  end
end

local function normalize_completion_items(result)
  if result == nil or lsp_json.is_null(result) then return {}, false end
  if type(result) ~= "table" then return {}, false end
  if result.items then
    return type(result.items) == "table" and result.items or {}, result.isIncomplete == true
  end
  return result, false
end

function completion.map_items(client, doc, result)
  local raw_items, incomplete = normalize_completion_items(result)
  local mapped = {}
  for _, raw in ipairs(raw_items) do
    if type(raw) == "table" and raw.insertTextFormat == 2 then
      quiet_log("LSP completion skipped snippet item %s", tostring(raw.label))
    elseif type(raw) == "table" and type(raw.label) == "string" and raw.label ~= "" then
      local label = raw.label
      local insert_text = item_text(raw)
      mapped[#mapped + 1] = {
        label = label,
        text = insert_text ~= "" and insert_text or label,
        info = raw.detail or COMPLETION_KIND[raw.kind] or raw.kind,
        desc = documentation_text(raw.documentation),
        icon = COMPLETION_KIND[raw.kind],
        sort_text = raw.sortText,
        filter_text = raw.filterText,
        raw = raw,
        onselect = make_onselect(doc, client, raw),
      }
    end
  end
  table.sort(mapped, function(a, b)
    local sa = a.sort_text or a.label
    local sb = b.sort_text or b.label
    if sa ~= sb then return tostring(sa) < tostring(sb) end
    return tostring(a.label) < tostring(b.label)
  end)
  return mapped, incomplete
end

function completion.symbols_from_items(items, opts)
  opts = opts or {}
  local symbols = {
    name = opts.name or "lsp-completion",
    files = opts.files or ".*",
    items = {},
  }
  for i, item in ipairs(items or {}) do
    local key = item.label
    if symbols.items[key] ~= nil then key = key .. " #" .. tostring(i) end
    symbols.items[key] = {
      info = item.info,
      icon = item.icon,
      desc = item.desc,
      data = item,
      onselect = item.onselect,
    }
  end
  return symbols
end

function completion.available_clients(doc)
  local out = {}
  for _, state in ipairs(documents.states_for_doc(doc)) do
    local client = state.client
    if state.opened and not state.disabled_reason and completion_capability(client) then
      out[#out + 1] = { client = client, state = state }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.client.server_id or a.client.id or a.client) < tostring(b.client.server_id or b.client.id or b.client)
  end)
  return out
end

local function show_items(items, opts)
  opts = opts or {}
  if #items == 0 then return false, "empty" end
  local ok, autocomplete = pcall(require, "plugins.autocomplete")
  if not ok or not autocomplete or not autocomplete.complete then return nil, "autocomplete unavailable" end
  autocomplete.complete(completion.symbols_from_items(items, opts))
  return true
end

function completion.latest(client, uri, key, version)
  local bucket = cache[client] and cache[client][uri]
  local by_version = bucket and bucket[key]
  return by_version and by_version[version] or nil
end

function completion.request(doc, opts)
  opts = opts or {}
  local matches = completion.available_clients(doc)
  if #matches == 0 then return nil, "unavailable" end
  local line, col = opts.line, opts.col
  if not line or not col then line, col = doc:get_selection() end
  local key = request_key(line, col, opts)
  local first_reason = "pending"
  for _, match in ipairs(matches) do
    local client, state = match.client, match.state
    documents.flush_before_request(client, state.uri)
    state = documents.state(client, state.uri) or state
    local entry = completion.latest(client, state.uri, key, state.lsp_version)
    if entry then
      if opts.show ~= false then show_items(entry.items, { name = "lsp-completion" }) end
      return entry.items, nil, "fresh"
    end
    local ok, reason = completion.schedule(client, state, doc, line, col, opts)
    if ok == nil then first_reason = reason or "unavailable" else first_reason = "pending" end
  end
  return nil, first_reason, first_reason == "unavailable" and "unavailable" or "pending"
end

function completion.schedule(client, state, doc, line, col, opts)
  opts = opts or {}
  if type(client.send_request) ~= "function" then return nil, "client has no request API" end
  cancel_inflight(client, state.uri, "superseded completion request")
  local key = request_key(line, col, opts)
  local pending = bucket_for(inflight, client, state.uri)
  request_serial = request_serial + 1
  local token = request_serial
  local requested_version = state.lsp_version
  local requested_generation = client_generation(client)
  local params = {
    textDocument = { uri = state.uri },
    position = position.doc_to_lsp(doc, line, col, client.position_encoding or "utf-16"),
  }
  if opts.trigger_character then
    params.context = {
      triggerKind = opts.trigger_kind or 2,
      triggerCharacter = opts.trigger_character,
    }
  elseif opts.manual ~= false then
    params.context = { triggerKind = 1 }
  end
  local id, err = client:send_request("textDocument/completion", params, function(result, error_obj)
    local current = pending[key]
    if current and current.token == token then pending[key] = nil end
    local current_state = documents.state(client, state.uri)
    if error_obj then
      quiet_log("LSP completion failed for %s: %s", state.uri, tostring(error_obj.message or error_obj.code))
      return
    end
    if not current or current.token ~= token then
      quiet_log("LSP completion dropped cancelled response for %s", state.uri)
      return
    end
    if client_generation(client) ~= requested_generation then
      quiet_log("LSP completion dropped stale generation response for %s", state.uri)
      return
    end
    if not current_state or current_state.lsp_version ~= requested_version then
      quiet_log("LSP completion dropped stale version response for %s", state.uri)
      return
    end
    local mapped, incomplete = completion.map_items(client, doc, result)
    local by_key = bucket_for(cache, client, state.uri)
    by_key[key] = by_key[key] or {}
    by_key[key][requested_version] = {
      version = requested_version,
      line = line,
      col = col,
      items = mapped,
      incomplete = incomplete,
      received_at = system.get_time(),
      generation = requested_generation,
    }
    if opts.show ~= false then show_items(mapped, { name = "lsp-completion" }) end
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

function completion.start_current_document(view, opts)
  view = view or core.active_view
  if not view or not view.doc then return nil, "no active document" end
  return completion.request(view.doc, opts)
end

function completion.clear_client(client)
  cache[client] = nil
  inflight[client] = nil
end

function completion.clear()
  cache = setmetatable({}, { __mode = "k" })
  inflight = setmetatable({}, { __mode = "k" })
  request_serial = 0
end

return completion
