-- mod-version:3
-- Debounced IntelliJ-like last edit location history for real editor buffers.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local Buffer = require "core.buffer"
local TextView = require "core.textview"

local M = {
  debounce_seconds = 1.0,
  max_entries = 100,
  merge_line_distance = 4,
  debug = true,
}

local locations = {}
local current_index = 1 -- points one past the newest location when at the end
local pending_buffers = setmetatable({}, { __mode = "k" })
local pending_places = setmetatable({}, { __mode = "k" })
local pending_last_edit_time = nil
local flush_thread_running = false
local suppress_recording = false
local navigation_anchor = nil

local original_insert = core.edit_location_history_original_insert or Buffer.insert
local original_remove = core.edit_location_history_original_remove or Buffer.remove
core.edit_location_history_original_insert = original_insert
core.edit_location_history_original_remove = original_remove

local function place_label(place)
  if not place then return "<nil>" end
  local name = place.filename or tostring(place.buffer)
  return string.format("%s:%s:%s", name, tostring(place.line), tostring(place.col))
end

local DEBUG_LOG_FILE = USERDIR .. PATHSEP .. "edit-location-history-debug.log"

local function debug_log(fmt, ...)
  if not M.debug then return end
  local msg = string.format("EditLocationHistory: " .. fmt, ...)
  core.log_quiet("%s", msg)
  local fp = io.open(DEBUG_LOG_FILE, "ab")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n")
    fp:close()
  end
end

local function dump_locations(reason)
  if not M.debug then return end
  local parts = {}
  for i, place in ipairs(locations) do
    parts[#parts + 1] = string.format("%s%s=%s", i == current_index and "*" or "", i, place_label(place))
  end
  debug_log("%s index=%d locations=[%s]", reason, current_index, table.concat(parts, " | "))
end

local function buffer_in_core_buffers(buffer)
  for _, d in ipairs(core.buffers or {}) do
    if d == buffer then return true end
  end
  return false
end

local function active_editor_for_buffer(buffer)
  local view = core.active_view
  if view and view.extends and view:extends(TextView) and view.buffer == buffer then
    return view
  end
end

local function is_real_editor_buffer(buffer)
  if not buffer or not buffer_in_core_buffers(buffer) then return false end
  if buffer == (core.global_prompt_bar and core.global_prompt_bar.buffer) then return false end

  local view = active_editor_for_buffer(buffer)
  if view then
    if view == core.global_prompt_bar or view == core.nag_view then return false end
    if tostring(view) == "FileTreeView" then return false end
  end

  -- Prefer real files, but allow still-open Untitled Buffers as long
  -- as they are normal core buffers. Internal widget buffers are filtered above by
  -- not being in core.buffers.
  return true
end

local function make_place(buffer)
  if not is_real_editor_buffer(buffer) then return nil end
  local view = active_editor_for_buffer(buffer)
  local line, col = buffer:get_selection(false)
  if not line then return nil end
  return {
    buffer = buffer,
    filename = buffer.abs_filename and common.normalize_path(buffer.abs_filename) or nil,
    line = line,
    col = col,
    scroll_x = view and view.scroll and view.scroll.to.x or 0,
    scroll_y = view and view.scroll and view.scroll.to.y or 0,
  }
end

local function current_place()
  local view = core.active_view
  local buffer = view and view.buffer
  return make_place(buffer)
end

local function same_file_or_buffer(a, b)
  if not a or not b then return false end
  if a.filename and b.filename then return common.path_equals(a.filename, b.filename) end
  return a.buffer and b.buffer and a.buffer == b.buffer
end

local function same_or_near_place(a, b)
  return same_file_or_buffer(a, b)
     and math.abs((a.line or 1) - (b.line or 1)) < M.merge_line_distance
end

local function exact_caret_place(a, b)
  return same_file_or_buffer(a, b)
     and (a.line or 1) == (b.line or 1)
     and (a.col or 1) == (b.col or 1)
end

local function place_valid(place)
  if not place then return false end
  if place.filename then return system.get_file_info(place.filename) ~= nil end
  return place.buffer and buffer_in_core_buffers(place.buffer)
end

local function trim_invalid_locations()
  local write = 1
  for read = 1, #locations do
    if place_valid(locations[read]) then
      locations[write] = locations[read]
      write = write + 1
    end
  end
  for i = write, #locations do locations[i] = nil end
  current_index = common.clamp(current_index, 1, #locations + 1)
end

local function append_place(place)
  if not place or not place_valid(place) then debug_log("skip append invalid place %s", place_label(place)); return end

  debug_log("append request %s", place_label(place))

  if same_or_near_place(locations[#locations], place) then
    locations[#locations] = place
  else
    locations[#locations + 1] = place
    while #locations > M.max_entries do table.remove(locations, 1) end
  end
  current_index = #locations + 1
  navigation_anchor = nil
  dump_locations("after append")
end

local function flush_pending()
  if not pending_last_edit_time then return end
  debug_log("flush pending")
  local buffers = {}
  for buffer in pairs(pending_buffers) do buffers[#buffers + 1] = buffer end
  local places = pending_places
  pending_buffers = setmetatable({}, { __mode = "k" })
  pending_places = setmetatable({}, { __mode = "k" })
  pending_last_edit_time = nil

  table.sort(buffers, function(a, b)
    return tostring(a.abs_filename or a) < tostring(b.abs_filename or b)
  end)
  for _, buffer in ipairs(buffers) do
    -- Record the caret/edit site captured when the edit happened, not wherever
    -- the caret happens to be when the debounce timer flushes.
    append_place(places[buffer] or make_place(buffer))
  end
end

local function ensure_flush_thread()
  if flush_thread_running then return end
  flush_thread_running = true
  core.add_thread(function()
    while pending_last_edit_time do
      local remaining = M.debounce_seconds - (system.get_time() - pending_last_edit_time)
      if remaining <= 0 then break end
      coroutine.yield(math.min(remaining, 0.25))
    end
    flush_pending()
    flush_thread_running = false
  end)
end

local function mark_buffer_edited(buffer)
  if suppress_recording then debug_log("skip mark suppressed %s", tostring(buffer)); return end
  if not is_real_editor_buffer(buffer) then debug_log("skip mark non-editor %s", tostring(buffer)); return end

  local place = make_place(buffer)
  if not place then return end
  local pending = pending_places[buffer]
  if pending and same_file_or_buffer(pending, place)
     and math.abs((pending.line or 1) - (place.line or 1)) >= M.merge_line_distance
  then
    debug_log("far edit: flush pending %s before new %s", place_label(pending), place_label(place))
    append_place(pending)
    pending_buffers[buffer] = nil
    pending_places[buffer] = nil
  end

  debug_log("mark edited %s", place_label(place))
  pending_buffers[buffer] = true
  pending_places[buffer] = place
  pending_last_edit_time = system.get_time()
  ensure_flush_thread()
end

function Buffer:insert(...)
  local a, b, c, d, e, f = original_insert(self, ...)
  mark_buffer_edited(self)
  return a, b, c, d, e, f
end

function Buffer:remove(...)
  local a, b, c, d, e, f = original_remove(self, ...)
  mark_buffer_edited(self)
  return a, b, c, d, e, f
end

local function restore_place(place)
  debug_log("restore request %s", place_label(place))
  if not place_valid(place) then debug_log("restore invalid %s", place_label(place)); return false end
  suppress_recording = true
  local ok, err = pcall(function()
    local buffer = place.buffer
    local view
    if place.filename then
      buffer = core.open_buffer(place.filename)
      view = core.root_panel:open_buffer(buffer)
    elseif buffer then
      view = core.root_panel:open_buffer(buffer)
    end
    if not buffer or not view then return end
    buffer:set_selection(place.line, place.col, place.line, place.col)
    if view.scroll then
      view.scroll.to.x, view.scroll.x = place.scroll_x or 0, place.scroll_x or 0
      view.scroll.to.y, view.scroll.y = place.scroll_y or 0, place.scroll_y or 0
    end
    if view.scroll_to_make_visible then view:scroll_to_make_visible(place.line, place.col) end
  end)
  suppress_recording = false
  if not ok then
    core.error("Failed to restore edit location: %s", err)
    return false
  end
  return true
end

local function maybe_reset_index_after_move(current)
  if navigation_anchor and current and not exact_caret_place(navigation_anchor, current) then
    debug_log("caret moved from navigation anchor %s to %s; reset index to end", place_label(navigation_anchor), place_label(current))
    current_index = #locations + 1
    navigation_anchor = nil
  end
end

local function navigate_previous_edit_location()
  debug_log("navigate previous")
  flush_pending()
  trim_invalid_locations()

  local current = current_place()
  maybe_reset_index_after_move(current)
  dump_locations("before previous")
  debug_log("current %s", place_label(current))
  local i = math.min(current_index - 1, #locations)
  while i >= 1 do
    local target = locations[i]
    debug_log("previous candidate i=%d %s same=%s valid=%s", i, place_label(target), tostring(current and exact_caret_place(current, target)), tostring(place_valid(target)))
    if place_valid(target) and (not current or not exact_caret_place(current, target)) then
      if restore_place(target) then
        current_index = i
        navigation_anchor = target
        dump_locations("after previous")
        return
      end
    end
    i = i - 1
  end
end

local function navigate_next_edit_location()
  debug_log("navigate next")
  flush_pending()
  trim_invalid_locations()

  local current = current_place()
  maybe_reset_index_after_move(current)
  dump_locations("before next")
  debug_log("current %s", place_label(current))
  local i = math.max(current_index + 1, 1)
  while i <= #locations do
    local target = locations[i]
    debug_log("next candidate i=%d %s same=%s valid=%s", i, place_label(target), tostring(current and exact_caret_place(current, target)), tostring(place_valid(target)))
    if place_valid(target) and (not current or not exact_caret_place(current, target)) then
      if restore_place(target) then
        current_index = i + 1
        navigation_anchor = target
        dump_locations("after next")
        return
      end
    end
    i = i + 1
  end
end

command.add(nil, {
  ["user:navigate-last-edit-location"] = navigate_previous_edit_location,
  ["user:navigate-next-edit-location"] = navigate_next_edit_location,
})

keymap.add({
  ["alt+g"] = "user:navigate-last-edit-location",
  ["alt+shift+g"] = "user:navigate-next-edit-location",
}, true)

return M
