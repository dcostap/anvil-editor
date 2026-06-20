local core = require "core"
local common = require "core.common"
local Doc = require "core.doc"
local documents = require "core.lsp.documents"
local position = require "core.lsp.position"
local range_marker = require "core.range_marker"
local uri = require "core.lsp.uri"

local diagnostic_markers = {}

local stores = setmetatable({}, { __mode = "k" })
local generation = 0
-- Some LSP servers briefly publish an empty/current diagnostic set while they
-- re-analyze after typing, then publish the real errors a moment later. Keep
-- pending removals visible long enough to recycle them if the real errors come
-- back immediately, otherwise fixed diagnostics should disappear promptly.
local removal_grace_seconds = 0.45
local expiry_thread_running = false

local function bump_generation()
  generation = generation + 1
  return generation
end

function diagnostic_markers.generation()
  return generation
end

function diagnostic_markers.set_removal_grace_seconds(seconds)
  local old = removal_grace_seconds
  removal_grace_seconds = math.max(0, tonumber(seconds) or removal_grace_seconds)
  return old
end

local function doc_change_id(doc)
  if doc and doc.get_change_id then return doc:get_change_id() end
  return nil
end

local function doc_uri(doc)
  local path = doc and (doc.abs_filename or doc.filename)
  if not path or path == "" then return nil end
  if not common.is_absolute_path(path) and system.absolute_path then
    path = system.absolute_path(path)
  end
  return uri.path_to_uri(common.normalize_path(path))
end

local function server_id_for(client)
  return client.server_id
    or client.id
    or (client.definition and client.definition.id)
    or "lsp"
end

local function marker_store(client)
  local store = stores[client]
  if not store then
    store = { by_uri = {}, server_id = server_id_for(client) }
    stores[client] = store
  end
  return store
end

local function entry_for(client, document_uri)
  local store = marker_store(client)
  local entry = store.by_uri[document_uri]
  if not entry then
    entry = { uri = document_uri, markers = {}, server_id = store.server_id }
    store.by_uri[document_uri] = entry
  end
  return entry
end

local function same_diagnostic_key(a, b)
  return tostring(a.server_id or "") == tostring(b.server_id or "")
     and tostring(a.source or "") == tostring(b.source or "")
     and tostring(a.code or "") == tostring(b.code or "")
     and tostring(a.severity or "") == tostring(b.severity or "")
     and tostring(a.message or "") == tostring(b.message or "")
end

local function range_distance(marker, range)
  local mr = marker:range()
  if not mr then return math.huge end
  return math.abs((mr.line1 or 1) - (range.line1 or 1)) * 100000
       + math.abs((mr.col1 or 1) - (range.col1 or 1))
       + math.abs((mr.line2 or mr.line1 or 1) - (range.line2 or range.line1 or 1)) * 100000
       + math.abs((mr.col2 or mr.col1 or 1) - (range.col2 or range.col1 or 1))
end

local function marker_changed(_marker, _reason)
  bump_generation()
end

local function now()
  return system.get_time()
end

local function is_authoritative_publish(state, version)
  if not state or not state.doc then return false end
  local change_id = doc_change_id(state.doc)
  if version ~= nil and version ~= state.lsp_version then return false end
  return change_id ~= nil and change_id == state.last_synced_change_id
end

local function convert_range(item, doc, client)
  if not item or not item.lsp_range then return nil end
  local encoding = item.position_encoding or client.position_encoding or "utf-16"
  return position.range_lsp_to_doc(doc, item.lsp_range, encoding)
end

local function new_marker(entry, doc, item, range)
  local marker = range_marker.new(doc, {
    line1 = range.line1,
    col1 = range.col1,
    line2 = range.line2,
    col2 = range.col2,
    greedy_left = true,
    greedy_right = true,
    sticky_right_on_newline = true,
    preserve_on_replace = true,
    kind = "diagnostic",
    data = {
      diagnostic = item,
      fresh = true,
      stale_tracked = false,
      server_id = item.server_id,
      uri = item.uri,
    },
    on_change = marker_changed,
  })
  entry.markers[#entry.markers + 1] = marker
  return marker
end

local function remove_entry_marker(entry, index, reason)
  local marker = entry.markers[index]
  if marker then
    range_marker.remove(marker)
    marker.invalid_reason = reason or marker.invalid_reason
    table.remove(entry.markers, index)
  end
end

local sweep_expired_removals

local function next_pending_removal_time()
  local next_time
  for _, store in pairs(stores) do
    for _, entry in pairs(store.by_uri) do
      for _, marker in ipairs(entry.markers) do
        local data = marker and marker.data or {}
        if marker and marker:is_valid() and data.pending_removal and data.remove_after then
          if not next_time or data.remove_after < next_time then next_time = data.remove_after end
        end
      end
    end
  end
  return next_time
end

local function schedule_expiry_thread()
  if expiry_thread_running or not core or not core.add_thread then return end
  expiry_thread_running = true
  core.add_thread(function()
    while true do
      local next_time = next_pending_removal_time()
      if not next_time then break end
      while now() < next_time do coroutine.yield() end
      if sweep_expired_removals then sweep_expired_removals(now()) end
      core.redraw = true
    end
    expiry_thread_running = false
  end)
end

local function defer_entry_marker_removal(entry, index, reason)
  local marker = entry.markers[index]
  if not marker or not marker:is_valid() then return false end
  local data = marker.data or {}
  marker.data = data
  data.fresh = false
  data.stale_tracked = true
  data.pending_removal = true
  data.pending_removal_reason = reason or "authoritative-replace"
  data.remove_after = now() + removal_grace_seconds
  schedule_expiry_thread()
  return true
end

local function prune_invalid_markers(entry)
  local removed = 0
  for i = #entry.markers, 1, -1 do
    local marker = entry.markers[i]
    if not marker or not marker:is_valid() then
      remove_entry_marker(entry, i, "invalid")
      removed = removed + 1
    end
  end
  return removed
end

local function sweep_entry(entry, time)
  local removed = prune_invalid_markers(entry)
  for i = #entry.markers, 1, -1 do
    local marker = entry.markers[i]
    local data = marker and marker.data or {}
    if marker and data.pending_removal and (data.remove_after or 0) <= time then
      remove_entry_marker(entry, i, data.pending_removal_reason or "expired-removal")
      removed = removed + 1
    end
  end
  return removed
end

sweep_expired_removals = function(time)
  local removed = 0
  time = time or now()
  for _, store in pairs(stores) do
    for _, entry in pairs(store.by_uri) do
      removed = removed + sweep_entry(entry, time)
    end
  end
  if removed > 0 then
    bump_generation()
    if core and core.log_quiet then
      core.log_quiet("Expired %d deferred LSP diagnostic marker removal(s)", removed)
    end
  end
  return removed
end

local function reconcile_authoritative(client, document_uri, items, version)
  local state = documents.state(client, document_uri)
  local doc = state and state.doc
  if not doc then return false end
  local entry = entry_for(client, document_uri)
  local used = {}
  local changed = prune_invalid_markers(entry) > 0

  for _, item in ipairs(items or {}) do
    local range = convert_range(item, doc, client)
    if range then
      local best_index, best_distance
      local fallback_index, fallback_distance
      for i, marker in ipairs(entry.markers) do
        if not used[i] and marker:is_valid() then
          local data = marker.data or {}
          local dist = range_distance(marker, range)
          if data.diagnostic and same_diagnostic_key(data.diagnostic, item) then
            if not best_distance or dist < best_distance then
              best_index, best_distance = i, dist
            end
          elseif data.diagnostic and tostring((data.diagnostic or {}).severity or "") == tostring(item.severity or "") then
            if dist <= 8 and (not fallback_distance or dist < fallback_distance) then
              fallback_index, fallback_distance = i, dist
            end
          end
        end
      end
      best_index = best_index or fallback_index

      local marker
      if best_index then
        marker = entry.markers[best_index]
        used[best_index] = true
        marker.data = marker.data or {}
        marker.data.diagnostic = item
        marker.data.fresh = true
        marker.data.stale_tracked = false
        marker.data.pending_removal = nil
        marker.data.pending_removal_reason = nil
        marker.data.remove_after = nil
        marker.data.server_id = item.server_id
        marker.data.uri = item.uri
        marker:set_range(range.line1, range.col1, range.line2, range.col2)
      else
        marker = new_marker(entry, doc, item, range)
        used[#entry.markers] = true
      end
      item.visual_marker = marker
      changed = true
    end
  end

  for i = #entry.markers, 1, -1 do
    if not used[i] then
      local marker = entry.markers[i]
      local data = marker and marker.data or {}
      if not data.pending_removal then
        defer_entry_marker_removal(entry, i, "authoritative-replace")
        changed = true
      end
    end
  end

  if changed then
    bump_generation()
    if core and core.log_quiet then
      core.log_quiet(
        "Reconciled LSP diagnostic markers for %s: markers=%d version=%s",
        tostring(document_uri), #entry.markers, tostring(version)
      )
    end
  end
  return changed
end

function diagnostic_markers.on_publish(client, document_uri, version, items)
  local state = documents.state(client, document_uri)
  if not is_authoritative_publish(state, version) then
    if core and core.log_quiet then
      core.log_quiet(
        "Keeping tracked LSP diagnostic markers for stale/non-authoritative publish %s version=%s",
        tostring(document_uri), tostring(version)
      )
    end
    return false, "stale-publish"
  end
  return reconcile_authoritative(client, document_uri, items, version)
end

function diagnostic_markers.mark_doc_stale(doc, _transaction)
  if not doc then return 0 end
  local document_uri = doc_uri(doc)
  if not document_uri then return 0 end
  local count = 0
  for _, store in pairs(stores) do
    local entry = store.by_uri[document_uri]
    if entry then
      for _, marker in ipairs(entry.markers) do
        if marker:is_valid() then
          marker.data = marker.data or {}
          if marker.data.fresh ~= false or marker.data.stale_tracked ~= true
          or marker.data.pending_removal then
            marker.data.fresh = false
            marker.data.stale_tracked = true
            marker.data.pending_removal = nil
            marker.data.pending_removal_reason = nil
            marker.data.remove_after = nil
            count = count + 1
          end
        end
      end
    end
  end
  if count > 0 then
    bump_generation()
    if core and core.log_quiet then
      core.log_quiet("Marked %d LSP diagnostic marker(s) stale-tracked for %s", count, doc:get_name())
    end
  end
  return count
end

function diagnostic_markers.clear_uri(client, document_uri)
  local store = stores[client]
  if not store then return 0 end
  local entry = store.by_uri[document_uri]
  if not entry then return 0 end
  local count = #entry.markers
  for i = #entry.markers, 1, -1 do
    remove_entry_marker(entry, i, "clear-uri")
  end
  store.by_uri[document_uri] = nil
  if count > 0 then bump_generation() end
  return count
end

function diagnostic_markers.clear_client(client)
  local store = stores[client]
  if not store then return 0 end
  local count = 0
  for document_uri in pairs(store.by_uri) do
    count = count + diagnostic_markers.clear_uri(client, document_uri)
  end
  stores[client] = nil
  return count
end

function diagnostic_markers.clear_doc(doc)
  local document_uri = doc_uri(doc)
  if not document_uri then return 0 end
  local count = 0
  for client in pairs(stores) do
    count = count + diagnostic_markers.clear_uri(client, document_uri)
  end
  return count
end

local function compare_items(a, b)
  if a.line1 ~= b.line1 then return a.line1 < b.line1 end
  if a.col1 ~= b.col1 then return a.col1 < b.col1 end
  return tostring(a.diagnostic and a.diagnostic.message or "") < tostring(b.diagnostic and b.diagnostic.message or "")
end

function diagnostic_markers.visual_document_items(doc, opts)
  opts = opts or {}
  local document_uri = doc_uri(doc)
  if not document_uri then return {} end
  local out = {}
  for _, store in pairs(stores) do
    local entry = store.by_uri[document_uri]
    if entry then
      local removed = sweep_entry(entry, now())
      if removed > 0 then bump_generation() end
      for _, marker in ipairs(entry.markers) do
        if marker:is_valid() then
          local data = marker.data or {}
          if opts.include_stale ~= false or data.fresh then
            local range = marker:range()
            if range then
              out[#out + 1] = {
                diagnostic = data.diagnostic,
                marker = marker,
                fresh = data.fresh == true,
                stale_tracked = data.stale_tracked == true,
                line1 = range.line1,
                col1 = range.col1,
                line2 = range.line2,
                col2 = range.col2,
              }
            end
          end
        end
      end
    end
  end
  table.sort(out, compare_items)
  return out
end

if Doc.register_text_transaction_handler then
  Doc.register_text_transaction_handler("lsp_diagnostic_markers", diagnostic_markers.mark_doc_stale)
end

return diagnostic_markers
