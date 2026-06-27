-- mod-version:3
-- First-party Git View commands.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local tool_window = require "core.tool_window"
local RootPanel = require "core.rootpanel"
local GitView = require "plugins.git.view"
local backend = require "plugins.git.backend"
local historical_document = require "plugins.git.historical_document"
local model = require "plugins.git.model"

local git_view = {
  backend = backend,
  Model = model,
  View = GitView,
}

local active_node
local sync_model_active_from_focus

local function current_project()
  return core.projects and core.projects[1] or core.root_project and core.root_project()
end

local function project_key(project)
  if type(project) == "table" then return project.path or tostring(project) end
  return tostring(project or "")
end

local function make_main_tabs_git_session(project, opts)
  opts = opts or {}
  local main_tabs = core.main_tabs or require "core.main_tabs"
  local key = project_key(project)
  local tw = main_tabs.git_sessions[key]
  if tw then return tw, false end
  tw = {
    __main_tabs = true,
    project = project,
    project_key = key,
    kind = "git",
    key = key .. "\0git",
    title = "Git - " .. tostring(type(project) == "table" and project.path or project),
    window = opts.window or core.window,
    window_id = opts.window_id or (core.window and system.get_window_id and system.get_window_id(core.window)),
    root = opts.root or core.root_panel,
    hidden = false,
  }
  function tw:raise() self.hidden = false; return self end
  function tw:hide()
    self.hidden = true
    if self.git_view then self.git_view.visible = false end
    return self
  end
  function tw:show()
    self.hidden = false
    local tab = self.git_model and self.git_model:selected_tab()
    local view = self.git_tab_views and tab and self.git_tab_views[tab.id] or self.git_view
    if view then git_view.ensure_tab_view(self, tab or self.git_model:log_tab(), true) end
    return self
  end
  function tw:activate_root()
    local tab = self.git_model and self.git_model:selected_tab()
    local view = self.git_tab_views and tab and self.git_tab_views[tab.id] or self.git_view
    if view then
      local focus = view.get_focus_view and (view:get_focus_view() or view) or view
      core.set_active_view(focus)
      return view
    end
  end
  main_tabs.git_sessions[key] = tw
  return tw, true
end

local function live_git_view(view)
  if not (view and view.model and view.model.log_tab) then return nil end
  if view.tab_id and view.tab_id ~= "log" then
    if not (view.model.find_tab and view.model:find_tab(view.tab_id)) then return nil end
    local tw = view.tool_window
    if tw and tw.git_tab_views and tw.git_tab_views[view.tab_id] ~= view then return nil end
  end
  return view
end

local function focused_git_view()
  local view = core.active_view
  return live_git_view(view) or live_git_view(view and view.git_owner_view)
end

local function active_git_view()
  return focused_git_view() or (function()
    local project = current_project()
    local main_tabs = core.main_tabs
    local tw = project and main_tabs and main_tabs.git_sessions[project_key(project)]
    if not tw then return nil end
    sync_model_active_from_focus(tw)
    local node = active_node(tw)
    local node_view = node and node.active_view
    if node_view and node_view.model and node_view.model.log_tab then return node_view end
    return (tw.git_tab_views and tw.git_model and tw.git_tab_views[tw.git_model.active_tab]) or tw.git_view
  end)()
end

local function copy_options(options)
  local result = {}
  for key, value in pairs(options or {}) do result[key] = value end
  return result
end

function active_node(tw)
  if tw and tw.__main_tabs then return tw.root and tw.root.get_main_panel and tw.root:get_main_panel() end
  if not tw or not tw.root then return nil end
  local root = tw.root.root_node
  local active = core.active_view
  local owner = active and (active.git_owner_view or active)
  if root and owner and root.get_node_for_view then
    local node = root:get_node_for_view(owner)
    if node then return node end
  end
  return tw.root.get_active_node_default and tw.root:get_active_node_default()
end

local function node_in_tree(root, target)
  if not root or not target then return false end
  if root == target then return true end
  if root.type ~= "leaf" then return node_in_tree(root.a, target) or node_in_tree(root.b, target) end
  return false
end

local function owner_node_for_view(tw, view)
  if tw and tw.__main_tabs then
    local root = tw.root and tw.root.root_node
    local found = root and root.get_node_for_view and root:get_node_for_view(view)
    if found then return found end
    local node = active_node(tw)
    if node and node.views then
      for _, candidate in ipairs(node.views) do
        if candidate == view then return node end
      end
    end
    return nil
  end
  local root = tw and tw.root and tw.root.root_node
  if root and root.get_node_for_view then
    local node = root:get_node_for_view(view)
    if node then return node end
  end
  local node = active_node(tw)
  if node and node.views then
    for _, candidate in ipairs(node.views) do
      if candidate == view then return node end
    end
  end
end

local function remove_node_view(tw, view)
  local node = owner_node_for_view(tw, view)
  if node and node.remove_view and tw and tw.root and tw.root.root_node then
    node:remove_view(tw.root.root_node, view)
    return true
  elseif node and node.views then
    for i = #node.views, 1, -1 do
      if node.views[i] == view then table.remove(node.views, i) end
    end
    if node.active_view == view then node.active_view = node.views[#node.views] end
    return true
  end
end

local function install_model_update_hook(tw)
  if not tw or not tw.git_model then return end
  tw.git_model.on_update = function()
    git_view.sync_tab_views(tw, false)
    core.redraw = true
  end
end

local function activate_git_tab_view(tw, view)
  if not tw or not view then return end
  local node = owner_node_for_view(tw, view) or active_node(tw)
  if node then node.active_view = view end
  if tw.__main_tabs then
    local main_tabs = core.main_tabs or require "core.main_tabs"
    main_tabs.open_view(view, { focus = false })
    tw.hidden = false
  elseif tw.show then
    tw:show()
  end
  local focus = view.get_focus_view and (view:get_focus_view() or view) or view
  local previous_event_window = core.event_window
  core.event_window = tw.window
  local ok = pcall(core.set_active_view, focus)
  if not ok then
    core.event_window = core.window
    core.active_window = core.window
    core.set_active_view(focus)
  end
  core.event_window = previous_event_window
end

function sync_model_active_from_focus(tw)
  if not (tw and tw.git_model) or tw.hidden then return end
  local view = focused_git_view()
  if view and view.tool_window == tw and view.tab_id and tw.git_model:find_tab(view.tab_id) then
    tw.git_model.active_tab = view.tab_id
  end
end

function git_view.ensure_tab_view(tw, tab, focus, target_node)
  if not tw or not tab then return nil end
  tw.git_tab_views = tw.git_tab_views or {}
  local view = tw.git_tab_views[tab.id]
  if not view then
    view = GitView(tw.project, {
      model = tw.git_model,
      tab_id = tab.id,
      defer_refresh = true,
      on_update = function()
        git_view.sync_tab_views(tw, false)
        core.redraw = true
      end,
    })
    view.tool_window = tw
    function view:on_model_tab_open(opened_tab)
      git_view.ensure_tab_view(tw, opened_tab, true)
    end
    tw.git_tab_views[tab.id] = view
    local node = target_node or active_node(tw)
    if tw.__main_tabs then
      local main_tabs = core.main_tabs or require "core.main_tabs"
      main_tabs.open_view(view, { focus = focus == true, node = node })
    elseif node and node.add_view then
      if focus then
        node:add_view(view)
      elseif node.views then
        table.insert(node.views, view)
      else
        local previous_node_active = node.active_view
        local previous_core_active = core.active_view
        node:add_view(view)
        node.active_view = previous_node_active
        core.active_view = previous_core_active
      end
    end
  end
  if tw.__main_tabs and view and not owner_node_for_view(tw, view) then
    local main_tabs = core.main_tabs or require "core.main_tabs"
    main_tabs.open_view(view, { focus = false, node = active_node(tw) })
  end
  if focus then
    tab = tw.git_model:select_tab(tab.id, function() core.redraw = true end) or tab
    activate_git_tab_view(tw, view)
  end
  return view
end

local function focus_model_active_tab(tw)
  if not tw or not tw.git_model then return end
  local tab = tw.git_model:selected_tab()
  return git_view.ensure_tab_view(tw, tab, true)
end

function git_view.sync_tab_views(tw, focus_active)
  if not tw or not tw.git_model then return end
  tw.git_tab_views = tw.git_tab_views or {}
  local valid = {}
  for _, tab in ipairs(tw.git_model.tabs or {}) do valid[tab.id] = tab end
  local preserve_focus, preserve_view, preserve_node
  for id, view in pairs(tw.git_tab_views) do
    if not valid[id] then
      local owner_node = owner_node_for_view(tw, view)
      if core.active_view == view or (core.active_view and core.active_view.git_owner_view == view)
          or (owner_node and owner_node.active_view == view) then
        preserve_focus = true
        preserve_view = view
        preserve_node = owner_node
      end
      remove_node_view(tw, view)
      tw.git_tab_views[id] = nil
    end
  end
  for _, tab in ipairs(tw.git_model.tabs or {}) do
    local target_node = preserve_focus and tab.id == tw.git_model.active_tab and preserve_node or nil
    if target_node and not node_in_tree(tw.root and tw.root.root_node, target_node) then target_node = nil end
    local view = git_view.ensure_tab_view(tw, tab, false, target_node)
    if preserve_focus and preserve_view and tab.id == tw.git_model.active_tab and view then
      view.focus_pane = preserve_view.focus_pane
      view.focused_diff_doc_view = nil
    end
  end
  local tab = tw.git_model:selected_tab()
  local view = tw.git_tab_views and tab and tw.git_tab_views[tab.id]
  local node = view and (owner_node_for_view(tw, view) or active_node(tw))
  if view and node then
    node.active_view = view
    if (focus_active or preserve_focus) and not tw.hidden then tw:activate_root() end
  end
  return view
end

function git_view.open_view(project, opts)
  opts = opts or {}
  project = project or current_project()
  if not project then
    core.warn("Git View: no project is open")
    return nil
  end

  local view
  local tw, created = make_main_tabs_git_session(project, opts)
  tw.hidden = opts.state and opts.state.hidden or false
  if created or not tw.git_view then
    local git_view_opts = copy_options(opts.git_view_opts)
    if opts.state and opts.state.model then git_view_opts.state = opts.state.model end
    if opts.state and opts.state.hidden then git_view_opts.defer_refresh = true end
    git_view_opts.tab_id = "log"
    view = GitView(project, git_view_opts)
    view.tool_window = tw
    function view:on_model_tab_open(opened_tab)
      git_view.ensure_tab_view(tw, opened_tab, true)
    end
    tw.git_view = view
    tw.git_model = view.model
    tw.git_tab_views = { log = view }
    tw.hidden = opts.state and opts.state.hidden or false
    install_model_update_hook(tw)
    git_view.ensure_tab_view(tw, view.model:log_tab(), not tw.hidden)
    git_view.sync_tab_views(tw, not tw.hidden)
    if not tw.hidden then focus_model_active_tab(tw) end
  elseif tw.git_view then
    view = (tw.git_tab_views and tw.git_tab_views[tw.git_model.active_tab]) or tw.git_view
    view:set_refresh_pending()
    git_view.ensure_tab_view(tw, view:model_tab(), true)
  end
  return tw, view
end

local function active_file_view()
  local view = core.active_view
  if view and view.get_focus_view then view = view:get_focus_view() or view end
  local doc = view and view.doc
  if not doc or doc.new_file or not doc.abs_filename or not common.is_absolute_path(doc.abs_filename) then return nil end
  return view, doc
end

local function active_file_path()
  local view, doc = active_file_view()
  return doc and doc.abs_filename
end

local function active_selection_line_range()
  local view, doc = active_file_view()
  if not doc or not doc.has_any_selection or not doc:has_any_selection() then return nil end
  local function normalized_range(line1, col1, line2, col2)
    if line1 == line2 and col1 == col2 then return nil end
    if line2 < line1 or (line1 == line2 and col2 < col1) then
      line1, col1, line2, col2 = line2, col2, line1, col1
    end
    if line2 > line1 and col2 == 1 then line2 = line2 - 1 end
    if line2 >= line1 then return line1, line2 end
  end

  local line1, col1, line2, col2 = doc:get_selection(true)
  local start_line, end_line = normalized_range(line1, col1, line2, col2)
  if start_line then return doc.abs_filename, start_line, end_line end

  for _, sline1, scol1, sline2, scol2 in doc:get_selections(true) do
    start_line, end_line = normalized_range(sline1, scol1, sline2, scol2)
    if start_line then return doc.abs_filename, start_line, end_line end
  end
end

local function active_or_open_view()
  local view = active_git_view()
  if view then
    if view.tool_window then view.tool_window:show() end
    return view.tool_window, view
  end
  return git_view.open_view(current_project())
end

local function when_model_ready(view, action)
  if not view then return end
  local model = view.model
  local log_tab = model:log_tab()
  if view.refresh_started and model.repo and not log_tab.loading then
    action(view)
    return
  end
  view:set_refresh_pending(function(v)
    action(v)
    core.redraw = true
  end)
end

function git_view.save_state(tw)
  if not tw or not tw.git_view or not tw.git_view.model then return nil end
  sync_model_active_from_focus(tw)
  return {
    kind = "git",
    hidden = tw.hidden and true or false,
    model = tw.git_view.model:get_state(),
  }
end

function git_view.restore_state(project, state, opts)
  local existing = tool_window.get(project, "git")
  if existing and existing.git_view then
    if state and state.model then existing.git_view.model:apply_state(state.model) end
    existing.git_model = existing.git_view.model
    install_model_update_hook(existing)
    git_view.sync_tab_views(existing, not (state and state.hidden))
    existing.git_view.refresh_started = false
    existing.git_view.refresh_inflight = false
    existing.git_view.refresh_callbacks = nil
    if state and state.hidden then
      existing:hide()
    else
      existing:show()
      existing.git_view:set_refresh_pending()
    end
    return existing, existing.git_view
  end
  opts = copy_options(opts)
  opts.state = state
  return git_view.open_view(project, opts)
end

tool_window.register_kind("git", {
  save = git_view.save_state,
  restore = git_view.restore_state,
})

command.add(nil, {
  ["git:open-view"] = function()
    git_view.open_view()
  end,

  ["git:refresh-view"] = function()
    local tw, view = active_or_open_view()
    if view then view.model:refresh_log(function() core.redraw = true end) end
  end,

  ["git:open-selected-commit-diff"] = function()
    local tw, view = active_or_open_view()
    local function open_diff(v)
      if v.activate_model_tab then v:activate_model_tab(function() core.redraw = true end) end
      local selected = v.model:selected_tab()
      if selected and selected.kind == "file_history" and selected.loading then
        v.model:load_file_history(selected, function() open_diff(v) end)
        return
      end
      local tab, err = v.model:open_selected_commit_diff(function() core.redraw = true end)
      if tab then git_view.ensure_tab_view(v.tool_window, tab, true) end
      if not tab and err then core.log_quiet("Git View: open selected commit diff skipped: %s", err.message or err.kind) end
    end
    when_model_ready(view, open_diff)
  end,

  ["git:open-working-tree-diff"] = function()
    local tw, view = active_or_open_view()
    when_model_ready(view, function(v)
      local tab, err = v.model:open_working_tree_diff(function() core.redraw = true end)
      if tab then git_view.ensure_tab_view(v.tool_window, tab, true) end
      if not tab and err then core.log_quiet("Git View: open working tree diff skipped: %s", err.message or err.kind) end
    end)
  end,

  ["git:show-file-history"] = function()
    local filename = active_file_path()
    if not filename then
      core.log_quiet("Git View: file history skipped; active view has no file-backed document")
      return
    end
    backend.repo_for_path_async(filename, function(repo, err)
      if not repo then
        core.log_quiet("Git View: file history repo lookup failed: %s", err and (err.message or err.kind) or "unknown")
        return
      end
      local project = current_project()
      if not project or not project.path
          or (not common.path_equals(project.path, repo.root) and not common.path_belongs_to(project.path, repo.root)) then
        project = { path = repo.root }
      end
      local tw, view = git_view.open_view(project)
      when_model_ready(view, function(v)
        if v.model.repo and not common.path_equals(repo.root, v.model.repo.root) then
          v.model.repo = repo
        end
        local tab, tab_err = v.model:open_file_history(repo.relpath, function() core.redraw = true end)
        if tab then git_view.ensure_tab_view(v.tool_window, tab, true) end
        if not tab and tab_err then core.log_quiet("Git View: file history skipped: %s", tab_err.message or tab_err.kind) end
        core.redraw = true
      end)
    end)
  end,

  ["git:show-selection-history"] = function()
    local filename, start_line, end_line = active_selection_line_range()
    if not filename then
      core.log_quiet("Git View: selection history skipped; active file has no selection")
      return
    end
    local _, doc = active_file_view()
    if doc and doc.is_dirty and doc:is_dirty() then
      core.log_quiet("Git View: selection history skipped; document has unsaved edits")
      return
    end
    backend.repo_for_path_async(filename, function(repo, err)
      if not repo then
        core.log_quiet("Git View: selection history repo lookup failed: %s", err and (err.message or err.kind) or "unknown")
        return
      end
      backend.path_status(repo, repo.relpath, { ignored = true }, function(status, status_err)
        if status_err then
          core.log_quiet("Git View: selection history status failed: %s", status_err.message or status_err.kind)
          return
        end
        if status and #status > 0 then
          core.log_quiet("Git View: selection history skipped; file has Git changes")
          return
        end
        local project = current_project()
        if not project or not project.path
            or (not common.path_equals(project.path, repo.root) and not common.path_belongs_to(project.path, repo.root)) then
          project = { path = repo.root }
        end
        local tw, view = git_view.open_view(project)
        when_model_ready(view, function(v)
          if v.model.repo and not common.path_equals(repo.root, v.model.repo.root) then v.model.repo = repo end
          local tab, tab_err = v.model:open_selection_history(repo.relpath, start_line, end_line, function() core.redraw = true end)
          if tab then git_view.ensure_tab_view(v.tool_window, tab, true) end
          if not tab and tab_err then core.log_quiet("Git View: selection history skipped: %s", tab_err.message or tab_err.kind) end
          core.redraw = true
        end)
      end)
    end)
  end,

  ["git:open-selected-historical-document"] = function()
    local view = active_git_view()
    if not view then
      core.log_quiet("Git View: historical document open skipped; Git View is not open")
      return
    end
    if view.activate_model_tab then view:activate_model_tab(function() core.redraw = true end) end
    local request, request_err = view.model:selected_historical_document()
    if not request then
      core.log_quiet("Git View: historical document open skipped: %s", request_err.message or request_err.kind)
      return
    end
    if historical_document.activate_existing(request.repo, request.rev, request.relpath) then
      core.redraw = true
      return
    end
    view.model.backend.file_at(request.repo, request.rev, request.relpath, {}, function(text, err)
      if err then
        core.log_quiet("Git View: historical document load failed: %s", err.message or err.kind)
        return
      end
      historical_document.open(request.repo, request.rev, request.relpath, text or "")
      core.redraw = true
    end)
  end,

})

command.add(function()
  local view = focused_git_view()
  if view then return true, view end
  return false
end, {
  ["git:select-next-row"] = function(view)
    if view and view.select_relative then view:select_relative(1) end
  end,

  ["git:select-previous-row"] = function(view)
    if view and view.select_relative then view:select_relative(-1) end
  end,

  ["git:focus-diff-pane"] = function(view)
    if view and view.focus_diff_pane then view:focus_diff_pane() end
  end,

  ["git:close-selected-tab"] = function(view)
    if not view then return end
    local tw = view.tool_window
    view:try_close(function()
      local node = active_node(tw)
      if node and node.remove_view and tw and tw.root and tw.root.root_node then
        node:remove_view(tw.root.root_node, view)
      end
    end)
  end,
})

local function close_git_view_tab(view)
  if not view then return end
  local tw = view.tool_window
  if view.tab_id == "log" and tw then
    local node = active_node(tw)
    local active = node and node.active_view
    if active and active.model == view.model and active.tab_id ~= "log" then view = active end
  end
  if view.tab_id == "log" then
    view:try_close(function()
      remove_node_view(tw, view)
    end)
    return
  end
  local node = owner_node_for_view(tw, view)
  for i, tab in ipairs(view.model.tabs or {}) do
    if tab.id == view.tab_id and tab.closable then
      table.remove(view.model.tabs, i)
      break
    end
  end
  if tw and tw.git_tab_views then tw.git_tab_views[view.tab_id] = nil end
  local previous_active = core.active_view
  remove_node_view(tw, view)
  local active = node and node.active_view
  if previous_active == view or previous_active and previous_active.git_owner_view == view then
    local focus_target = active and active.model == view.model and active or tw and tw.git_view
    if focus_target and focus_target ~= view and focus_target.focus_list_pane then
      focus_target:focus_list_pane()
    end
  end
  if active and active.model == view.model and active.tab_id and view.model:find_tab(active.tab_id) then
    view.model.active_tab = active.tab_id
  elseif view.model:find_tab("log") then
    view.model.active_tab = "log"
  end
  core.redraw = true
end

command.add(function()
  local view = active_git_view()
  if view then return true, view end
  return false
end, {
  ["git:focus-list-pane"] = function(view)
    if view and view.focus_list_pane then view:focus_list_pane() end
  end,
  ["git:activate-selected-row"] = function(view)
    if not view then return end
    local active_tab = view.model:selected_tab()
    local diff_tab, err = view:activate_selected(function() core.redraw = true end)
    if active_tab.kind ~= "commit_diff" and diff_tab then git_view.ensure_tab_view(view.tool_window, diff_tab, true) end
    if not diff_tab and err then core.log_quiet("Git View: activate selected row skipped: %s", err.message or err.kind) end
  end,
  ["git:close-selected-tab"] = close_git_view_tab,
})

command.add(function()
  local view = focused_git_view()
  if view and view.can_focus_next_pane and view:can_focus_next_pane() then return true, view end
  return false
end, {
  ["git:focus-next-pane"] = function(view)
    if view and view.focus_next_pane then view:focus_next_pane() end
  end,
})

keymap.add({
  ["ctrl+k"] = "git:open-view",
  ["return"] = "git:activate-selected-row",
  ["alt+r"] = "git:activate-selected-row",
  ["alt+shift+`"] = "git:focus-diff-pane",
})

return git_view
