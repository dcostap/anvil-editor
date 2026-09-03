-- mod-version:3
-- First-party Git View commands.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local file_context = require "core.file_context"
local keymap = require "core.keymap"
local style = require "core.style"
local GitView = require "plugins.git.view"
local backend = require "plugins.git.backend"
local historical_buffer = require "plugins.git.historical_buffer"
local model = require "plugins.git.model"
local FragmentBuffer = require "plugins.diff.fragment_buffer"
local panes = require "core.panes"
panes.git_sessions = panes.git_sessions or setmetatable({}, { __mode = "v" })
if not getmetatable(panes.git_sessions) then
  setmetatable(panes.git_sessions, { __mode = "v" })
end

local git_view = {
  backend = backend,
  Model = model,
  View = GitView,
}
local next_session_number = 0

local function current_project()
  return core.projects and core.projects[1] or core.root_project and core.root_project()
end

local function project_for_repo(repo)
  local project = current_project()
  if not project or not project.path
      or (not common.path_equals(project.path, repo.root)
        and not common.path_belongs_to(project.path, repo.root)) then
    return { path = repo.root }
  end
  return project
end

local function project_key(project)
  if type(project) == "table" then return project.path or tostring(project) end
  return tostring(project or "")
end

local function next_session_key(project)
  local prefix = project_key(project) .. "\0git\0"
  repeat
    next_session_number = next_session_number + 1
  until not panes.git_sessions[prefix .. next_session_number]
  return prefix .. next_session_number
end

local function retained_session_is_stale(session)
  for _, view in pairs(session and session.git_tab_views or {}) do
    if view.__pane_owner and not panes.contains(view.__pane_owner) then return true end
  end
  local view = session and session.git_view
  return view and view.__pane_owner and not panes.contains(view.__pane_owner) or false
end

local function retained_session_has_live_view(session)
  for _, view in pairs(session and session.git_tab_views or {}) do
    if view.__pane_owner and panes.contains(view.__pane_owner) then return true end
  end
  local view = session and session.git_view
  return not not (view and view.__pane_owner and panes.contains(view.__pane_owner))
end

local function make_git_session(project, opts)
  opts = opts or {}
  local project_id = project_key(project)
  local key = opts.session_key or next_session_key(project)
  local session = {
    project = project,
    project_key = project_id,
    kind = "git",
    key = key,
    title = "Git - " .. tostring(type(project) == "table" and project.path or project),
    window = opts.window or core.window,
    window_id = opts.window_id or (core.window and system.get_window_id and system.get_window_id(core.window)),
    hidden = false,
  }
  function session:raise() self.hidden = false; return self end
  function session:hide()
    self.hidden = true
    if self.git_view then self.git_view.visible = false end
    return self
  end
  function session:show()
    self.hidden = false
    if self.git_view then git_view.ensure_tab_view(self, self.git_model:log_tab(), true) end
    return self
  end
  function session:activate_root()
    local view = self.git_view
    if view then
      local pane = panes.pane_for_view(view)
      if pane then panes.present(view, { pane = pane, focus = true, reuse = true }) end
      local focus = view.get_focus_view and (view:get_focus_view() or view) or view
      core.set_active_view(focus)
      return view
    end
  end
  panes.git_sessions[key] = session
  core.log_quiet("Git View created session %s for Project %s", key, project_id)
  return session
end

local function live_git_view(view)
  if not (view and view.model and view.model.log_tab) then return nil end
  if view.tab_id and view.tab_id ~= "log" then
    if not (view.model.find_tab and view.model:find_tab(view.tab_id)) then return nil end
    local session = view.git_session
    if session and session.git_tab_views and session.git_tab_views[view.tab_id] ~= view then return nil end
  end
  return view
end

local function focused_git_view()
  local view = core.active_view
  return live_git_view(view) or live_git_view(view and view.git_owner_view)
end

local function active_git_view()
  return focused_git_view()
end

local function copy_options(options)
  local result = {}
  for key, value in pairs(options or {}) do result[key] = value end
  return result
end

local function pane_for_session(session)
  local view = session and session.git_view
  return panes.pane_for_view(view) or panes.active()
end

local function remove_pane_view(view)
  local pane = panes.pane_for_view(view)
  return pane and panes.close_view(pane, { view = view, force = true }) or false
end

local function install_model_update_hook(session)
  if not session or not session.git_model then return end
  session.git_model.on_update = function()
    git_view.sync_tab_views(session)
    core.redraw = true
  end
end

local function activate_git_tab_view(session, view)
  if not session or not view then return end
  local pane = panes.pane_for_view(view) or pane_for_session(session)
  if panes.pane_for_view(view) then
    panes.present(view, { pane = pane, focus = true, reuse = true })
  else
    panes.place(function() return view end, {
      pane = pane,
      placement = "current",
      focus = true,
      reason = "git-view",
    })
  end
  session.hidden = false
  local focus = view.get_focus_view and (view:get_focus_view() or view) or view
  if focus ~= view and panes.pane_for_view(view) then
    panes.register_focus_target(view, focus)
  end
  local previous_event_window = core.event_window
  core.event_window = session.window
  local ok = pcall(core.set_active_view, focus)
  if not ok then
    core.event_window = core.window
    core.active_window = core.window
    core.set_active_view(focus)
  end
  core.event_window = previous_event_window
end

function git_view.ensure_tab_view(session, tab, focus, target_pane)
  if not session or not tab then return nil end
  session.git_tab_views = session.git_tab_views or {}
  local view = session.git_tab_views[tab.id]
  local created = false
  if not view then
    view = GitView(session.project, {
      model = session.git_model,
      tab_id = tab.id,
      defer_refresh = true,
      on_update = function()
        git_view.sync_tab_views(session)
        core.redraw = true
      end,
    })
    view.git_session = session
    view.git_model_tab = tab
    created = true
    function view:on_model_tab_open(opened_tab)
      git_view.ensure_tab_view(session, opened_tab, true)
    end
    session.git_tab_views[tab.id] = view
    if target_pane then
      panes.present(view, { pane = target_pane, focus = false })
    end
  end
  view.git_model_tab = tab
  if created then session.git_model:load_view(tab, function() core.redraw = true end) end
  if view and not panes.pane_for_view(view) then
    if target_pane then
      panes.present(view, { pane = target_pane, focus = false })
    end
  end
  if focus then
    session.git_model:load_view(tab, function() core.redraw = true end)
    activate_git_tab_view(session, view)
  end
  return view
end

function git_view.sync_tab_views(session)
  if not session or not session.git_model then return end
  session.syncing_tabs = true
  session.git_tab_views = session.git_tab_views or {}
  local valid = {}
  for _, tab in ipairs(session.git_model.tabs or {}) do valid[tab.id] = tab end
  for id, view in pairs(session.git_tab_views) do
    if not valid[id] then
      local moved_tab = view.git_model_tab
      if moved_tab and valid[moved_tab.id] == moved_tab then
        session.git_tab_views[id] = nil
        view.tab_id = moved_tab.id
        session.git_tab_views[moved_tab.id] = view
      else
        remove_pane_view(view)
        session.git_tab_views[id] = nil
      end
    end
  end
  for _, tab in ipairs(session.git_model.tabs or {}) do
    git_view.ensure_tab_view(session, tab, false)
  end
  session.syncing_tabs = false
end

function git_view.open_log(project, opts)
  opts = opts or {}
  project = project or current_project()
  if not project then
    core.warn("Git View: no project is open")
    return nil
  end

  local view
  local session = make_git_session(project, opts)
  session.hidden = opts.state and opts.state.hidden or false
  local git_view_opts = copy_options(opts.git_view_opts)
  if opts.state and opts.state.model then git_view_opts.state = opts.state.model end
  if opts.state and opts.state.hidden then git_view_opts.defer_refresh = true end
  git_view_opts.tab_id = "log"
  view = GitView(project, git_view_opts)
  view.git_session = session
  function view:on_model_tab_open(opened_tab)
    git_view.ensure_tab_view(session, opened_tab, true)
  end
  session.git_view = view
  session.git_model = view.model
  session.git_tab_views = { log = view }
  install_model_update_hook(session)
  local focus = not session.hidden and opts.focus ~= false
  git_view.ensure_tab_view(session, view.model:log_tab(), false)
  git_view.sync_tab_views(session)
  if focus then git_view.ensure_tab_view(session, view.model:log_tab(), true) end
  return session, view
end

local function active_file_view()
  local view = core.active_view
  if view and view.get_focus_view then view = view:get_focus_view() or view end
  local buffer = view and view.buffer
  if not buffer then return nil end
  local target = file_context.view_path_target(view)
  if not (target and common.is_absolute_path(target.path)) then return nil end
  return view, buffer
end

local function active_file_path()
  local target = file_context.current_path_target()
  return target and common.is_absolute_path(target.path) and target.path or nil
end

local function active_selection_line_range()
  local view, buffer = active_file_view()
  if not buffer or not buffer.has_any_selection or not buffer:has_any_selection() then return nil end
  local target = file_context.view_path_target(view)
  local filename = target and target.path
  local function normalized_range(line1, col1, line2, col2)
    if line1 == line2 and col1 == col2 then return nil end
    if line2 < line1 or (line1 == line2 and col2 < col1) then
      line1, col1, line2, col2 = line2, col2, line1, col1
    end
    if line2 > line1 and col2 == 1 then line2 = line2 - 1 end
    if line2 >= line1 then
      if buffer.fragment_source then
        line1 = FragmentBuffer.map_line(buffer, line1)
        line2 = FragmentBuffer.map_line(buffer, line2)
      end
      return line1, line2
    end
  end

  local line1, col1, line2, col2 = buffer:get_selection(true)
  local start_line, end_line = normalized_range(line1, col1, line2, col2)
  if start_line then return filename, start_line, end_line end

  for _, sline1, scol1, sline2, scol2 in buffer:get_selections(true) do
    start_line, end_line = normalized_range(sline1, scol1, sline2, scol2)
    if start_line then return filename, start_line, end_line end
  end
end

local function show_git_progress(message)
  if core.status_bar and core.status_bar.show_message then
    core.status_bar:show_message("i", style.dim, message)
  end
end

local function active_or_open_view()
  local view = active_git_view()
  if view then
    return view.git_session, view
  end
  return git_view.open_log(current_project())
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

function git_view.save_state(session)
  if not session or not session.git_view or not session.git_view.model then return nil end
  return {
    kind = "git",
    session_key = session.key,
    hidden = session.hidden and true or false,
    model = session.git_view.model:get_state(),
  }
end

function git_view.restore_state(project, state, opts)
  local key = state and state.session_key
  local existing = key and panes.git_sessions[key]
  if existing and existing.git_view then
    if retained_session_is_stale(existing) or not retained_session_has_live_view(existing) then
      panes.git_sessions[key] = nil
      existing = nil
    end
  end
  if existing and existing.git_view then
    if state and state.model then existing.git_view.model:apply_state(state.model) end
    existing.git_model = existing.git_view.model
    install_model_update_hook(existing)
    git_view.sync_tab_views(existing)
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
  opts.session_key = key
  return git_view.open_log(project, opts)
end

command.add(nil, {
  ["git:open_log"] = command.palette(function()
    git_view.open_log()
  end, {
    keywords = { "version control", "history", "changes" },
    opens_view = true,
  }),

  ["git:refresh"] = command.palette(function()
    local session, view = active_or_open_view()
    if view then view.model:refresh_log(function() core.redraw = true end) end
  end),

  ["git:open_selected_commit_diff"] = {
    perform = function()
      local session, view = active_or_open_view()
      local function open_diff(v)
        local source = v:model_tab()
        if source and source.kind == "file_history" and source.loading then
          v.model:load_file_history(source, function() open_diff(v) end)
          return
        end
        local tab, err = v.model:open_selected_commit_diff(source, function() core.redraw = true end)
        if tab then git_view.ensure_tab_view(v.git_session, tab, true) end
        if not tab and err then core.log_quiet("Git View: open selected commit diff skipped: %s", err.message or err.kind) end
      end
      when_model_ready(view, open_diff)
    end,
    metadata = { opens_view = true },
  },

  ["git:open_working_tree_diff"] = command.palette(function()
    local session, view = active_or_open_view()
    when_model_ready(view, function(v)
      local tab, err = v.model:open_working_tree_diff(function() core.redraw = true end)
      if tab then git_view.ensure_tab_view(v.git_session, tab, true) end
      if not tab and err then core.log_quiet("Git View: open working tree diff skipped: %s", err.message or err.kind) end
    end)
  end, { opens_view = true }),

  ["git:show_file_history"] = command.palette(function()
    local filename = active_file_path()
    if not filename then
      core.log_quiet("Git View: file history skipped; active view has no file-backed buffer")
      return
    end
    show_git_progress("Loading File History…")
    backend.repo_for_path_async(filename, function(repo, err)
      if not repo then
        core.log_quiet("Git View: file history repo lookup failed: %s", err and (err.message or err.kind) or "unknown")
        return
      end
      local project = project_for_repo(repo)
      local session, view = git_view.open_log(project, { focus = false })
      when_model_ready(view, function(v)
        if v.model.repo and not common.path_equals(repo.root, v.model.repo.root) then
          v.model.repo = repo
        end
        local presented = false
        local function present_history(_, _, ready)
          if presented then return end
          if not (ready and ready.kind == "file_history") then return end
          presented = true
          git_view.ensure_tab_view(v.git_session, ready, true)
          core.redraw = true
        end
        local tab, tab_err = v.model:open_file_history(repo.relpath, present_history)
        if tab and not tab.loading and not tab.preview_loading then present_history(nil, nil, tab) end
        if not tab and tab_err then core.log_quiet("Git View: file history skipped: %s", tab_err.message or tab_err.kind) end
        core.redraw = true
      end)
    end)
  end, { opens_view = true }),

  ["git:show_selection_history"] = command.palette(function()
    local filename, start_line, end_line = active_selection_line_range()
    if not filename then
      core.log_quiet("Git View: selection history skipped; active file has no selection")
      return
    end
    show_git_progress("Loading Selection History…")
    backend.repo_for_path_async(filename, function(repo, err)
      if not repo then
        core.log_quiet("Git View: selection history repo lookup failed: %s", err and (err.message or err.kind) or "unknown")
        return
      end
      local project = project_for_repo(repo)
      local session, view = git_view.open_log(project, { focus = false })
      when_model_ready(view, function(v)
        if v.model.repo and not common.path_equals(repo.root, v.model.repo.root) then v.model.repo = repo end
        local presented = false
        local function present_history(_, _, ready)
          if presented then return end
          if not (ready and ready.kind == "file_history") then return end
          presented = true
          git_view.ensure_tab_view(v.git_session, ready, true)
          core.redraw = true
        end
        local tab, tab_err = v.model:open_selection_history(
          repo.relpath, start_line, end_line, present_history
        )
        if tab and not tab.loading and not tab.preview_loading then present_history(nil, nil, tab) end
        if not tab and tab_err then core.log_quiet("Git View: selection history skipped: %s", tab_err.message or tab_err.kind) end
        core.redraw = true
      end)
    end)
  end, { opens_view = true }),

  ["git:open_current_file_in_project_diff"] = command.palette(function()
    local filename = active_file_path()
    if not filename then
      core.log_quiet("Git View: current file diff skipped; active View has no Path Target")
      return
    end
    show_git_progress("Loading Current File Diff…")
    backend.repo_for_path_async(filename, function(repo, err)
      if not repo then
        core.log_quiet("Git View: current file diff repo lookup failed: %s", err and (err.message or err.kind) or "unknown")
        return
      end
      local project = project_for_repo(repo)
      local session, view = git_view.open_log(project, { focus = false })
      when_model_ready(view, function(v)
        v.model.repo = repo
        local tab, tab_err = v.model:open_working_tree_diff(function() core.redraw = true end, {
          selected_file_path = repo.relpath,
        })
        if tab then git_view.ensure_tab_view(v.git_session, tab, true) end
        if not tab and tab_err then core.log_quiet("Git View: current file diff skipped: %s", tab_err.message or tab_err.kind) end
      end)
    end)
  end, { opens_view = true }),

  ["git:copy_selected_commit_hash"] = command.palette(function()
    local view = active_git_view()
    local commit = view and view.model:selected_commit(view:model_tab())
    if not (commit and commit.hash) then return false end
    system.set_clipboard(commit.hash)
    return true
  end),

  ["git:copy_selected_commit_message"] = command.palette(function()
    local view = active_git_view()
    local commit = view and view.model:selected_commit(view:model_tab())
    if not commit then return false end
    local message = commit.subject or ""
    if commit.body and commit.body ~= "" then message = message .. "\n\n" .. commit.body end
    system.set_clipboard(message)
    return true
  end),

  ["git:open_selected_historical_buffer"] = {
    perform = function()
      local view = active_git_view()
      if not view then
        core.log_quiet("Git View: historical buffer open skipped; Git View is not open")
        return
      end
      local request, request_err = view.model:selected_historical_buffer(view:model_tab())
      if not request then
        core.log_quiet("Git View: historical buffer open skipped: %s", request_err.message or request_err.kind)
        return
      end
      if historical_buffer.activate_existing(request.repo, request.rev, request.relpath) then
        core.redraw = true
        return
      end
      view.model.backend.file_at(request.repo, request.rev, request.relpath, {}, function(text, err)
        if err then
          core.log_quiet("Git View: historical buffer load failed: %s", err.message or err.kind)
          return
        end
        historical_buffer.open(request.repo, request.rev, request.relpath, text or "")
        core.redraw = true
      end)
    end,
    metadata = { opens_view = true },
  },

})

command.add(function()
  local view = focused_git_view()
  if view then return true, view end
  return false
end, {
  ["git:select_next_row"] = function(view)
    if view and view.select_relative then view:select_relative(1) end
  end,

  ["git:select_previous_row"] = function(view)
    if view and view.select_relative then view:select_relative(-1) end
  end,

  ["git:focus_diff_pane"] = function(view)
    if view and view.focus_diff_pane then view:focus_diff_pane() end
  end,
})

local function close_git_view_tab(view)
  if not view then return end
  local session = view.git_session
  if view.tab_id == "log" and session then
    local pane = pane_for_session(session)
    local active = pane and pane.current_view
    if active and active.model == view.model and active.tab_id ~= "log" then view = active end
  end
  if view.tab_id == "log" then
    remove_pane_view(view)
    return
  end
  local pane = panes.pane_for_view(view)
  for i, tab in ipairs(view.model.tabs or {}) do
    if tab.id == view.tab_id and tab.closable then
      if view.dispose_tab_resources then view:dispose_tab_resources(tab) end
      if view.model.dispose_tab then view.model:dispose_tab(tab) end
      table.remove(view.model.tabs, i)
      break
    end
  end
  if session and session.git_tab_views then session.git_tab_views[view.tab_id] = nil end
  local previous_active = core.active_view
  remove_pane_view(view)
  local active = pane and panes.contains(pane) and pane.current_view
  if previous_active == view or previous_active and previous_active.git_owner_view == view then
    local focus_target = active and active.model == view.model and active or session and session.git_view
    if focus_target and focus_target ~= view and focus_target.focus_list_pane then
      focus_target:focus_list_pane()
    end
  end
  core.redraw = true
end

command.add(function()
  local view = focused_git_view()
  if view then return true, view end
  return false
end, {
  ["git:focus_list_pane"] = function(view)
    if view and view.focus_list_pane then view:focus_list_pane() end
  end,
  ["git:activate_selected_row"] = function(view)
    if not view then return end
    local diff_tab, err = view:activate_selected_point(function() core.redraw = true end)
    if not diff_tab and err then core.log_quiet("Git View: activate selected row skipped: %s", err.message or err.kind) end
  end,
  ["git:close_selected_tab"] = close_git_view_tab,
})

keymap.add({
  ["ctrl+k"] = "git:open_log",
  ["return"] = "git:activate_selected_row",
})

if not core.__git_focus_refresh_wrapped then
  core.__git_focus_refresh_wrapped = true
  local previous_on_event = core.on_event
  local git_focus_was_lost = false
  core.on_event = function(type, ...)
    local result = previous_on_event(type, ...)
    if type == "focuslost" then
      git_focus_was_lost = true
    elseif type == "focusgained" and git_focus_was_lost then
      git_focus_was_lost = false
      local view = active_git_view()
      if view then
        view:set_refresh_pending(nil, true)
        core.log_quiet("Git View requested refresh after application focus returned")
      end
    end
    return result
  end
end

return git_view
