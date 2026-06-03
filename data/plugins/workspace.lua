-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local storage = require "core.storage"

local STORAGE_MODULE = "ws"

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
  if node.type == "leaf" then
    return type(node.views) == "table" and #node.views or 0
  end
  return count_saved_views(node.a) + count_saved_views(node.b)
end


local function matching_workspace_entries(project_dir)
  local entries = {}
  for _, entry in ipairs(workspace_key_entries_for(project_dir)) do
    local workspace = storage.load(STORAGE_MODULE, entry.key)
    if type(workspace) == "table" and common.path_equals(workspace.path, project_dir) then
      entry.workspace = workspace
      entry.saved_view_count = count_saved_views(workspace.documents)
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
  -- Preserve the original consume semantics: once state is restored, remove it
  -- from disk so repeated load hooks in the same run cannot duplicate tabs.
  for _, entry in ipairs(entries) do
    storage.clear(STORAGE_MODULE, entry.key)
  end
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


local function has_no_locked_children(node)
  if node.locked then return false end
  if node.type == "leaf" then return true end
  return has_no_locked_children(node.a) and has_no_locked_children(node.b)
end


local function get_unlocked_root(node)
  if node.type == "leaf" then
    return not node.locked and node
  end
  if has_no_locked_children(node) then
    return node
  end
  return get_unlocked_root(node.a) or get_unlocked_root(node.b)
end


---@param view core.view
local function save_view(view)
  local state = view:get_state()
  local module = view:get_module()
  if state and module then
    return {
      module = module,
      active = (core.active_view == view),
      state = state,
    }
  end
end


local function load_view(t)
  t.module = t.module or (t.type == "doc" and "core.docview")
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
    return View and View.from_state(t.state)
  end
end


local function save_node(node)
  local res = {}
  res.type = node.type
  if node.type == "leaf" then
    res.views = {}
    for _, view in ipairs(node.views) do
      local t = save_view(view)
      if t then
        table.insert(res.views, t)
        if node.active_view == view then
          res.active_view = #res.views
        end
      end
    end
  else
    res.divider = node.divider
    res.a = save_node(node.a)
    res.b = save_node(node.b)
  end
  return res
end


local function load_node(node, t)
  if t.type == "leaf" then
    local res
    local active_view
    for i, v in ipairs(t.views) do
      local view = load_view(v)
      if view then
        if v.active then res = view end
        node:add_view(view)
        if t.active_view == i then
          active_view = view
        end
      end
    end
    if active_view then
      node:set_active_view(active_view)
    end
    return res
  else
    node:split(t.type == "hsplit" and "right" or "down")
    node.divider = t.divider
    local res1 = load_node(node.a, t.a)
    local res2 = load_node(node.b, t.b)
    return res1 or res2
  end
end


local function save_directories()
  local project_dir = core.root_project().path
  local dir_list = {}
  for i = 2, #core.projects do
    dir_list[#dir_list + 1] = common.relative_path(project_dir, core.projects[i].path)
  end
  return dir_list
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

  local root = get_unlocked_root(core.root_panel.root_node)
  local documents = save_node(root)
  storage.save(STORAGE_MODULE, key, {
    path = project_dir,
    documents = documents,
    directories = save_directories(),
    visited_files = core.visited_files
  })
  loaded_workspace_key = key
  loaded_workspace_path = project_dir
  if core.log_quiet then
    core.log_quiet(
      "Workspace: saved %s for %s with %d view(s)",
      key,
      project_dir,
      count_saved_views(documents)
    )
  end
end


local function main_panel_workspace_is_empty()
  local main_panel = core.root_panel and core.root_panel:get_main_panel()
  return main_panel and main_panel:is_empty() and #core.docs == 0
end

local function maybe_show_empty_project_file_tree()
  -- Let workspace restoration, command-line file opening, and autosave recovery
  -- settle first. If the user focuses anything during this grace period (for
  -- example the fuzzy searcher), do not steal focus back to the file tree.
  local initial_active_view = core.active_view
  coroutine.yield()
  coroutine.yield()
  if core.active_view == initial_active_view
  and main_panel_workspace_is_empty()
  and command.is_valid("filetree:focus-and-show") then
    command.perform("filetree:focus-and-show")
  end
end

local function load_workspace()
  core.add_thread(function()
    local workspace = consume_workspace(core.root_project().path)
    if workspace then
      if workspace.visited_files then
        core.visited_files = workspace.visited_files
      end
      local root = get_unlocked_root(core.root_panel.root_node)
      local active_view = load_node(root, workspace.documents)
      if active_view then
        core.set_active_view(active_view)
      end
      for _, dir_name in ipairs(workspace.directories or {}) do
        core.add_project(system.absolute_path(dir_name))
      end
    end
    maybe_show_empty_project_file_tree()
  end)
end


local run = core.run

function core.run(...)
  if #core.docs == 0 then
    core.try(load_workspace)

    local set_project = core.set_project
    function core.set_project(project)
      core.try(save_workspace)
      project = set_project(project)
      core.try(load_workspace)
      return project
    end

    local open_project_in_same_window = core.open_project_in_same_window
    function core.open_project_in_same_window(project, ...)
      suppress_next_exit_workspace_save = true
      local result = table.pack(pcall(open_project_in_same_window, project, ...))
      if not result[1] then
        suppress_next_exit_workspace_save = false
        error(result[2], 0)
      end
      if suppress_next_exit_workspace_save then
        -- The wrapped function did not reach core.exit, so do not let a stale
        -- suppression skip an unrelated later quit.
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

  core.run = run
  return core.run(...)
end
