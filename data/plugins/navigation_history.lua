-- mod-version:3
-- IntelliJ-style editor navigation history.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local config = require "core.config"
local DocView = require "core.docview"
local Node = require "core.node"

local M = {}

local back_places = {}
local forward_places = {}
local restoring = false
local suppress_count = 0

local tracked_commands = {
  ["doc:set-cursor"] = true,
  ["doc:set-cursor-word"] = true,
  ["doc:set-cursor-line"] = true,
  ["doc:select-to-cursor"] = true,
  ["bracket-match:move-to-matching"] = true,
  ["find-replace:repeat-find"] = true,
  ["find-replace:previous-find"] = true,
  ["poi:previous"] = true,
  ["poi:next"] = true,
  ["poi:side-previous-activate"] = true,
  ["poi:side-next-activate"] = true,
  ["poi:activate"] = true,
  ["poi:activate-side"] = true,
}

local function debug_log(fmt, ...)
  if config.plugins.navigation_history and config.plugins.navigation_history.debug then
    core.log_quiet("NavigationHistory: " .. fmt, ...)
  end
end

local function copy_array(values)
  local copy = {}
  for i = 1, #(values or {}) do copy[i] = values[i] end
  return copy
end

local function clone_selection_state(state)
  if not state then return nil end
  return {
    selections = copy_array(state.selections),
    last_selection = state.last_selection or 1,
  }
end

local function doc_in_core_docs(doc)
  for _, open_doc in ipairs(core.docs or {}) do
    if open_doc == doc then return true end
  end
  return false
end

local function is_docview(view)
  return type(view) == "table"
    and type(view.extends) == "function"
    and view:extends(DocView)
    and view.doc ~= nil
end

local function is_editor_place_view(view)
  if not is_docview(view) then return false end
  if view == core.global_prompt_bar or view == core.nag_view then return false end
  if view.command_output_view then return false end
  return doc_in_core_docs(view.doc)
end

local function place_identity_matches(a, b)
  if not a or not b then return false end
  if a.filename and b.filename then return common.path_equals(a.filename, b.filename) end
  return a.doc ~= nil and a.doc == b.doc
end

local function exact_place_matches(a, b)
  return place_identity_matches(a, b)
    and (a.line or 1) == (b.line or 1)
    and (a.col or 1) == (b.col or 1)
    and (a.line2 or a.line or 1) == (b.line2 or b.line or 1)
    and (a.col2 or a.col or 1) == (b.col2 or b.col or 1)
end

local function significant_place_change(a, b)
  if not a or not b then return false end
  if not place_identity_matches(a, b) then return true end
  return (a.line or 1) ~= (b.line or 1)
    or math.abs((a.col or 1) - (b.col or 1)) > 2
    or (a.line2 or a.line or 1) ~= (b.line2 or b.line or 1)
    or math.abs((a.col2 or a.col or 1) - (b.col2 or b.col or 1)) > 2
end

local function current_stack_limit()
  return math.max(1, math.floor(tonumber(config.plugins.navigation_history.max_entries)))
end

local function place_label(place)
  if not place then return "<nil>" end
  return string.format("%s:%s:%s", tostring(place.filename or place.doc), tostring(place.line), tostring(place.col))
end

function M.capture_place(view)
  if not is_editor_place_view(view) then return nil end
  local doc = view.doc
  local selection_state = view.get_selection_state and view:get_selection_state() or nil
  local selections = selection_state and selection_state.selections or doc.selections or {}
  local last = selection_state and selection_state.last_selection or doc.last_selection or 1
  local offset = ((last - 1) * 4) + 1
  local line = selections[offset] or selections[1]
  local col = selections[offset + 1] or selections[2]
  local line2 = selections[offset + 2] or line
  local col2 = selections[offset + 3] or col
  if not line or not col then return nil end

  return {
    view = view,
    doc = doc,
    filename = doc.abs_filename and common.normalize_path(doc.abs_filename) or nil,
    selection_state = clone_selection_state(selection_state),
    line = line,
    col = col,
    line2 = line2,
    col2 = col2,
    scroll_x = view.scroll and (view.scroll.to.x or view.scroll.x) or 0,
    scroll_y = view.scroll and (view.scroll.to.y or view.scroll.y) or 0,
    timestamp = system.get_time(),
  }
end

function M.capture_current_place()
  return M.capture_place(core.active_view)
end

local function view_is_open(view)
  local root = core.root_panel and core.root_panel.root_node
  return root and view and root:get_node_for_view(view) ~= nil
end

local function place_valid(place)
  if not place then return false end
  if place.doc and doc_in_core_docs(place.doc) then return true end
  return place.filename and system.get_file_info(place.filename) ~= nil
end

local function trim_invalid(stack)
  local write = 1
  for read = 1, #stack do
    if place_valid(stack[read]) then
      stack[write] = stack[read]
      write = write + 1
    end
  end
  for i = write, #stack do stack[i] = nil end
end

local function push_place(stack, place)
  if not place_valid(place) then return false end
  if exact_place_matches(stack[#stack], place) then return false end
  stack[#stack + 1] = place
  local limit = current_stack_limit()
  while #stack > limit do table.remove(stack, 1) end
  return true
end

function M.record_place(place, opts)
  opts = opts or {}
  if suppress_count > 0 or restoring then return false end
  if not place_valid(place) then return false end
  if opts.check_current ~= false and exact_place_matches(M.capture_current_place(), place) then return false end

  local recorded = push_place(back_places, place)
  if recorded and opts.clear_forward ~= false then forward_places = {} end
  if recorded then debug_log("record %s reason=%s", place_label(place), tostring(opts.reason or "manual")) end
  return recorded
end

function M.record_current_place(reason)
  return M.record_place(M.capture_current_place(), {
    reason = reason,
    check_current = false,
  })
end

function M.clear_history()
  back_places = {}
  forward_places = {}
end

function M.back_places()
  trim_invalid(back_places)
  return { table.unpack(back_places) }
end

function M.forward_places()
  trim_invalid(forward_places)
  return { table.unpack(forward_places) }
end

function M.is_back_available()
  trim_invalid(back_places)
  return #back_places > 0
end

function M.is_forward_available()
  trim_invalid(forward_places)
  return #forward_places > 0
end

local function apply_place_to_view(view, place)
  if view.expand_folds_covering_range then
    view:expand_folds_covering_range(place.line, place.col, place.line2 or place.line, place.col2 or place.col, "navigation-history")
  end
  if place.selection_state and view.set_selection_state then
    view:set_selection_state(clone_selection_state(place.selection_state))
  end
  if view.with_selection_state then
    view:with_selection_state(function()
      if place.selection_state and view.doc.set_selection_list then
        view.doc:set_selection_list(copy_array(place.selection_state.selections), place.selection_state.last_selection or 1,
          { sanitized = true, take_ownership = true })
      else
        view.doc:set_selection(place.line, place.col, place.line2 or place.line, place.col2 or place.col)
      end
    end)
  else
    view.doc:set_selection(place.line, place.col, place.line2 or place.line, place.col2 or place.col)
  end
  if view.scroll then
    view.scroll.to.x, view.scroll.x = place.scroll_x or 0, place.scroll_x or 0
    view.scroll.to.y, view.scroll.y = place.scroll_y or 0, place.scroll_y or 0
  end
  if view.scroll_to_make_visible then
    view:scroll_to_make_visible(place.line, place.col)
  elseif view.scroll_to_line then
    view:scroll_to_line(place.line, true, true)
  end
end

function M.restore_place(place)
  if not place_valid(place) then return false end

  restoring = true
  local ok, err = xpcall(function()
    local doc = place.doc
    local view = place.view
    if view and (not view_is_open(view) or view.doc ~= doc) then view = nil end
    if not view then
      if place.filename then doc = core.open_doc(place.filename) end
      if doc then view = core.root_panel:open_doc(doc) end
    else
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then node:set_active_view(view) end
    end
    if not view or not view.doc then error("could not open navigation target") end
    apply_place_to_view(view, place)
    core.set_active_view(view)
  end, debug.traceback)
  restoring = false

  if not ok then
    core.error("Failed to restore navigation place: %s", tostring(err))
    return false
  end
  return true
end

local function pop_target(stack, current)
  while #stack > 0 do
    local target = table.remove(stack)
    if place_valid(target) and not exact_place_matches(current, target) then return target end
  end
end

function M.go_back()
  trim_invalid(back_places)
  local current = M.capture_current_place()
  local target = pop_target(back_places, current)
  if not target then return false end
  if current then push_place(forward_places, current) end
  debug_log("back to %s", place_label(target))
  return M.restore_place(target)
end

function M.go_forward()
  trim_invalid(forward_places)
  local current = M.capture_current_place()
  local target = pop_target(forward_places, current)
  if not target then return false end
  if current then push_place(back_places, current) end
  debug_log("forward to %s", place_label(target))
  return M.restore_place(target)
end

function M.suppress_recording(fn, ...)
  suppress_count = suppress_count + 1
  local args = { n = select("#", ...), ... }
  local ok, result = xpcall(function()
    return { n = 1, fn(table.unpack(args, 1, args.n)) }
  end, debug.traceback)
  suppress_count = suppress_count - 1
  if not ok then error(result, 0) end
  return table.unpack(result, 1, result.n)
end

function M.track_command(name, enabled)
  tracked_commands[name] = enabled ~= false or nil
end

local function install_node_tracking()
  local wrapped = Node.set_active_view
  if wrapped == core.navigation_history_node_set_active_view_wrapper then
    wrapped = core.navigation_history_wrapped_node_set_active_view or wrapped
  end
  core.navigation_history_wrapped_node_set_active_view = wrapped

  local wrapper = function(self, view)
    local history = core.navigation_history or M
    local before = history.capture_current_place()
    local result = wrapped(self, view)
    local after = history.capture_current_place()
    if before and after and significant_place_change(before, after) then
      history.record_place(before, { reason = "view-selection" })
    end
    return result
  end
  core.navigation_history_node_set_active_view_wrapper = wrapper
  Node.set_active_view = wrapper
end

local function install_command_tracking()
  local wrapped = command.perform
  if wrapped == core.navigation_history_command_perform_wrapper then
    wrapped = core.navigation_history_wrapped_command_perform or wrapped
  end
  core.navigation_history_wrapped_command_perform = wrapped

  local wrapper = function(name, ...)
    local history = core.navigation_history or M
    if tracked_commands[name] and suppress_count == 0 and not restoring then
      local before = history.capture_current_place()
      local result = wrapped(name, ...)
      local after = history.capture_current_place()
      if result and before and after and significant_place_change(before, after) then
        history.record_place(before, { reason = "command:" .. tostring(name) })
      end
      return result
    end
    return wrapped(name, ...)
  end
  core.navigation_history_command_perform_wrapper = wrapper
  command.perform = wrapper
end

command.add(function() return M.is_back_available() end, {
  ["navigation:back"] = function()
    M.go_back()
  end,
})

command.add(function() return M.is_forward_available() end, {
  ["navigation:forward"] = function()
    M.go_forward()
  end,
})

keymap.add({
  ["alt+left"] = "navigation:back",
  ["alt+right"] = "navigation:forward",
  ["xclick"] = "navigation:back",
  ["yclick"] = "navigation:forward",
}, true)

core.navigation_history = M

install_node_tracking()
install_command_tracking()

return M
