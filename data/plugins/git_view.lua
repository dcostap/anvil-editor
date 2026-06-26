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

local function current_project()
  return core.root_project and core.root_project() or core.projects and core.projects[1]
end

local function active_git_view()
  local view = core.active_view
  if view and view.model and view.model.log_tab then return view end
  local project = current_project()
  local tw = project and tool_window.get(project, "git")
  return tw and tw.git_view or nil
end

function git_view.open_view(project, opts)
  opts = opts or {}
  project = project or current_project()
  if not project then
    core.warn("Git View: no project is open")
    return nil
  end

  local view
  local tw, created = tool_window.open(project, "git", {
    title = "Git - " .. tostring(project.path or project),
    width = opts.width or 1200,
    height = opts.height or 800,
    window = opts.window,
    window_id = opts.window_id,
    create_window = opts.create_window,
    root = opts.root,
    create_root = opts.create_root or function() return RootPanel() end,
  })
  if created then
    view = GitView(project, opts.git_view_opts)
    view.tool_window = tw
    tw.git_view = view
    local previous_event_window = core.event_window
    core.event_window = tw.window
    local ok, err = pcall(function()
      tw.root:get_active_node_default():add_view(view)
    end)
    core.event_window = previous_event_window
    if not ok then error(err, 0) end
    tw:activate_root()
  elseif tw.git_view then
    view = tw.git_view
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
  if model.repo and not log_tab.loading then
    action(view)
    return
  end
  model:refresh_log(function()
    action(view)
    core.redraw = true
  end)
end

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
    when_model_ready(view, function(v)
      local tab, err = v.model:open_selected_commit_diff(function() core.redraw = true end)
      if not tab and err then core.log_quiet("Git View: open selected commit diff skipped: %s", err.message or err.kind) end
    end)
  end,

  ["git:open-working-tree-diff"] = function()
    local tw, view = active_or_open_view()
    when_model_ready(view, function(v)
      local tab, err = v.model:open_working_tree_diff(function() core.redraw = true end)
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

  ["git:close-selected-tab"] = function()
    local view = active_git_view()
    if view and view.model:close_selected_tab() then core.redraw = true end
  end,
})

keymap.add({
  ["ctrl+k"] = "git:open-view",
})

return git_view
