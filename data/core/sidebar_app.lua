-- One disposable frontend serves independent Sidebar surfaces in the shell's Windows.
local core = require "core"
local saved_event = core.on_event
local surfaces, current = {}, nil
local SidebarView, font, base_font_size
local fonts, style = {}, nil
local color_theme = require "core.color_theme"
local storage = require "core.storage"

-- Which Sidebar groups are collapsed. Every surface shares it, and the next Sidebar process restores it.
local collapsed = {}
local function load_collapsed()
  local ok, saved = pcall(storage.load, "sidebar", "collapsed")
  if ok and type(saved) == "table" then
    for key, value in pairs(saved) do
      if type(key) == "string" and type(value) == "boolean" then collapsed[key] = value end
    end
  end
  core.log_quiet("Sidebar collapse state: %s", ok and saved and "loaded" or "defaults")
end
local function save_collapsed()
  local ok, err = pcall(storage.save, "sidebar", "collapsed", collapsed)
  if not ok then core.log_quiet("Sidebar collapse state not saved: %s", tostring(err)) end
end

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
    redraw = true, query_needed = true}
  surface.view = SidebarView(function(action, row_id, target, ...)
    if action == "collapsed" then
      core.log_quiet("Sidebar group %s collapsed=%s", row_id, tostring(target))
      save_collapsed()
      -- Other surfaces share the state. Their rows change too.
      for _, other in pairs(surfaces) do
        if other ~= surface then other.view:rebuild_rows(); other.redraw = true end
      end
      return
    end
    if action == "select_terminal" then
      for _, project in ipairs(core.project_sidebar or {}) do
        if project.row_id == row_id then
          local sent = system.select_terminal(project.path, target)
          core.log_quiet("Sidebar Terminal Session selection: Window=%d Project=%d session=%s sent=%s", id,
            project.id or 0, target, tostring(sent))
          return
        end
      end
      return
    end
    if action == "menu" then
      local x, y = target, ...
      local sent = system.show_project_menu(row_id, x, y)
      core.log_quiet("Sidebar Project menu: Window=%d row=%d sent=%s", id, row_id, tostring(sent))
      return
    end
    for _, project in ipairs(core.project_sidebar or {}) do
      if project.row_id == row_id then
        if action == "select" then
          core.log_quiet("Sidebar selection: Window=%d Project=%d owner=%d", id, project.id, project.window_id)
          system.select_project(project.path)
        end
        return
      end
    end
    core.log_quiet("Sidebar %s dropped: Window=%d row=%s is not in the model (%d rows)", action, id,
      tostring(row_id), #(core.project_sidebar or {}))
  end, collapsed)
  surfaces[id] = surface
  core.log_quiet("Sidebar surface created: Window=%d", id)
end
-- Projects save the Color Theme; the Sidebar draws with the saved one.
local function apply_color_theme()
  local name = color_theme.saved_name()
  local ok, err = pcall(color_theme.load_style, name)
  if not ok then
    core.log_quiet("Sidebar Color Theme %s failed: %s", name, tostring(err))
    color_theme.load_style("dark")
  end
  for _, surface in pairs(surfaces) do surface.redraw = true end
  core.redraw = true
  -- The shell draws an empty Project area and its Window controls in these colours.
  local delivered = system.set_shell_colors(color_theme.shell_colors(require "core.style"))
  core.log_quiet("Sidebar Color Theme: %s shell_colors=%s", name, tostring(delivered))
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
  load_collapsed()
  apply_color_theme()
  SidebarView = require "core.sidebar_view"
  style = require "core.style"
  -- Terminal titles carry spinners and symbols the text font lacks. The editor's fallbacks draw them.
  local font_fallbacks = require "core.font_fallbacks"
  font = font_fallbacks.group(style.font, font_fallbacks.load(style.font:get_size(), "Sidebar"))
  -- A blended surface keeps one alpha per pixel. Subpixel text would lose the backdrop in some channels and show
  -- dark coloured outlines over a bright wallpaper. Copies at other scales keep this antialiasing.
  if system.is_surface_transparent() then
    font = font:copy(font:get_size(), {antialiasing = "grayscale"})
    style.font = font
    core.log_quiet("Sidebar font uses grayscale antialiasing on a transparent surface")
  end
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
    core.log_quiet("Sidebar press: Window=%d button=%s x=%d y=%d", current.id, button, x, y)
    local width, height = renwindow.get_size(core.window)
    current.view:set_size(width, height)
    current.view:on_mouse_pressed(button, x, y); core.redraw = true
  elseif name == "mousemoved" then
    local x, y = ...
    local width, height = renwindow.get_size(core.window)
    current.view:set_size(width, height)
    if current.view:on_mouse_moved(x, y) then core.redraw = true end
    current.pointer_y = y
  elseif name == "mouseleft" then
    current.pointer_y = nil
    if current.view:on_mouse_left() then core.redraw = true end
  elseif name == "mousewheel" then
    local _, height = renwindow.get_size(core.window)
    current.view:on_mouse_wheel((...), height, current.pointer_y); core.redraw = true
  elseif name == "resized" or name == "exposed" or name == "displaychanged" then
    if name == "resized" then
      local width, height = renwindow.get_size(core.window)
      local configured_w, configured_h = ...
      core.log_quiet("Sidebar surface resized: configured=%sx%s surface=%dx%d",
        tostring(configured_w), tostring(configured_h), width, height)
    end
    core.redraw = true
  end
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
    if event[1] == "colorthemechanged" then
      apply_color_theme()
    elseif event[1] == "projectsidebarchanged" and not native_id then
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
  local pending, spin_at = false, nil
  for id, surface in pairs(surfaces) do
    if activate(id) then
      local visible, now = system.window_should_render(core.window), system.get_time()
      if core.project_sidebar_request and now - core.project_sidebar_request.started >= 5 then
        core.project_sidebar_request = nil
        surface.query_needed = true
        core.log_quiet("Sidebar snapshot timed out: Window=%d", id)
      end
      if visible and surface.query_needed and core.request_project_sidebar() then
        surface.query_needed = false
      end
      -- Ages tick each minute, and Projects move between groups as they age.
      if visible and surface.view:refresh_ages() then core.redraw = true end
      if core.project_sidebar and surface.revision ~= core.project_sidebar.revision then
        surface.revision = core.project_sidebar.revision
        surface.view:set_model(core.project_sidebar, id); core.redraw = true
      end
      -- A working Terminal's spinner turns between the host's title reports.
      if visible and surface.spin_at and now >= surface.spin_at then core.redraw = true end
      if visible and core.redraw then
        local width, height = renwindow.get_size(core.window)
        renderer.begin_frame(core.window)
        surface.view:draw(width, height)
        renderer.end_frame()
        core.redraw = false
        local delay = surface.view:animation_delay(now)
        surface.spin_at = delay and now + delay
      end
      if not visible then surface.spin_at = nil end
      if surface.spin_at then spin_at = math.min(spin_at or math.huge, surface.spin_at) end
      pending = pending or core.project_sidebar_request ~= nil
      save()
    end
  end
  -- Keep fonts only for scales still used by a live surface. Activation never resizes them.
  local used = {}
  for _, surface in pairs(surfaces) do used[surface.scale] = true end
  for scale in pairs(fonts) do if not used[scale] then fonts[scale] = nil end end
  -- Wake each minute so ages stay current.
  if pending then system.wait_event(.01)
  elseif spin_at then system.wait_event(math.max(0, spin_at - system.get_time()))
  else system.wait_event(60 - os.time() % 60) end
  return true
end
return core
