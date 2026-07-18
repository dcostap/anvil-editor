-- mod-version:3
-- IntelliJ-style scoped navigation history.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local config = require "core.config"
local file_context = require "core.file_context"
local Node = require "core.node"
local panes = require "core.panes"

local M = {}

local histories = {}
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
  ["poi:right-previous-activate"] = true,
  ["poi:right-next-activate"] = true,
  ["poi:activate"] = true,
  ["poi:activate-right"] = true,
  ["filetree:focus-current-file"] = true,
  ["filetree:focus-file"] = true,
  ["filetree:up-dir"] = true,
  ["filetree:project-root"] = true,
  ["command-slots:history-previous"] = true,
  ["command-slots:history-next"] = true,
  ["git:select-next-row"] = true,
  ["git:select-previous-row"] = true,
  ["git:activate-selected-row"] = true,
}

local DEBUG_LOG_FILE = (os.getenv("TEMP") or os.getenv("TMP") or USERDIR)
  .. PATHSEP .. "anvil-navigation-history-" .. system.get_process_id() .. ".log"
local debug_state = core.navigation_history_debug_state
if not debug_state then
  debug_state = { session_started = false, buffer = {} }
  core.navigation_history_debug_state = debug_state
elseif debug_state.file then
  pcall(debug_state.file.close, debug_state.file)
  debug_state.file = nil
end
debug_state.buffer = debug_state.buffer or {}

local function formatted_debug_message(fmt, ...)
  local ok, message = pcall(string.format, "NavigationHistory: " .. fmt, ...)
  return ok and message or ("NavigationHistory: debug formatting failed: " .. tostring(message))
end

local flush_debug_log

local function debug_enabled()
  local settings = config.plugins.navigation_history
  if not (settings and settings.debug) then return false end
  if package.loaded["core.test"] then return false end
  return true
end

local function debug_log(fmt, ...)
  if not debug_enabled() then return end
  local message = formatted_debug_message(fmt, ...)
  debug_state.buffer[#debug_state.buffer + 1] = os.date("%Y-%m-%d %H:%M:%S ") .. message .. "\n"
  if #debug_state.buffer >= 5000 then flush_debug_log() end
end

flush_debug_log = function()
  if not debug_enabled() then
    debug_state.buffer = {}
    return true
  end
  if #debug_state.buffer == 0 then return true end
  if not debug_state.file then
    debug_state.file = io.open(DEBUG_LOG_FILE, debug_state.session_started and "ab" or "wb")
    debug_state.session_started = true
  end
  if debug_state.file then
    debug_state.file:write(table.concat(debug_state.buffer))
    debug_state.file:flush()
    debug_state.buffer = {}
    return true
  end
  return false
end

local function main_debug_log(fmt, ...)
  if not debug_enabled() then return end
  debug_log(fmt, ...)
  if config.plugins.navigation_history and config.plugins.navigation_history.debug_main_log then
    core.log_quiet("NavigationHistory: " .. fmt, ...)
  end
end

if debug_enabled() then
  core.log_quiet("NavigationHistory: detailed trace file %s", DEBUG_LOG_FILE)
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

local function view_is_open(view)
  local root = core.root_panel and core.root_panel.root_node
  return root and view and root:get_node_for_view(view) ~= nil
end

local function fuzzy_searcher_owns_view(view)
  local picker = core.fuzzy_searcher_active_view
  if not (picker and picker.is_visible and picker:is_visible()) then return false end
  if view == picker or view == picker.input or view == picker.child_active then return true end
  if picker.input and view == picker.input.textview then return true end
  if view and (view.parent == picker or view.subparent == picker or view.__fuzzy_searcher_owner == picker) then return true end
  if picker.input and view and (view.parent == picker.input or view.subparent == picker.input) then return true end
  return false
end

local function is_transient_place_view(view)
  if not view then return true end
  if view == core.global_prompt_bar or view == core.nag_view or view == core.status_bar or view == core.title_bar then return true end
  if panes.is_placeholder(view) then return true end
  if view.local_find_input then return true end
  if fuzzy_searcher_owns_view(view) then return true end
  return false
end

local function command_output_owner(view)
  if not view then return nil end
  if view.command_output_panel then return view end
  local owner = view.__pane_focus_owner
  if view.command_output_view and owner and owner.command_output_panel then return owner end
end

local function output_entry_exists(slot, entry)
  if not entry then return true end
  for _, candidate in ipairs(slot and slot.output_history or {}) do
    if candidate == entry then return true end
  end
  return false
end

local function git_owner(view)
  if not view then return nil end
  local owner = view.git_owner_view or view
  if owner and owner.model and type(owner.model.log_tab) == "function" then return owner end
end

local function navigation_scope(view)
  if type(view) ~= "table" or is_transient_place_view(view) then return nil end

  local pane, pane_owner = panes.pane_for_view(view)
  if not pane then return nil end

  local owner = git_owner(view)
  if owner then
    return {
      key = pane,
      kind = "git",
      owner = owner,
      pane = pane,
    }
  end

  owner = command_output_owner(view)
  if owner then return { key = pane, kind = "command-output", owner = owner, pane = pane } end

  if view.navigation_scope_kind == "file-tree" then
    return { key = pane, kind = "file-tree", owner = view, pane = pane }
  end

  if file_context.is_editor_view(view) or (view.doc and view.doc.git_historical_read_only) then
    return { key = pane, kind = "editor", owner = pane_owner or view, pane = pane }
  end
end

local function scope_owner_is_open(scope)
  return scope and view_is_open(scope.owner) or false
end

local function history_for(scope_key, create)
  if scope_key == nil then return nil end
  local history = histories[scope_key]
  if not history and create then
    history = { back = {}, forward = {} }
    histories[scope_key] = history
  end
  return history
end

local function place_identity_matches(a, b)
  if not a or not b then return false end
  if a.scope_key ~= b.scope_key or a.scope_kind ~= b.scope_kind then return false end
  if a.scope_kind == "command-output" then
    return a.scope_owner == b.scope_owner
      and a.output_slot_index == b.output_slot_index
      and a.output_entry == b.output_entry
  end
  if a.scope_kind == "git" then
    return a.git_owner == b.git_owner
      and a.git_tab_id == b.git_tab_id
      and a.git_pane == b.git_pane
      and a.git_diff_side == b.git_diff_side
  end
  if a.scope_kind == "file-tree" then return a.scope_owner == b.scope_owner end
  if a.view and b.view then return a.view == b.view end
  if a.filename and b.filename then return common.path_equals(a.filename, b.filename) end
  if a.doc ~= nil and b.doc ~= nil then return a.doc == b.doc end
  return false
end

local function file_tree_selection_matches(a, b)
  local aa = a and a.selections
  local bb = b and b.selections
  if not aa or not bb or #aa ~= #bb then return false end
  if (a.last_selection or 1) ~= (b.last_selection or 1) then return false end
  for index, selection in ipairs(aa) do
    local other = bb[index]
    if not other
      or not common.path_equals(selection.line1_abs, other.line1_abs)
      or not common.path_equals(selection.line2_abs, other.line2_abs)
      or selection.col1 ~= other.col1
      or selection.col2 ~= other.col2
    then
      return false
    end
  end
  return true
end

local function optional_path_matches(a, b)
  if a == nil or b == nil then return a == b end
  return common.path_equals(a, b)
end

local function exact_place_matches(a, b)
  if not place_identity_matches(a, b) then return false end
  if a.scope_kind == "file-tree"
    and not optional_path_matches(a.file_tree_current_dir, b.file_tree_current_dir)
  then
    return false
  end
  if a.scope_kind == "file-tree" and a.file_tree_selection_paths and b.file_tree_selection_paths then
    return file_tree_selection_matches(a.file_tree_selection_paths, b.file_tree_selection_paths)
  end
  if a.scope_kind == "git"
    and (a.git_commit_hash or b.git_commit_hash or a.git_file_path or b.git_file_path)
    and (a.git_commit_hash ~= b.git_commit_hash or a.git_file_path ~= b.git_file_path)
  then
    return false
  end
  return (a.line or 1) == (b.line or 1)
    and (a.col or 1) == (b.col or 1)
    and (a.line2 or a.line or 1) == (b.line2 or b.line or 1)
    and (a.col2 or a.col or 1) == (b.col2 or b.col or 1)
end

local function significant_place_change(a, b)
  if not a or not b then return false end
  if not place_identity_matches(a, b) then return true end
  if a.scope_kind == "file-tree"
    and not optional_path_matches(a.file_tree_current_dir, b.file_tree_current_dir)
  then
    return true
  end
  if a.scope_kind == "file-tree" and a.file_tree_selection_paths and b.file_tree_selection_paths then
    return not file_tree_selection_matches(a.file_tree_selection_paths, b.file_tree_selection_paths)
  end
  if a.scope_kind == "git"
    and (a.git_commit_hash ~= b.git_commit_hash or a.git_file_path ~= b.git_file_path)
  then
    return true
  end
  return (a.line or 1) ~= (b.line or 1)
    or math.abs((a.col or 1) - (b.col or 1)) > 2
    or (a.line2 or a.line or 1) ~= (b.line2 or b.line or 1)
    or math.abs((a.col2 or a.col or 1) - (b.col2 or b.col or 1)) > 2
end

local function current_stack_limit()
  return math.max(1, math.floor(tonumber(config.plugins.navigation_history.max_entries)))
end

local function view_label(view)
  if not view then return "<nil>" end
  if type(view) ~= "table" then return string.format("%s{type=%s}", tostring(view), type(view)) end
  local doc = view.doc
  local filename = doc and (doc.abs_filename or doc.filename) or view.path
  return string.format("%s{file=%s doc=%s open=%s active=%s}",
    tostring(view), tostring(filename), tostring(doc), tostring(view_is_open(view)), tostring(core.active_view == view))
end

local function place_label(place)
  if not place then return "<nil>" end
  local selection_count = place.selection_state and math.floor(#(place.selection_state.selections or {}) / 4) or 0
  return string.format(
    "{scope=%s key=%s pane=%s file=%s view=%s doc=%s sel=%s,%s-%s,%s selections=%d scroll=%.1f,%.1f git=%s/%s/%s output_slot=%s tree_dir=%s}",
    tostring(place.scope_kind), tostring(place.scope_key), tostring(place.pane), tostring(place.filename), tostring(place.view),
    tostring(place.doc), tostring(place.line), tostring(place.col), tostring(place.line2), tostring(place.col2),
    selection_count, tonumber(place.scroll_x) or 0, tonumber(place.scroll_y) or 0,
    tostring(place.git_tab_id), tostring(place.git_pane), tostring(place.git_diff_side),
    tostring(place.output_slot_index), tostring(place.file_tree_current_dir))
end

local function stack_label(stack)
  local parts = {}
  for index, place in ipairs(stack or {}) do
    parts[#parts + 1] = string.format("[%d]=%s", index, place_label(place))
  end
  return table.concat(parts, " | ")
end

local function dump_history(scope_key, history, reason)
  if not history then
    debug_log("state reason=%s scope_key=%s history=<nil>", tostring(reason), tostring(scope_key))
    return
  end
  debug_log("state reason=%s scope_key=%s back_count=%d forward_count=%d back=[%s] forward=[%s]",
    tostring(reason), tostring(scope_key), #history.back, #history.forward,
    stack_label(history.back), stack_label(history.forward))
end

local function capture_git_anchor(owner, view, line, diff_side)
  local tab = owner and owner.model_tab and owner:model_tab()
  if not tab then return nil, nil end
  if view.git_pane == "log-list" or view.git_pane == "history-list" then
    local commit = tab.commits and tab.commits[line or 1]
    return commit and commit.hash or nil, nil
  end
  if view.git_pane == "file-list" and tab.kind == "commit_diff" then
    local index = view.git_file_line_to_index and view.git_file_line_to_index[line or 1]
    if not index and not view.git_file_line_to_index then index = line end
    local file = index and tab.changed_files and tab.changed_files[index]
    return nil, file and (file.new_path or file.path or file.old_path) or nil
  end
  if diff_side and tab.kind == "commit_diff" then
    local file = tab.changed_files and tab.changed_files[tab.selected_file or 1]
    return nil, file and (file.new_path or file.path or file.old_path) or nil
  end
end

function M.capture_place(view)
  local scope = navigation_scope(view)
  if not scope then
    local reason
    if not view then
      reason = "no-view"
    elseif type(view) ~= "table" then
      reason = "non-table-view"
    elseif is_transient_place_view(view) then
      reason = "transient-view"
    else
      reason = "untracked-view-kind"
    end
    debug_log("capture rejected reason=%s requested=%s active=%s", reason, view_label(view), view_label(core.active_view))
    return nil
  end
  if not scope_owner_is_open(scope) then
    main_debug_log("capture rejected reason=scope-owner-not-open scope=%s key=%s owner=%s requested=%s active=%s",
      tostring(scope.kind), tostring(scope.key), view_label(scope.owner), view_label(view), view_label(core.active_view))
    return nil
  end
  if view == scope.owner and type(view.get_focus_view) == "function" then
    view = view:get_focus_view() or view
  end
  local doc = view.doc
  local selection_state = view.get_selection_state and view:get_selection_state() or nil
  local selections = selection_state and selection_state.selections or (doc and doc.selections) or {}
  local last = selection_state and selection_state.last_selection or (doc and doc.last_selection) or 1
  local offset = ((last - 1) * 4) + 1
  local line = selections[offset] or selections[1]
  local col = selections[offset + 1] or selections[2]
  local line2 = selections[offset + 2] or line
  local col2 = selections[offset + 3] or col
  local path = doc and doc.abs_filename or view.path
  local output_owner = scope.kind == "command-output" and scope.owner or nil
  local git_view = scope.kind == "git" and scope.owner or nil
  local git_diff_side
  if git_view and git_view.model_tab then
    local tab = git_view:model_tab()
    local diff = tab and tab.diff_view
    if diff and view == diff.doc_view_a then
      git_diff_side = "left"
    elseif diff and view == diff.doc_view_b then
      git_diff_side = "right"
    end
  end
  local git_commit_hash, git_file_path = capture_git_anchor(git_view, view, line, git_diff_side)

  return {
    scope_key = scope.key,
    scope_kind = scope.kind,
    scope_owner = scope.owner,
    pane = scope.pane,
    view = view,
    doc = doc,
    filename = path and common.normalize_path(path) or nil,
    selection_state = clone_selection_state(selection_state),
    line = line,
    col = col,
    line2 = line2,
    col2 = col2,
    scroll_x = view.scroll and (view.scroll.to.x or view.scroll.x) or 0,
    scroll_y = view.scroll and (view.scroll.to.y or view.scroll.y) or 0,
    output_slot_index = output_owner and view.slot and view.slot.index or nil,
    output_entry = output_owner and view.displayed_entry or nil,
    git_owner = git_view,
    git_tab_id = git_view and git_view.tab_id or nil,
    git_pane = git_view and view.git_pane or nil,
    git_diff_side = git_diff_side,
    git_commit_hash = git_commit_hash,
    git_file_path = git_file_path,
    file_tree_selection_paths = scope.kind == "file-tree" and view.capture_selection_paths
      and view:capture_selection_paths() or nil,
    file_tree_current_dir = scope.kind == "file-tree" and view.current_dir
      and common.normalize_path(view.current_dir) or nil,
    timestamp = system.get_time(),
  }
end

function M.capture_current_place()
  return M.capture_place(core.active_view)
end

local function place_invalid_reason(place)
  if not place then return "missing-place" end
  if place.scope_kind == "command-output" then
    local owner = place.scope_owner
    if not owner then return "command-output-owner-missing" end
    if not owner.command_output_panel then return "command-output-panel-missing" end
    if not view_is_open(owner) then return "command-output-owner-closed" end
    if not place.output_slot_index then return "command-output-slot-missing" end
    local view = owner.views and owner.views[place.output_slot_index]
    if not view then return "command-output-view-missing" end
    if view ~= place.view then return "command-output-view-replaced" end
    if view.__pane_focus_owner ~= owner then return "command-output-owner-changed" end
    if not output_entry_exists(view.slot, place.output_entry) then return "command-output-entry-evicted" end
    return nil
  end
  if place.scope_kind == "git" then
    local owner = place.git_owner
    if not owner then return "git-owner-missing" end
    if not view_is_open(owner) then return "git-owner-closed" end
    if not (owner.model and owner.model.find_tab) then return "git-model-unavailable" end
    local tab = owner.model:find_tab(place.git_tab_id)
    if not tab then return "git-tab-closed" end
    if place.git_commit_hash then
      for _, commit in ipairs(tab.commits or {}) do
        if commit.hash == place.git_commit_hash then return nil end
      end
      return "git-commit-evicted"
    end
    if place.git_file_path then
      for _, file in ipairs(tab.changed_files or {}) do
        if (file.new_path or file.path or file.old_path) == place.git_file_path then return nil end
      end
      return "git-file-evicted"
    end
    return nil
  end
  if place.scope_kind == "file-tree" and place.file_tree_current_dir then
    local info = system.get_file_info(place.file_tree_current_dir)
    if not (info and info.type == "dir") then return "file-tree-directory-missing" end
  end
  if place.view and view_is_open(place.view) then
    if place.doc ~= nil and place.view.doc ~= place.doc then return "open-view-document-changed" end
    return nil
  end
  if place.scope_kind ~= "editor" and place.view and not view_is_open(place.view) then
    return "removed-tool-not-rebuildable"
  end
  if place.doc and doc_in_core_docs(place.doc) then return nil end
  if not place.filename then return "document-closed-and-no-filename" end
  if not system.get_file_info(place.filename) then return "file-missing" end
  return nil
end

local function place_valid(place)
  return place_invalid_reason(place) == nil
end

local function trim_invalid(stack, stack_name, scope_key, reason)
  local write = 1
  for read = 1, #stack do
    local invalid_reason = place_invalid_reason(stack[read])
    if not invalid_reason then
      stack[write] = stack[read]
      write = write + 1
    else
      main_debug_log("trim invalid stack=%s scope_key=%s reason=%s invalid_reason=%s place=%s",
        tostring(stack_name), tostring(scope_key), tostring(reason), invalid_reason, place_label(stack[read]))
    end
  end
  for i = write, #stack do stack[i] = nil end
end

local function trim_all_histories(reason)
  for scope_key, history in pairs(histories) do
    trim_invalid(history.back, "back", scope_key, reason)
    trim_invalid(history.forward, "forward", scope_key, reason)
    if #history.back == 0 and #history.forward == 0 then
      debug_log("discard empty history scope_key=%s reason=%s", tostring(scope_key), tostring(reason))
      histories[scope_key] = nil
    end
  end
end

local function push_place(stack, place, stack_name, reason)
  local invalid_reason = place_invalid_reason(place)
  if invalid_reason then
    debug_log("push rejected stack=%s reason=%s invalid_reason=%s place=%s",
      tostring(stack_name), tostring(reason), invalid_reason, place_label(place))
    return false
  end
  if exact_place_matches(stack[#stack], place) then
    debug_log("push rejected stack=%s reason=%s duplicate_top=%s", tostring(stack_name), tostring(reason), place_label(place))
    return false
  end
  stack[#stack + 1] = place
  local limit = current_stack_limit()
  while #stack > limit do
    local evicted = table.remove(stack, 1)
    debug_log("push evicted oldest stack=%s reason=%s limit=%d place=%s",
      tostring(stack_name), tostring(reason), limit, place_label(evicted))
  end
  debug_log("push accepted stack=%s reason=%s count=%d place=%s",
    tostring(stack_name), tostring(reason), #stack, place_label(place))
  return true
end

function M.record_place(place, opts)
  opts = opts or {}
  local reason = tostring(opts.reason or "manual")
  debug_log("record request reason=%s suppress_count=%d restoring=%s check_current=%s clear_forward=%s place=%s",
    reason, suppress_count, tostring(restoring), tostring(opts.check_current ~= false),
    tostring(opts.clear_forward ~= false), place_label(place))
  if suppress_count > 0 or restoring then
    main_debug_log("record rejected reason=%s gate=%s", reason, suppress_count > 0 and "suppressed" or "restoring")
    return false
  end
  local invalid_reason = place_invalid_reason(place)
  if invalid_reason then
    main_debug_log("record rejected reason=%s invalid_reason=%s place=%s", reason, invalid_reason, place_label(place))
    return false
  end
  if opts.check_current ~= false then
    local current = M.capture_current_place()
    if exact_place_matches(current, place) then
      debug_log("record rejected reason=%s same-as-current current=%s", reason, place_label(current))
      return false
    end
    debug_log("record current comparison reason=%s same=false current=%s candidate=%s",
      reason, place_label(current), place_label(place))
  end

  trim_all_histories("record:" .. reason)
  local history = history_for(place.scope_key, true)
  local recorded = push_place(history.back, place, "back", reason)
  if recorded and opts.clear_forward ~= false then
    debug_log("record clearing forward reason=%s discarded_count=%d", reason, #history.forward)
    history.forward = {}
  end
  if recorded then
    debug_log("record accepted scope=%s reason=%s place=%s", tostring(place.scope_kind), reason, place_label(place))
    dump_history(place.scope_key, history, "after-record:" .. reason)
  else
    dump_history(place.scope_key, history, "after-rejected-record:" .. reason)
  end
  if reason == "pane-editor-replace" then flush_debug_log() end
  return recorded
end

function M.record_current_place(reason)
  return M.record_place(M.capture_current_place(), {
    reason = reason,
    check_current = false,
  })
end

function M.clear_history()
  local scope_count = 0
  for _ in pairs(histories) do scope_count = scope_count + 1 end
  debug_log("clear all histories scope_count=%d", scope_count)
  histories = {}
  flush_debug_log()
end

local function current_history()
  trim_all_histories("current-history")
  local place = M.capture_current_place()
  return place and history_for(place.scope_key, false) or nil
end

function M.back_places()
  local history = current_history()
  if not history then return {} end
  trim_invalid(history.back, "back", nil, "back-places")
  return { table.unpack(history.back) }
end

function M.forward_places()
  local history = current_history()
  if not history then return {} end
  trim_invalid(history.forward, "forward", nil, "forward-places")
  return { table.unpack(history.forward) }
end

function M.is_back_available()
  local history = current_history()
  if not history then return false end
  trim_invalid(history.back, "back", nil, "back-available")
  return #history.back > 0
end

function M.is_forward_available()
  local history = current_history()
  if not history then return false end
  trim_invalid(history.forward, "forward", nil, "forward-available")
  return #history.forward > 0
end

local function apply_place_to_view(view, place)
  debug_log("apply begin target=%s destination=%s", place_label(place), view_label(view))
  if place.scope_kind == "file-tree" and place.file_tree_current_dir
    and (not view.current_dir or not common.path_equals(view.current_dir, place.file_tree_current_dir))
  then
    local reveal_paths = {}
    for _, selection in ipairs(place.file_tree_selection_paths and place.file_tree_selection_paths.selections or {}) do
      reveal_paths[#reveal_paths + 1] = selection.line1_abs
      reveal_paths[#reveal_paths + 1] = selection.line2_abs
    end
    view.current_dir = place.file_tree_current_dir
    view:refresh(false, true, reveal_paths)
    debug_log("restored File Tree directory %s", tostring(place.file_tree_current_dir))
  end
  local restored_file_tree_selection = place.scope_kind == "file-tree"
    and place.file_tree_selection_paths
    and view.restore_selection_paths
    and view:restore_selection_paths(place.file_tree_selection_paths)
  if view.doc and place.line and place.col and not restored_file_tree_selection then
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
  end
  if view.scroll then
    view.scroll.to.x, view.scroll.x = place.scroll_x or 0, place.scroll_x or 0
    if not restored_file_tree_selection then
      view.scroll.to.y, view.scroll.y = place.scroll_y or 0, place.scroll_y or 0
    end
  end
  if place.line and place.col and not restored_file_tree_selection then
    if view.scroll_to_make_visible then
      view:scroll_to_make_visible(place.line, place.col)
    elseif view.scroll_to_line then
      view:scroll_to_line(place.line, true, true)
    end
  end
  debug_log("apply complete target=%s destination=%s restored_tree_selection=%s",
    place_label(place), view_label(view), tostring(not not restored_file_tree_selection))
end

local function restore_missing_view(place, doc)
  debug_log("restore missing view begin place=%s supplied_doc=%s doc_open=%s",
    place_label(place), tostring(doc), tostring(doc and doc_in_core_docs(doc)))
  if place.filename then
    debug_log("restore missing pane view opening file=%s pane=%s", tostring(place.filename), tostring(place.pane))
    doc = core.open_doc(place.filename)
  end
  if doc then
    local view = panes.open_doc(doc, { pane = place.pane or place.scope_key, focus = false })
    debug_log("restore missing pane view result place=%s view=%s doc=%s",
      place_label(place), view_label(view), tostring(doc))
    return view, doc
  end
  debug_log("restore missing view failed place=%s", place_label(place))
  return nil, doc
end

local function restore_command_output_place(place)
  local owner = place.scope_owner
  if not (owner and place.output_slot_index) then return nil end
  panes.show(place.pane or "right", { view = owner, focus = false })
  local view = owner:select_slot(place.output_slot_index, { focus = true })
  local slot = view and view.slot
  if view and output_entry_exists(slot, place.output_entry)
    and view.displayed_entry ~= place.output_entry
  then
    if place.output_entry then
      for index, entry in ipairs(slot.output_history or {}) do
        if entry == place.output_entry then slot.output_history_index = index; break end
      end
    end
    view:show_entry(place.output_entry)
  end
  return view
end

local function restore_git_anchor(owner, place, on_diff_ready)
  local tab = owner and owner.model_tab and owner:model_tab()
  if not tab then return end
  local resolved_line
  if place.git_commit_hash and tab.commits then
    for index, commit in ipairs(tab.commits) do
      if commit.hash == place.git_commit_hash then
        resolved_line = index
        if tab.kind == "log" and owner.model.select_log_index then
          owner.model:select_log_index(index, function() core.redraw = true end)
        elseif tab.kind == "file_history" then
          tab.selected_commit = index
          tab.selected_commit_hash = commit.hash
          if owner.model.load_selected_commit_changed_files then
            owner.model:load_selected_commit_changed_files(function() core.redraw = true end)
          end
        end
        break
      end
    end
  elseif place.git_file_path and tab.kind == "commit_diff" then
    for index, file in ipairs(tab.changed_files or {}) do
      local path = file.new_path or file.path or file.old_path
      if path == place.git_file_path then
        local selected = tab.changed_files and tab.changed_files[tab.selected_file or 1]
        local selected_path = selected and (selected.new_path or selected.path or selected.old_path)
        if place.git_diff_side and selected_path == path and not tab.loading_file
          and (tab.left_text ~= nil or tab.right_text ~= nil)
        then
          if owner.update_pane_docs then owner:update_pane_docs() end
          return nil, false
        end
        if place.git_diff_side and selected_path == path and tab.loading_file then
          core.add_thread(function()
            while tab.loading_file do coroutine.yield(0.03) end
            if on_diff_ready then on_diff_ready() end
          end)
          return nil, true
        end
        local callback_called = false
        owner.model:select_diff_file(tab, index, function()
          callback_called = true
          core.redraw = true
          if on_diff_ready then on_diff_ready() end
        end)
        if owner.update_pane_docs then owner:update_pane_docs() end
        local list = owner.pane_view and owner:pane_view("file-list")
        if not place.git_diff_side then
          resolved_line = list and list.git_file_index_to_line and list.git_file_index_to_line[index] or index
        elseif not callback_called then
          return nil, true
        end
        break
      end
    end
  end
  if owner.update_pane_docs then owner:update_pane_docs() end
  return resolved_line, false
end

local function focus_git_place(owner, place)
  local node = core.root_panel.root_node:get_node_for_view(owner)
  if node then node:set_active_view(owner) end

  if place.git_pane and owner.focus_pane_view then
    owner:focus_pane_view(place.git_pane)
  elseif place.git_diff_side and owner.focus_diff_pane then
    owner:focus_diff_pane(place.git_diff_side)
  else
    local focus = owner.get_focus_view and owner:get_focus_view() or owner
    core.set_active_view(focus or owner)
  end
  local view = core.active_view
  if view == owner or view and view.git_owner_view == owner then return view end
end

local function complete_deferred_git_restore(owner, place)
  local invalid_reason = place_invalid_reason(place)
  if invalid_reason then
    debug_log("discard deferred Git restore invalid_reason=%s place=%s", invalid_reason, place_label(place))
    return
  end
  debug_log("deferred Git restore begin owner=%s place=%s", view_label(owner), place_label(place))
  local previous_restoring = restoring
  restoring = true
  local ok, err = xpcall(function()
    if owner.update_pane_docs then owner:update_pane_docs() end
    local view = focus_git_place(owner, place)
    if not view or view == owner then error("could not restore deferred Git diff pane") end
    apply_place_to_view(view, place)
    core.set_active_view(view)
  end, debug.traceback)
  restoring = previous_restoring
  if not ok then
    debug_log("deferred Git restore failed place=%s error=%s", place_label(place), tostring(err))
    core.error("Failed to finish restoring Git navigation place: %s", tostring(err))
  else
    debug_log("deferred Git restore complete active=%s place=%s", view_label(core.active_view), place_label(place))
  end
end

local function restore_git_place(place)
  local owner = place.git_owner
  if not owner then return nil end
  if owner.activate_model_tab then owner:activate_model_tab(function() core.redraw = true end) end
  local restore_returned = false
  local callback_called = false
  local function on_diff_ready()
    callback_called = true
    if restore_returned then complete_deferred_git_restore(owner, place) end
  end
  local resolved_line, pending = restore_git_anchor(owner, place, place.git_diff_side and on_diff_ready or nil)
  restore_returned = true
  if pending and not callback_called then
    local node = core.root_panel.root_node:get_node_for_view(owner)
    if node then node:set_active_view(owner) end
    return owner, nil, true
  end
  local view = focus_git_place(owner, place)
  return view, resolved_line, false
end

function M.restore_place(place)
  debug_log("restore request restoring=%s suppress_count=%d active=%s place=%s",
    tostring(restoring), suppress_count, view_label(core.active_view), place_label(place))
  local invalid_reason = place_invalid_reason(place)
  if invalid_reason then
    main_debug_log("restore rejected invalid_reason=%s place=%s", invalid_reason, place_label(place))
    return false
  end

  restoring = true
  local ok, err = xpcall(function()
    local doc = place.doc
    local view = place.view
    local resolved_git_line
    local deferred_git_restore = false
    if place.scope_kind == "command-output" then
      debug_log("restore route=command-output place=%s", place_label(place))
      view = restore_command_output_place(place)
    elseif place.scope_kind == "git" then
      debug_log("restore route=git place=%s", place_label(place))
      view, resolved_git_line, deferred_git_restore = restore_git_place(place)
    else
      if view and (not view_is_open(view) or view.doc ~= doc) then
        debug_log("restore discarding stale view=%s expected_doc=%s place=%s",
          view_label(view), tostring(doc), place_label(place))
        view = nil
      end
      if not view then
        debug_log("restore route=rebuild-missing-view place=%s", place_label(place))
        view, doc = restore_missing_view(place, doc)
      else
        local node = core.root_panel.root_node:get_node_for_view(view)
        debug_log("restore route=existing-pane-view node=%s view=%s", tostring(node), view_label(view))
        if node then
          node:set_active_view(view)
          panes.show(place.pane or place.scope_key, { view = view, focus = false })
        end
      end
    end
    if not view then error("could not open navigation target") end
    if deferred_git_restore then
      debug_log("restore deferred Git completion owner=%s place=%s", view_label(view), place_label(place))
      return
    end
    local applied_place = place
    if resolved_git_line then
      applied_place = {}
      for key, value in pairs(place) do applied_place[key] = value end
      applied_place.line = resolved_git_line
      applied_place.line2 = resolved_git_line
      applied_place.selection_state = nil
    end
    apply_place_to_view(view, applied_place)
    core.set_active_view(view)
  end, debug.traceback)
  restoring = false

  if not ok then
    debug_log("restore failed active=%s place=%s error=%s", view_label(core.active_view), place_label(place), tostring(err))
    core.error("Failed to restore navigation place: %s", tostring(err))
    return false
  end
  debug_log("restore complete active=%s place=%s", view_label(core.active_view), place_label(place))
  return true
end

local function pop_target(stack, current, stack_name, reason)
  while #stack > 0 do
    local target = table.remove(stack)
    local invalid_reason = place_invalid_reason(target)
    local same_as_current = exact_place_matches(current, target)
    debug_log("pop candidate stack=%s reason=%s invalid_reason=%s same_as_current=%s current=%s candidate=%s",
      tostring(stack_name), tostring(reason), tostring(invalid_reason), tostring(same_as_current),
      place_label(current), place_label(target))
    if not invalid_reason and not same_as_current then return target end
  end
end

function M.go_back()
  main_debug_log("back request active=%s suppress_count=%d restoring=%s", view_label(core.active_view), suppress_count, tostring(restoring))
  trim_all_histories("go-back")
  local current = M.capture_current_place()
  if not current then
    main_debug_log("back rejected reason=no-current-place active=%s", view_label(core.active_view))
    return false
  end
  local history = history_for(current.scope_key, false)
  if not history then
    main_debug_log("back rejected reason=no-history current=%s", place_label(current))
    return false
  end
  trim_invalid(history.back, "back", current.scope_key, "go-back")
  dump_history(current.scope_key, history, "before-back")
  local target = pop_target(history.back, current, "back", "go-back")
  if not target then
    main_debug_log("back rejected reason=no-target current=%s", place_label(current))
    dump_history(current.scope_key, history, "after-empty-back")
    return false
  end
  push_place(history.forward, current, "forward", "go-back-current")
  main_debug_log("back restoring scope=%s from=%s to=%s", tostring(target.scope_kind), place_label(current), place_label(target))
  dump_history(current.scope_key, history, "before-back-restore")
  local restored = M.restore_place(target)
  main_debug_log("back complete restored=%s active=%s target=%s", tostring(restored), view_label(core.active_view), place_label(target))
  dump_history(current.scope_key, history, "after-back")
  flush_debug_log()
  return restored
end

function M.go_forward()
  main_debug_log("forward request active=%s suppress_count=%d restoring=%s", view_label(core.active_view), suppress_count, tostring(restoring))
  trim_all_histories("go-forward")
  local current = M.capture_current_place()
  if not current then
    main_debug_log("forward rejected reason=no-current-place active=%s", view_label(core.active_view))
    return false
  end
  local history = history_for(current.scope_key, false)
  if not history then
    main_debug_log("forward rejected reason=no-history current=%s", place_label(current))
    return false
  end
  trim_invalid(history.forward, "forward", current.scope_key, "go-forward")
  dump_history(current.scope_key, history, "before-forward")
  local target = pop_target(history.forward, current, "forward", "go-forward")
  if not target then
    main_debug_log("forward rejected reason=no-target current=%s", place_label(current))
    dump_history(current.scope_key, history, "after-empty-forward")
    return false
  end
  push_place(history.back, current, "back", "go-forward-current")
  main_debug_log("forward restoring scope=%s from=%s to=%s", tostring(target.scope_kind), place_label(current), place_label(target))
  dump_history(current.scope_key, history, "before-forward-restore")
  local restored = M.restore_place(target)
  main_debug_log("forward complete restored=%s active=%s target=%s", tostring(restored), view_label(core.active_view), place_label(target))
  dump_history(current.scope_key, history, "after-forward")
  flush_debug_log()
  return restored
end

function M.suppress_recording(fn, ...)
  suppress_count = suppress_count + 1
  debug_log("suppression begin depth=%d function=%s", suppress_count, tostring(fn))
  local args = { n = select("#", ...), ... }
  local ok, result = xpcall(function()
    return { n = 1, fn(table.unpack(args, 1, args.n)) }
  end, debug.traceback)
  suppress_count = suppress_count - 1
  debug_log("suppression end depth=%d ok=%s", suppress_count, tostring(ok))
  if not ok then error(result, 0) end
  return table.unpack(result, 1, result.n)
end

function M.track_command(name, enabled)
  tracked_commands[name] = enabled ~= false or nil
  debug_log("tracked command changed name=%s enabled=%s", tostring(name), tostring(tracked_commands[name] == true))
end

local function record_transition(before, after, reason)
  debug_log("transition observed reason=%s suppress_count=%d restoring=%s before=%s after=%s",
    tostring(reason), suppress_count, tostring(restoring), place_label(before), place_label(after))
  if suppress_count > 0 or restoring then
    debug_log("transition ignored reason=%s gate=%s", tostring(reason), suppress_count > 0 and "suppressed" or "restoring")
    return
  end
  trim_all_histories("transition:" .. tostring(reason))
  if not before then
    debug_log("transition ignored reason=%s decision=missing-before after=%s", tostring(reason), place_label(after))
    return
  end
  if not after then
    debug_log("transition ignored reason=%s decision=missing-after before=%s", tostring(reason), place_label(before))
    return
  end
  local scope_changed = before.scope_key ~= after.scope_key
  local significant = significant_place_change(before, after)
  if not scope_changed and not significant then
    debug_log("transition ignored reason=%s decision=not-significant before=%s after=%s",
      tostring(reason), place_label(before), place_label(after))
    return
  end
  debug_log("transition recording reason=%s scope_changed=%s significant=%s before=%s after=%s",
    tostring(reason), tostring(scope_changed), tostring(significant), place_label(before), place_label(after))
  local history = core.navigation_history or M
  local recorded = history.record_place(before, { reason = reason })
  debug_log("transition record result reason=%s recorded=%s", tostring(reason), tostring(recorded))
end

local function install_focus_tracking()
  local wrapped = core.set_active_view
  if wrapped == core.navigation_history_set_active_view_wrapper then
    wrapped = core.navigation_history_wrapped_set_active_view or wrapped
  end
  core.navigation_history_wrapped_set_active_view = wrapped

  local wrapper = function(view)
    local history = core.navigation_history or M
    debug_log("focus wrapper begin requested=%s active_before=%s", view_label(view), view_label(core.active_view))
    local before = history.capture_current_place()
    local result = wrapped(view)
    local after = history.capture_current_place()
    debug_log("focus wrapper end requested=%s result=%s active_after=%s before=%s after=%s",
      view_label(view), tostring(result), view_label(core.active_view), place_label(before), place_label(after))
    record_transition(before, after, "focus")
    return result
  end
  core.navigation_history_set_active_view_wrapper = wrapper
  core.set_active_view = wrapper
  debug_log("installed core.set_active_view tracking wrapper wrapped=%s wrapper=%s", tostring(wrapped), tostring(wrapper))
end

local function install_node_tracking()
  local wrapped = Node.set_active_view
  if wrapped == core.navigation_history_node_set_active_view_wrapper then
    wrapped = core.navigation_history_wrapped_node_set_active_view or wrapped
  end
  core.navigation_history_wrapped_node_set_active_view = wrapped

  local wrapper = function(self, view)
    local history = core.navigation_history or M
    debug_log("node wrapper begin node=%s requested=%s node_active_before=%s core_active_before=%s",
      tostring(self), view_label(view), view_label(self and self.active_view), view_label(core.active_view))
    local before = history.capture_current_place()
    local result = wrapped(self, view)
    local after = history.capture_current_place()
    debug_log("node wrapper end node=%s requested=%s result=%s node_active_after=%s core_active_after=%s before=%s after=%s",
      tostring(self), view_label(view), tostring(result), view_label(self and self.active_view),
      view_label(core.active_view), place_label(before), place_label(after))
    record_transition(before, after, "view-selection")
    return result
  end
  core.navigation_history_node_set_active_view_wrapper = wrapper
  Node.set_active_view = wrapper
  debug_log("installed Node.set_active_view tracking wrapper wrapped=%s wrapper=%s", tostring(wrapped), tostring(wrapper))
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
      debug_log("tracked command begin name=%s active=%s", tostring(name), view_label(core.active_view))
      local before = history.capture_current_place()
      local result = wrapped(name, ...)
      local after = history.capture_current_place()
      debug_log("tracked command end name=%s result=%s active=%s before=%s after=%s",
        tostring(name), tostring(result), view_label(core.active_view), place_label(before), place_label(after))
      if result then record_transition(before, after, "command:" .. tostring(name)) end
      return result
    end
    if tracked_commands[name] then
      debug_log("tracked command bypass name=%s suppress_count=%d restoring=%s active=%s",
        tostring(name), suppress_count, tostring(restoring), view_label(core.active_view))
    end
    return wrapped(name, ...)
  end
  core.navigation_history_command_perform_wrapper = wrapper
  command.perform = wrapper
  debug_log("installed command.perform tracking wrapper wrapped=%s wrapper=%s", tostring(wrapped), tostring(wrapper))
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
M.flush_debug_log = flush_debug_log

install_focus_tracking()
install_node_tracking()
install_command_tracking()

return M
