-- mod-version:3
-- First-party Git View commands.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local tool_window = require "core.tool_window"
local RootPanel = require "core.rootpanel"
local GitView = require "plugins.git.view"
local backend = require "plugins.git.backend"
local model = require "plugins.git.model"

local git_view = {
  backend = backend,
  Model = model,
  View = GitView,
}

local function current_project()
  return core.root_project and core.root_project() or core.projects and core.projects[1]
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

command.add(nil, {
  ["git:open-view"] = function()
    git_view.open_view()
  end,

  ["git:refresh-view"] = function()
    local project = current_project()
    local tw = project and tool_window.get(project, "git")
    if tw and tw.git_view then
      tw.git_view.model:refresh_log(function() core.redraw = true end)
    else
      git_view.open_view(project)
    end
  end,
})

keymap.add({
  ["ctrl+k"] = "git:open-view",
})

return git_view
