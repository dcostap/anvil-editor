-- Internal hosted frontend. It has no Project, Workspace, or Terminal client.
local core = require "core"
local saved_event = core.on_event
local view, last_query, revision
function core.init()
  core.log_items = {}
  core.log_quiet = function(...) system.log_shutdown(string.format(...)) end
  core.window = renwindow.create("Sidebar", 240, 600, 0, 0)
  core.active_window = core.window
  SCALE = system.get_scale(core.window)
  require "colors.default"
  local SidebarView = require "core.sidebar_view"
  view = SidebarView(function(action, id)
    for _, project in ipairs(core.project_sidebar or {}) do
      if project.row_id == id then
        if action == "select" then system.select_project(project.path)
        elseif action == "unload" then system.unload_project(project.path) end
        return
      end
    end
  end)
  core.redraw, last_query = true, -math.huge
end
function core.run() end
function core.on_event(name, ...)
  if name == "quit" or name == "shelllost" then core.quit_request = true
  elseif name == "projectsidebar" then saved_event(name, ...)
  elseif name == "mousepressed" then view:on_mouse_pressed(...); core.redraw = true
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
  if core.quit_request then return false end
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
  if visible and now - last_query >= 1 then
    core.request_project_sidebar(); last_query = now
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
  system.wait_event(.05)
  return true
end
return core
