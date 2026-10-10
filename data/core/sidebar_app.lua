-- One disposable frontend serves independent Sidebar surfaces in the shell's Windows.
local core = require "core"
local saved_event = core.on_event
local surfaces, current = {}, nil
local SidebarView, font, base_font_size
local fonts, style = {}, nil

local function save()
  if not current then return end
  current.model, current.request = core.project_sidebar, core.project_sidebar_request
  current.redraw = core.redraw
end
local function activate(id)
  local surface = surfaces[id]
  if not surface or not system.activate_sidebar_surface(id) then return false end
  save()
  current = surface
  core.window, core.active_window = surface.window, surface.window
  core.project_sidebar, core.project_sidebar_request = surface.model, surface.request
  core.redraw = surface.redraw
  local scale = system.get_scale(surface.window)
  if surface.scale ~= scale then
    surface.view.scroll = surface.view.scroll * scale / surface.scale
    surface.scale, core.redraw = scale, true
  end
  SCALE = scale
  if font then
    if not fonts[scale] then
      fonts[scale] = font:copy(base_font_size * scale)
      core.log_quiet("Sidebar font created: scale=%g", scale)
    end
    style.font = fonts[scale]
  end
  return true
end
local function add_surface(id, window)
  local surface = {id = id, window = window, native_id = system.get_window_id(window), scale = system.get_scale(window),
    redraw = true, query_needed = true, refresh_needed = false}
  surface.view = SidebarView(function(action, row_id, target)
    if action == "move" then
      core.log_quiet("Sidebar Move: Window=%d Project=%d target=%d", id, row_id, target)
      if not system.move_project(row_id, target) then core.log_quiet("Sidebar Move request rejected: Project=%d target=%d", row_id, target) end
      return
    end
    if action == "refresh" then
      core.project_sidebar_request = nil
      surface.query_needed, surface.refresh_needed = true, true
      core.log_quiet("Sidebar Refresh requested: Window=%d", id)
      return
    end
    for _, project in ipairs(core.project_sidebar or {}) do
      if project.row_id == row_id then
        if action == "select" then
          core.log_quiet("Sidebar selection: Window=%d Project=%d owner=%d", id, project.id, project.window_id)
          system.select_project(project.path)
        elseif action == "unload" then system.unload_project(project.path) end
        return
      end
    end
  end)
  surfaces[id] = surface
  core.log_quiet("Sidebar surface created: Window=%d", id)
end
local function sync_surfaces()
  for _, item in ipairs(system.sidebar_surfaces()) do
    local surface = surfaces[item.id]
    if item.removed then
      if surface then
        if current == surface then current = nil end
        renwindow.close(surface.window)
        surfaces[item.id] = nil
        core.log_quiet("Sidebar surface removed: Window=%d", item.id)
      end
    elseif not surface then
      save()
      system.activate_sidebar_surface(item.id)
      add_surface(item.id, renwindow.create("Sidebar", 240, 600))
      current = nil
    end
  end
end
function core.init()
  core.log_items = {}
  core.session_log = require("core.session_log").start(USERDIR .. PATHSEP .. "logs")
  core.log_quiet = function(...)
    if core.session_log then core.session_log:write("INFO", string.format(...), "Sidebar") end
  end
  core.log_quiet("Sidebar frontend started")
  if core.session_log then core.session_log:flush() end
  local window = renwindow.create("Sidebar", 240, 600)
  core.window, core.active_window = window, window
  SCALE = system.get_scale(window)
  require "colors.default"
  SidebarView = require "core.sidebar_view"
  style = require "core.style"
  font = style.font
  base_font_size = font:get_size() / SCALE
  fonts[SCALE] = font
  local id = system.get_anvil_window_id()
  add_surface(id, window)
  activate(id)
end
function core.run() end
function core.on_event(name, ...)
  if name == "quit" or name == "shelllost" then core.quit_request = true; return end
  if not current then return end
  if name == "projectsidebarchanged" then
    core.project_sidebar_request = nil
    current.query_needed = true
  elseif name == "projectsidebar" then saved_event(name, ...)
  elseif name == "mousepressed" then
    local button, x, y = ...
    local width = renwindow.get_size(core.window)
    current.view:on_mouse_pressed(button, x, y, width); core.redraw = true
  elseif name == "mousewheel" then
    local _, height = renwindow.get_size(core.window)
    current.view:on_mouse_wheel((...), height); core.redraw = true
  elseif name == "resized" or name == "exposed" or name == "displaychanged" then core.redraw = true end
  save()
end
function core.run_step()
  sync_surfaces()
  while true do
    local event = table.pack(system.poll_event())
    if not event[1] then break end
    local native_id = system.get_last_event_window_id()
    sync_surfaces()
    local id
    for candidate, surface in pairs(surfaces) do
      if surface.native_id == native_id then id = candidate end
    end
    if event[1] == "projectsidebarchanged" and not native_id then
      for _, surface in pairs(surfaces) do surface.request, surface.query_needed = nil, true end
      core.project_sidebar_request = nil
    elseif activate(id) or event[1] == "quit" or event[1] == "shelllost" then
      core.on_event(table.unpack(event, 1, event.n))
    end
  end
  sync_surfaces()
  if core.quit_request then
    if core.session_log then core.session_log:close(); core.session_log = nil end
    return false
  end
  local pending = false
  for id, surface in pairs(surfaces) do
    if activate(id) then
      local visible, now = system.window_should_render(core.window), system.get_time()
      if core.project_sidebar_request and now - core.project_sidebar_request.started >= 5 then
        core.project_sidebar_request = nil
        surface.query_needed = true
        core.log_quiet("Sidebar snapshot timed out: Window=%d", id)
      end
      if visible and surface.query_needed and core.request_project_sidebar(surface.refresh_needed) then
        surface.query_needed, surface.refresh_needed = false, false
      end
      if core.project_sidebar and surface.revision ~= core.project_sidebar.revision then
        surface.revision = core.project_sidebar.revision
        surface.view:set_model(core.project_sidebar, id); core.redraw = true
      end
      if visible and core.redraw then
        local width, height = renwindow.get_size(core.window)
        renderer.begin_frame(core.window)
        surface.view:draw(width, height)
        renderer.end_frame()
        core.redraw = false
      end
      pending = pending or core.project_sidebar_request ~= nil
      save()
    end
  end
  -- Keep fonts only for scales still used by a live surface. Activation never resizes them.
  local used = {}
  for _, surface in pairs(surfaces) do used[surface.scale] = true end
  for scale in pairs(fonts) do if not used[scale] then fonts[scale] = nil end end
  if pending then system.wait_event(.01) else system.wait_event() end
  return true
end
return core
