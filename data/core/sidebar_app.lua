-- Internal hosted frontend. It has no Project, Workspace, or Terminal client.
local core = require "core"
local saved_event = core.on_event
local view, revision, query_needed, refresh_needed
function core.init()
  core.log_items = {}
  core.session_log = require("core.session_log").start(USERDIR .. PATHSEP .. "logs")
  core.log_quiet = function(...)
    if core.session_log then core.session_log:write("INFO", string.format(...), "Sidebar") end
  end
  core.log_quiet("Sidebar frontend started")
  if core.session_log then core.session_log:flush() end
  core.window = renwindow.create("Sidebar", 240, 600, 0, 0)
  core.active_window = core.window
  SCALE = system.get_scale(core.window)
  require "colors.default"
  local SidebarView = require "core.sidebar_view"
  view = SidebarView(function(action, id)
    if action == "refresh" then
      core.project_sidebar_request = nil
      query_needed, refresh_needed = true, true
      core.log_quiet("Sidebar Refresh requested")
      return
    end
    for _, project in ipairs(core.project_sidebar or {}) do
      if project.row_id == id then
        if action == "select" then system.select_project(project.path)
        elseif action == "unload" then system.unload_project(project.path) end
        return
      end
    end
  end)
  core.redraw, query_needed, refresh_needed = true, true, false
end
function core.run() end
function core.on_event(name, ...)
  if name == "quit" or name == "shelllost" then core.quit_request = true
  elseif name == "projectsidebarchanged" then
    core.project_sidebar_request = nil
    query_needed = true
  elseif name == "projectsidebar" then saved_event(name, ...)
  elseif name == "mousepressed" then
    local button, x, y = ...
    local width = renwindow.get_size(core.window)
    view:on_mouse_pressed(button, x, y, width); core.redraw = true
  elseif name == "mousewheel" then
    local _, height = renwindow.get_size(core.window)
    view:on_mouse_wheel((...), height); core.redraw = true
  elseif name == "resized" or name == "exposed" or name == "displaychanged" then core.redraw = true end
end
function core.run_step()
  while true do
    local event = table.pack(system.poll_event())
    if not event[1] then break end
    core.on_event(table.unpack(event, 1, event.n))
  end
  if core.quit_request then
    if core.session_log then core.session_log:close(); core.session_log = nil end
    return false
  end
  local current_scale = system.get_scale(core.window)
  if current_scale ~= SCALE then
    local factor = current_scale / SCALE
    local font = require("core.style").font
    font:set_size(font:get_size() * factor)
    view.scroll, SCALE = view.scroll * factor, current_scale
    core.redraw = true
  end
  local visible = system.window_should_render(core.window)
  local now = system.get_time()
  if core.project_sidebar_request and now - core.project_sidebar_request.started >= 5 then
    core.project_sidebar_request = nil
    query_needed = true
    core.log_quiet("Sidebar snapshot timed out; request the complete model again")
  end
  if visible and query_needed then
    if core.request_project_sidebar(refresh_needed) then query_needed, refresh_needed = false, false end
  end
  if core.project_sidebar and revision ~= core.project_sidebar.revision then
    revision = core.project_sidebar.revision
    view:set_model(core.project_sidebar); core.redraw = true
  end
  if visible and core.redraw then
    local width, height = renwindow.get_size(core.window)
    renderer.begin_frame(core.window)
    view:draw(width, height)
    renderer.end_frame()
    core.redraw = false
  end
  if core.project_sidebar_request then system.wait_event(.01)
  else system.wait_event() end
  return true
end
return core
