-- mod-version:3
-- IntelliJ-style scoped navigation history.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local config = require "core.config"
local file_context = require "core.file_context"
local Node = require "core.node"
local sidepanel = require "core.sidepanel"

local M = {}

local histories = {}
local EDITOR_SCOPE = "editors"
local FILE_TREE_SCOPE = "file-tree"
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
  if view.__sidepanel_placeholder then return true end
  if view.local_find_input then return true end
  if fuzzy_searcher_owns_view(view) then return true end
  return false
end

local function command_output_owner(view)
  if not view then return nil end
  if view.command_output_panel then return view end
  local owner = view.__sidepanel_focus_owner
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

  local owner = git_owner(view)
  if owner then
    return {
      key = owner.tool_window or owner.model,
      kind = "git",
      owner = owner,
    }
  end

  owner = command_output_owner(view)
  if owner then return { key = owner, kind = "command-output", owner = owner } end

  if view.navigation_scope_kind == "file-tree" then
    return { key = FILE_TREE_SCOPE, kind = "file-tree", owner = view }
  end

  if file_context.is_editor_view(view) or (view.doc and view.doc.git_historical_read_only) then
    return { key = EDITOR_SCOPE, kind = "editor", owner = view }
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

local function place_label(place)
  if not place then return "<nil>" end
  return string.format("%s:%s:%s", tostring(place.filename or place.doc), tostring(place.line), tostring(place.col))
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
  if not scope or not scope_owner_is_open(scope) then return nil end
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
  local is_side_view = sidepanel.is_side_view(view)
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
    view = view,
    doc = doc,
    filename = path and common.normalize_path(path) or nil,
    side_view = is_side_view,
    side_file = is_side_view and view == sidepanel.file_view,
    side_editor = is_side_view and sidepanel.is_side_editor(view),
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

local function place_valid(place)
  if not place then return false end
  if place.scope_kind == "command-output" then
    local owner = place.scope_owner
    if not (owner and owner.command_output_panel and view_is_open(owner)) then return false end
    if not place.output_slot_index then return false end
    local view = owner.views and owner.views[place.output_slot_index]
    return view == place.view
      and view.__sidepanel_focus_owner == owner
      and output_entry_exists(view.slot, place.output_entry)
  end
  if place.scope_kind == "git" then
    local owner = place.git_owner
    if not (owner and view_is_open(owner) and owner.model and owner.model.find_tab) then return false end
    local tab = owner.model:find_tab(place.git_tab_id)
    if not tab then return false end
    if place.git_commit_hash then
      for _, commit in ipairs(tab.commits or {}) do
        if commit.hash == place.git_commit_hash then return true end
      end
      return false
    end
    if place.git_file_path then
      for _, file in ipairs(tab.changed_files or {}) do
        if (file.new_path or file.path or file.old_path) == place.git_file_path then return true end
      end
      return false
    end
    return true
  end
  if place.scope_kind == "file-tree" and place.file_tree_current_dir then
    local info = system.get_file_info(place.file_tree_current_dir)
    if not (info and info.type == "dir") then return false end
  end
  if place.view and view_is_open(place.view) then return place.doc == nil or place.view.doc == place.doc end
  -- A removed side tool cannot be recreated as its original view type. Side
  -- Editors and the replaceable side file view can be rebuilt from a Document
  -- or path while preserving their side location.
  if place.side_view and not (place.side_file or place.side_editor) then return false end
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

local function trim_all_histories()
  for scope_key, history in pairs(histories) do
    trim_invalid(history.back)
    trim_invalid(history.forward)
    if #history.back == 0 and #history.forward == 0 then histories[scope_key] = nil end
  end
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

  trim_all_histories()
  local history = history_for(place.scope_key, true)
  local recorded = push_place(history.back, place)
  if recorded and opts.clear_forward ~= false then history.forward = {} end
  if recorded then
    debug_log("record scope=%s place=%s reason=%s", tostring(place.scope_kind), place_label(place), tostring(opts.reason or "manual"))
  end
  return recorded
end

function M.record_current_place(reason)
  return M.record_place(M.capture_current_place(), {
    reason = reason,
    check_current = false,
  })
end

function M.clear_history()
  histories = {}
end

local function current_history()
  trim_all_histories()
  local place = M.capture_current_place()
  return place and history_for(place.scope_key, false) or nil
end

function M.back_places()
  local history = current_history()
  if not history then return {} end
  trim_invalid(history.back)
  return { table.unpack(history.back) }
end

function M.forward_places()
  local history = current_history()
  if not history then return {} end
  trim_invalid(history.forward)
  return { table.unpack(history.forward) }
end

function M.is_back_available()
  local history = current_history()
  if not history then return false end
  trim_invalid(history.back)
  return #history.back > 0
end

function M.is_forward_available()
  local history = current_history()
  if not history then return false end
  trim_invalid(history.forward)
  return #history.forward > 0
end

local function apply_place_to_view(view, place)
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
end

local function restore_missing_view(place, doc)
  if place.side_view and (place.side_file or place.side_editor) then
    local side_panel_was_visible = sidepanel.visible
    local view

    if place.filename and not (doc and doc_in_core_docs(doc)) then
      if place.doc then
        doc = core.open_doc(place.filename)
      else
        view = sidepanel.open_path_in_side(place.filename, { focus = false })
      end
    end
    if not view and doc then
      view = sidepanel.open_doc_in_side(doc, { focus = false })
    end

    if view then
      if side_panel_was_visible then
        sidepanel.show(view, { focus = false })
      else
        sidepanel.make_view_visible(view)
      end
      debug_log("rebuilt side navigation target %s", place_label(place))
    end
    return view, doc
  end

  if place.filename then doc = core.open_doc(place.filename) end
  if doc then return core.root_panel:open_doc(doc), doc end
  return nil, doc
end

local function restore_command_output_place(place)
  local owner = place.scope_owner
  if not (owner and place.output_slot_index) then return nil end
  sidepanel.show(owner, { focus = false })
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
  if not place_valid(place) then
    debug_log("discard deferred Git restore for invalid place %s", place_label(place))
    return
  end
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
  if not ok then core.error("Failed to finish restoring Git navigation place: %s", tostring(err)) end
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
  if not place_valid(place) then return false end

  restoring = true
  local ok, err = xpcall(function()
    local doc = place.doc
    local view = place.view
    local resolved_git_line
    local deferred_git_restore = false
    if place.scope_kind == "command-output" then
      view = restore_command_output_place(place)
    elseif place.scope_kind == "git" then
      view, resolved_git_line, deferred_git_restore = restore_git_place(place)
    else
      if view and (not view_is_open(view) or view.doc ~= doc) then view = nil end
      if not view then
        view, doc = restore_missing_view(place, doc)
      elseif sidepanel.is_side_view(view) then
      -- Restoring a side target selects it, but presentation remains current:
      -- an existing Side Editor Slot stays a slot, while tools that have no
      -- slot presentation show the Side Panel.
        sidepanel.make_view_visible(view)
      else
        local node = core.root_panel.root_node:get_node_for_view(view)
        if node then node:set_active_view(view) end
      end
    end
    if not view then error("could not open navigation target") end
    if deferred_git_restore then return end
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
  trim_all_histories()
  local current = M.capture_current_place()
  if not current then return false end
  local history = history_for(current.scope_key, false)
  if not history then return false end
  trim_invalid(history.back)
  local target = pop_target(history.back, current)
  if not target then return false end
  push_place(history.forward, current)
  debug_log("back scope=%s to %s", tostring(target.scope_kind), place_label(target))
  return M.restore_place(target)
end

function M.go_forward()
  trim_all_histories()
  local current = M.capture_current_place()
  if not current then return false end
  local history = history_for(current.scope_key, false)
  if not history then return false end
  trim_invalid(history.forward)
  local target = pop_target(history.forward, current)
  if not target then return false end
  push_place(history.back, current)
  debug_log("forward scope=%s to %s", tostring(target.scope_kind), place_label(target))
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

local function record_transition(before, after, reason)
  if suppress_count > 0 or restoring then return end
  trim_all_histories()
  if before and after
    and (before.scope_key ~= after.scope_key or significant_place_change(before, after))
  then
    local history = core.navigation_history or M
    history.record_place(before, { reason = reason })
  end
end

local function install_focus_tracking()
  local wrapped = core.set_active_view
  if wrapped == core.navigation_history_set_active_view_wrapper then
    wrapped = core.navigation_history_wrapped_set_active_view or wrapped
  end
  core.navigation_history_wrapped_set_active_view = wrapped

  local wrapper = function(view)
    local history = core.navigation_history or M
    local before = history.capture_current_place()
    local result = wrapped(view)
    local after = history.capture_current_place()
    record_transition(before, after, "focus")
    return result
  end
  core.navigation_history_set_active_view_wrapper = wrapper
  core.set_active_view = wrapper
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
    record_transition(before, after, "view-selection")
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
      if result then record_transition(before, after, "command:" .. tostring(name)) end
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

install_focus_tracking()
install_node_tracking()
install_command_tracking()

return M
