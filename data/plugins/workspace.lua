-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local storage = require "core.storage"
local project_paths = require "core.project_paths"
local language_mode = require "core.language_mode"
local panes = require "core.panes"
local untitled_recovery = require "plugins.untitled_recovery"

local STORAGE_MODULE = "ws"

local function invalid_workspace_filename(filename)
  return type(filename) == "string" and filename:find("[%z\1-\31]") ~= nil
end

local function view_has_invalid_named_file(view)
  local buffer = view and view.buffer
  return buffer
     and not buffer.intellij_untitled
     and (invalid_workspace_filename(buffer.filename) or invalid_workspace_filename(buffer.abs_filename))
end

local function close_unattached_view_buffer(view)
  local buffer = view and view.buffer
  if not buffer then return end
  for _, open_buffer in ipairs(core.buffers or {}) do
    if open_buffer == buffer then
      if #core.get_views_referencing_buffer(buffer) == 0 then
        if core.buffer_registry then core.buffer_registry:remove(buffer, true) end
      end
      return
    end
  end
end

local loaded_workspace_key
local loaded_workspace_path
local suppress_next_exit_workspace_save = false

local function workspace_key_matches_basename(key, basename)
  local prefix = key:sub(1, #basename)
  if PATHSEP == "\\" then
    return prefix:lower() == basename:lower()
  end
  return prefix == basename
end


local function workspace_key_id(key, basename)
  if not workspace_key_matches_basename(key, basename) then return nil end
  return tonumber(key:sub(#basename + 1):match("^-(%d+)$"))
end


local function workspace_key_entries_for(project_dir)
  local basename = common.basename(project_dir)
  local entries = {}
  for _, key in ipairs(storage.keys(STORAGE_MODULE) or {}) do
    local id = workspace_key_id(key, basename)
    if id then
      entries[#entries + 1] = { key = key, id = id }
    end
  end
  table.sort(entries, function(a, b) return a.id < b.id end)
  return entries
end


local function count_saved_views(node)
  if type(node) ~= "table" then return 0 end
  return type(node.panes) == "table" and #node.panes or 0
end


local function matching_workspace_entries(project_dir)
  local entries = {}
  for _, entry in ipairs(workspace_key_entries_for(project_dir)) do
    local workspace = storage.load(STORAGE_MODULE, entry.key)
    if type(workspace) == "table" and common.path_equals(workspace.path, project_dir) then
      entry.workspace = workspace
      entry.saved_view_count = count_saved_views(workspace.pane_state)
      entries[#entries + 1] = entry
    end
  end
  table.sort(entries, function(a, b)
    local a_nonempty = a.saved_view_count > 0
    local b_nonempty = b.saved_view_count > 0
    if a_nonempty ~= b_nonempty then return a_nonempty end
    if a.saved_view_count ~= b.saved_view_count then
      return a.saved_view_count > b.saved_view_count
    end
    return a.id < b.id
  end)
  return entries
end


local function clear_duplicate_workspace_entries(entries, keep_key)
  for _, entry in ipairs(entries) do
    if entry.key ~= keep_key then
      storage.clear(STORAGE_MODULE, entry.key)
      if core.log_quiet then
        core.log_quiet(
          "Workspace: removed duplicate state %s for %s",
          entry.key,
          tostring(entry.workspace and entry.workspace.path)
        )
      end
    end
  end
end


local function allocate_workspace_key(project_dir)
  local basename = common.basename(project_dir)
  local used_ids = {}
  for _, entry in ipairs(workspace_key_entries_for(project_dir)) do
    used_ids[entry.id] = true
  end
  local id = 1
  while used_ids[id] do
    id = id + 1
  end
  return basename .. "-" .. id
end


local function loaded_key_for(project_dir)
  if loaded_workspace_key
  and loaded_workspace_path
  and common.path_equals(loaded_workspace_path, project_dir) then
    return loaded_workspace_key
  end
end


local function consume_workspace(project_dir)
  local entries = matching_workspace_entries(project_dir)
  if #entries == 0 then
    loaded_workspace_key = nil
    loaded_workspace_path = nil
    return nil
  end

  local chosen = entries[1]
  -- Keep the chosen workspace file durable. Local Project Paths are stored in
  -- workspace state; deleting the restored file makes them depend on a later
  -- clean exit/save and loses them after restart/crash. Only remove duplicate
  -- workspace slots for the same project.
  clear_duplicate_workspace_entries(entries, chosen.key)
  loaded_workspace_key = chosen.key
  loaded_workspace_path = chosen.workspace.path or project_dir
  if core.log_quiet then
    core.log_quiet(
      "Workspace: restored %s for %s with %d view(s), consumed %d duplicate(s)",
      chosen.key,
      tostring(chosen.workspace.path),
      chosen.saved_view_count,
      math.max(0, #entries - 1)
    )
  end
  return chosen.workspace
end


---@param view core.view
local function save_view(view)
  local state = view:get_state()
  local module = view:get_module()
  if state and invalid_workspace_filename(state.filename) then
    if core.log_quiet then core.log_quiet("Workspace: skipped view with invalid filename %q", state.filename) end
    return nil
  end
  if view_has_invalid_named_file(view) then
    if core.log_quiet then core.log_quiet("Workspace: skipped view with invalid buffer filename %q", view.buffer.filename or view.buffer.abs_filename) end
    return nil
  end
  if state and state.filename and view.buffer and view.buffer.new_file and not view.buffer.intellij_untitled then
    if core.log_quiet then core.log_quiet("Workspace: skipped missing named file view %q", state.filename) end
    return nil
  end
  if state and module then
    return {
      module = module,
      active = (core.active_view == view),
      state = state,
    }
  end
end


local function load_view(t)
  t.module = t.module or (t.type == "buffer" and "core.editor")
  if t.module then
    local View = require(t.module)
    -- compatibility with old state data
    if t.scroll then
      t.state = {
        scroll = t.scroll,
        filename = t.filename,
        selection = t.selection,
        crlf = t.crlf,
        text = t.text
      }
    end
    if t.state and invalid_workspace_filename(t.state.filename) then
      if core.log_quiet then core.log_quiet("Workspace: skipped invalid filename from saved state %q", t.state.filename) end
      return nil
    end
    local view = View and View.from_state(t.state)
    if view_has_invalid_named_file(view) then
      if core.log_quiet then core.log_quiet("Workspace: dropped invalid named file restored from saved state %q", view.buffer.filename or view.buffer.abs_filename) end
      close_unattached_view_buffer(view)
      return nil
    end
    if view and view.buffer and view.buffer.filename and view.buffer.new_file and not view.buffer.intellij_untitled then
      if core.log_quiet then core.log_quiet("Workspace: skipped missing named file from saved state %q", view.buffer.filename) end
      close_unattached_view_buffer(view)
      return nil
    end
    return view
  end
end


local function refresh_project_path_consumers(reason)
  local ok, filetree = pcall(require, "plugins.filetree")
  if ok and filetree and filetree.refresh_preserving_selection_paths then
    filetree:refresh_preserving_selection_paths(true)
    if core.log_quiet then
      core.log_quiet("Workspace: refreshed File Tree after Project Path state change (%s)", tostring(reason or "workspace"))
    end
  end
end

function core.refresh_project_path_consumers(reason)
  return refresh_project_path_consumers(reason)
end

local function sync_workspace_project_paths_to_core_projects()
  local root_project = core.root_project()
  local root_path = root_project and root_project.path
  for _, entry in ipairs(project_paths.entries({ include_root = false })) do
    if entry.source == "workspace"
    and root_path
    and not common.path_equals(entry.path, root_path)
    and not common.path_belongs_to(entry.path, root_path) then
      core.add_project(entry.path)
    end
  end
end

local function ensure_initial_filetree_pane()
  if panes.count() > 0 then return false end
  local ok, filetree = pcall(require, "plugins.filetree")
  if not ok or not filetree or not filetree.open then
    core.log_quiet("Workspace: initial File Tree is unavailable: %s", tostring(filetree))
    return false
  end
  local view, err = filetree.open(nil, {
    placement = "new",
    focus = true,
    reason = "initial-project",
  })
  if not view then
    core.log_quiet("Workspace: initial File Tree failed: %s", tostring(err))
    return false
  end
  core.log_quiet("Workspace: opened initial File Tree Pane for empty Project state")
  return true
end


local function save_workspace()
  local project = core.root_project and core.root_project()
  if not (project and project.path) then return end

  local project_dir = project.path
  local key = loaded_key_for(project_dir)
  local entries = matching_workspace_entries(project_dir)
  if not key then
    key = entries[1] and entries[1].key or allocate_workspace_key(project_dir)
  end
  clear_duplicate_workspace_entries(entries, key)

  untitled_recovery.flush_all("workspace save", true)
  local pane_state = panes.save_workspace_state(save_view)
  storage.save(STORAGE_MODULE, key, {
    version = 1,
    path = project_dir,
    pane_state = pane_state,
    project_paths = project_paths.save_workspace_state(),
    language_modes = language_mode.save_workspace_state(),
    visited_files = core.prune_visited_files and core.prune_visited_files() or core.visited_files,
  })
  loaded_workspace_key = key
  loaded_workspace_path = project_dir
  if core.log_quiet then
    core.log_quiet(
      "Workspace: saved %s for %s with %d view(s)",
      key,
      project_dir,
      count_saved_views(pane_state)
    )
  end
end


function core.save_workspace()
  return save_workspace()
end

local function load_workspace()
  core.add_thread(function()
    local function restore_workspace_state()
      local workspace = consume_workspace(core.root_project().path)
      language_mode.load_workspace_state(workspace and workspace.language_modes)
      local _, project_paths_changed = project_paths.load_workspace_state(
        workspace and workspace.project_paths,
        workspace and workspace.directories
      )
      if project_paths_changed then
        refresh_project_path_consumers("workspace load")
      elseif core.log_quiet then
        core.log_quiet("Workspace: skipped unchanged Project Path consumer refresh")
      end
      if workspace then
        if workspace.visited_files then
          core.visited_files = workspace.visited_files
          local legacy_recent_files = type(core.visited_files[1]) == "string"
          if core.prune_visited_files then core.prune_visited_files() end
          if legacy_recent_files then
            core.log_quiet("Workspace: migrated path-only Recent Files to view/edit metadata")
          end
        end
        panes.restore_workspace_state(workspace.pane_state, load_view)
        sync_workspace_project_paths_to_core_projects()
      end
      untitled_recovery.restore_project(core.root_project().path)
      ensure_initial_filetree_pane()
    end

    restore_workspace_state()
  end)
end


if not core.__workspace_hooks_installed then
  core.__workspace_hooks_installed = true

  local set_project = core.set_project
  function core.set_project(project)
    core.try(save_workspace)
    project = set_project(project)
    core.try(load_workspace)
    return project
  end

  local open_project_in_same_window = core.open_project_in_same_window
  function core.open_project_in_same_window(project, ...)
    untitled_recovery.flush_all("same-window project switch", true)
    suppress_next_exit_workspace_save = true
    local result = table.pack(pcall(open_project_in_same_window, project, ...))
    if not result[1] then
      suppress_next_exit_workspace_save = false
      error(result[2], 0)
    end
    if suppress_next_exit_workspace_save then
      suppress_next_exit_workspace_save = false
    end
    return table.unpack(result, 2, result.n)
  end

  local exit = core.exit
  function core.exit(quit_fn, force)
    if force then
      if suppress_next_exit_workspace_save then
        suppress_next_exit_workspace_save = false
        if core.log_quiet then
          core.log_quiet(
            "Workspace: skipped forced-exit save for %s during same-window project switch",
            tostring(core.root_project() and core.root_project().path)
          )
        end
      else
        core.try(save_workspace)
      end
    end
    exit(quit_fn, force)
  end
end

local run = core.run
function core.run(...)
  if #core.buffers == 0 then core.try(load_workspace) end
  core.run = run
  return core.run(...)
end
