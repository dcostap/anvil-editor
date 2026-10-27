-- One disposable frontend serves independent Sidebar surfaces in the shell's Windows.
local core = require "core"
local saved_event = core.on_event
local surfaces, current = {}, nil
-- The Window whose Sidebar asked for the open menu. The menu's result goes to that surface.
local menu_surface
local SidebarView, font, base_font_size
local fonts, style = {}, nil
local color_theme = require "core.color_theme"
local storage = require "core.storage"
local zoom = require "core.zoom"
local keymap = require "core.keymap"
local command = require "core.command"
local common = require "core.common"
-- The Sidebar draws at each Window's display scale times the interface Zoom that Projects save.
local interface_zoom = 1
local function set_zoom(interface)
  interface_zoom = interface
  core.log_quiet("Sidebar Zoom: interface=%.4f", interface_zoom)
end
-- Storage reports a failed read through core.log, which needs editor styles that the Sidebar does not load.
local function load_zoom()
  local ok, interface = pcall(zoom.load)
  if ok then set_zoom(interface) else core.log_quiet("Sidebar Zoom not loaded: %s", tostring(interface)) end
end

-- Each persistent Window ID owns its Project and group folds. Sidebar recovery uses the same tables.
local collapsed = {}
local function load_collapsed()
  local ok, saved = pcall(storage.load, "sidebar", "folding")
  if ok and type(saved) == "table" then
    for id, folds in pairs(saved) do
      if type(id) == "number" and type(folds) == "table" then
        collapsed[id] = {}
        for key, value in pairs(folds) do
          if type(key) == "string" and type(value) == "boolean" then collapsed[id][key] = value end
        end
      end
    end
  end
  core.log_quiet("Sidebar collapse state: %s", ok and saved and "loaded" or "defaults")
end
local function save_collapsed()
  -- Retain every live Window, including hidden surfaces not yet created by this frontend.
  local live = {}
  for _, window in ipairs((core.project_sidebar or {}).windows or {}) do live[window.id] = true end
  for id in pairs(surfaces) do live[id] = true end
  for id in pairs(collapsed) do if not live[id] then collapsed[id] = nil end end
  local ok, saved, err = pcall(storage.save, "sidebar", "folding", collapsed)
  if not ok or not saved then core.log_quiet("Sidebar folding not saved: %s", tostring(ok and err or saved)) end
end

-- When the user last looked at each Terminal Session, so an Unread Result stays unread in every Window and in
-- the next Sidebar process.
local seen = {}
local function load_seen()
  local ok, saved = pcall(storage.load, "sidebar", "seen")
  if ok and type(saved) == "table" then
    for session, time in pairs(saved) do
      if type(session) == "string" and type(time) == "number" then seen[session] = time end
    end
  end
  core.log_quiet("Sidebar seen times: %s", ok and saved and "loaded" or "none")
end
local function live_sessions()
  local live = {}
  for _, project in ipairs(core.project_sidebar or {}) do
    for _, terminal in ipairs(project.terminals or {}) do live[terminal.id] = true end
  end
  return live
end
-- Saves the times of the Terminal Sessions that still exist.
local function save_seen()
  local live = live_sessions()
  local pruned = 0
  for session in pairs(seen) do
    if not live[session] then seen[session], pruned = nil, pruned + 1 end
  end
  local ok, err = pcall(storage.save, "sidebar", "seen", seen)
  if not ok then core.log_quiet("Sidebar seen times not saved: %s", tostring(err)) end
  return pruned
end

-- The time at which each Terminal Session needs the user again, in Unix seconds, so a Reminder survives restarts,
-- sleep and a new Sidebar process.
local reminders = {}
local function load_reminders()
  local ok, saved = pcall(storage.load, "sidebar", "reminders")
  if ok and type(saved) == "table" then
    for session, time in pairs(saved) do
      if type(session) == "string" and type(time) == "number" then reminders[session] = time end
    end
  end
  core.log_quiet("Sidebar Reminders: %s", ok and saved and "loaded" or "none")
end
-- A Reminder whose time has not come stays, even when the model does not list its Terminal Session yet.
local function save_reminders()
  local live, now, pruned = live_sessions(), os.time(), 0
  for session, time in pairs(reminders) do
    if not live[session] and time <= now then reminders[session], pruned = nil, pruned + 1 end
  end
  local ok, err = pcall(storage.save, "sidebar", "reminders", reminders)
  if not ok then core.log_quiet("Sidebar Reminders not saved: %s", tostring(err)) end
  return pruned
end

-- The shell lists recent Projects from a source that a Project publishes. Windows can all be empty after a
-- restart, so the Sidebar publishes the saved recent Projects itself. A later Project replaces them.
local function publish_recents()
  local ok, app_state = pcall(dofile, USERDIR .. PATHSEP .. "appstate.lua")
  local recents = {}
  if ok and type(app_state) == "table" and type(app_state.recents) == "table" then
    for _, path in ipairs(app_state.recents) do
      if type(path) == "string" and #recents < 256 then recents[#recents + 1] = path end
    end
  end
  local sent = system.publish_project_sidebar(USERDIR, require("core.common").serialize(recents))
  core.log_quiet("Sidebar recent source: Projects=%d sent=%s", #recents, tostring(sent))
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
  local scale = system.get_scale(surface.window) * interface_zoom
  SCALE = scale
  if font then
    if not fonts[scale] then
      fonts[scale] = font:copy(base_font_size * scale)
      core.log_quiet("Sidebar font created: scale=%g", scale)
    end
    style.font = fonts[scale]
  end
  if surface.scale ~= scale then
    surface.view.scroll = surface.view.scroll * scale / surface.scale
    surface.scale, core.redraw = scale, true
    -- Row heights follow the font and SCALE.
    surface.view:rebuild_rows()
    core.log_quiet("Sidebar scale: Window=%d scale=%g", id, scale)
    -- The Sidebar can wait a minute for its next event. Scale changes are rare, so the log shows them at once.
    if core.session_log then core.session_log:flush() end
  end
  return true
end
local function add_surface(id, window)
  collapsed[id] = collapsed[id] or {}
  local surface = {id = id, window = window, native_id = system.get_window_id(window), scale = system.get_scale(window),
    redraw = true, query_needed = true}
  surface.view = SidebarView(function(action, row_id, target, ...)
    if action == "return_focus" then
      core.log_quiet("Sidebar return focus: Window=%d", id)
      system.focus_project_sidebar(false)
      return
    end
    if action == "collapsed" then
      core.log_quiet("Sidebar group %s collapsed=%s Window=%d", row_id, tostring(target), id)
      save_collapsed()
      return
    end
    if action == "seen" or action == "reminder" then
      if action == "seen" then
        core.log_quiet("Sidebar result read: Window=%d session=%s pruned=%d", id, row_id, save_seen())
      else
        core.log_quiet("Sidebar Reminder saved: Window=%d session=%s pruned=%d", id, row_id, save_reminders())
      end
      -- Other surfaces show the same result. It is read there too.
      for _, other in pairs(surfaces) do
        if other ~= surface then other.view:rebuild_rows(); other.redraw = true end
      end
      return
    end
    if action == "request" then
      local route, path, request, x, y = row_id, target, ...
      -- Focusing a Pane gives the keyboard back to the Project. The shell gets both messages in this order.
      if request.action == "focus" or request.action == "new_group" or request.action == "command" then
        system.focus_project_sidebar(false)
      end
      local text = common.serialize(request, {escape = true})
      local sent = system.pane_request(route, path, text, x, y)
      -- A drag over the work area sends a request for each pointer move. Log only its end.
      if request.phase ~= "move" or not sent then
        core.log_quiet("Sidebar Pane request: Window=%d route=%s Project=%s action=%s pane=%s bytes=%d sent=%s",
          id, route, tostring(path), request.action, tostring(request.pane), #text, tostring(sent))
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
    if action == "show_menu" then
      local x, y, labels = row_id, target, ...
      menu_surface = id
      local sent = system.show_menu(x, y, labels)
      core.log_quiet("Sidebar menu: Window=%d labels=%d sent=%s", id, #labels, tostring(sent))
      if not sent then menu_surface = nil; surface.view:on_menu_chosen(0) end
      return
    end
    if action == "focus" then
      local sent = system.focus_project_sidebar(true)
      core.log_quiet("Sidebar takes the keyboard: Window=%d sent=%s", id, tostring(sent))
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
        elseif action == "unload" then
          local sent = system.unload_project(project.path)
          core.log_quiet("Sidebar unload: Window=%d Project=%d sent=%s", id, project.id or 0, tostring(sent))
        end
        return
      end
    end
    core.log_quiet("Sidebar %s dropped: Window=%d row=%s is not in the model (%d rows)", action, id,
      tostring(row_id), #(core.project_sidebar or {}))
  end, collapsed[id], seen, true, reminders)
  surfaces[id] = surface
  core.log_quiet("Sidebar surface created: Window=%d", id)
end
-- Projects save the Color Theme; the Sidebar draws with the saved one, or with a Project's unsaved preview.
local function apply_color_theme(preview)
  local name = color_theme.saved_name()
  local ok, err
  if preview then
    ok, err = pcall(color_theme.load_preview, preview)
    if ok then name = err .. " (preview)" end
  end
  if not ok then
    if preview then core.log_quiet("Sidebar Color Theme preview failed: %s", tostring(err)) end
    ok, err = pcall(color_theme.load_style, name)
  end
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
  -- Keep Project actions, list navigation, and line editing shortcuts for the search field.
  local ok, settings = pcall(dofile, USERDIR .. "/user_settings.lua")
  local saved_config = ok and type(settings) == "table" and settings.config
  local custom = type(saved_config) == "table" and saved_config.custom_keybindings
  local function bindings_for(name)
    local saved = type(custom) == "table" and custom[name]
    return type(saved) == "table" and saved or keymap.get_bindings(name) or {}
  end
  local bindings = bindings_for("core:focus_project_sidebar")
  local new_group_bindings = bindings_for("pane:new_group")
  local close_pane_bindings = bindings_for("pane:close")
  local pane_bindings = {}
  for name in pairs(require "core.sidebar_commands") do pane_bindings[name] = bindings_for(name) end
  local LineInput, line_bindings = require "core.line_input", {}
  for _, name in ipairs(LineInput.COMMANDS) do line_bindings[name] = bindings_for("core:" .. name) end
  local numbered_panes, number_bindings = require "core.numbered_panes", {}
  for number = 1, numbered_panes.COUNT do
    number_bindings[number] = bindings_for("pane:focus_number_" .. number)
  end
  keymap.map, keymap.reverse_map = {}, {}
  command.add(nil, {
    ["core:focus_project_sidebar"] = function() system.focus_project_sidebar(false) end,
    ["pane:new_group"] = function() return current ~= nil and current.view:new_group() end,
    ["pane:close"] = function() return current ~= nil and current.view:close_pane() end,
  })
  for _, binding in ipairs(bindings) do keymap.add {[binding] = "core:focus_project_sidebar"} end
  for _, binding in ipairs(new_group_bindings) do keymap.add {[binding] = "pane:new_group"} end
  for _, binding in ipairs(close_pane_bindings) do keymap.add {[binding] = "pane:close"} end
  for name, keys in pairs(pane_bindings) do
    command.add(nil, {[name] = function()
      return current ~= nil and current.view:perform_pane_command(name)
    end})
    for _, binding in ipairs(keys) do keymap.add {[binding] = name} end
  end
  -- Numbered Panes can be in any Project. Focusing one gives the keyboard back to the Projects.
  for number = 1, numbered_panes.COUNT do
    local name = "pane:focus_number_" .. number
    command.add(nil, {[name] = function()
      local item, stamped = numbered_panes.target(core.project_sidebar, number, seen, reminders)
      if not item then
        core.log_quiet("Sidebar Numbered Pane %d: none of %d pending Panes", number, stamped)
        return false
      end
      system.focus_project_sidebar(false)
      local sent = numbered_panes.request(item.path, item.id)
      core.log_quiet("Sidebar Numbered Pane %d: Project=%s pane=%s sent=%s", number, item.path, tostring(item.id),
        tostring(sent))
    end})
    for _, binding in ipairs(number_bindings[number]) do keymap.add {[binding] = name} end
  end
  for _, key in ipairs {"up", "down", "left", "right", "home", "end", "return", "keypad enter", "escape"} do
    local name = "sidebar:" .. key:gsub(" ", "_")
    command.add(nil, {[name] = function()
      if current then current.view:on_key_pressed(key, current.key_repeat) end
    end})
    keymap.add {[key] = name}
  end
  -- Added last, so they go first. Without a query they decline, and Left, Right, Home and End move through the list.
  for _, name in ipairs(LineInput.COMMANDS) do
    local sidebar_name = "sidebar:" .. name
    command.add(function()
      return current ~= nil and current.view:edits(name)
    end, {[sidebar_name] = function() current.view:edit(name) end})
    for _, binding in ipairs(line_bindings[name]) do keymap.add {[binding] = sidebar_name} end
  end
  keymap.add {["alt+r"] = "sidebar:return"}
  if core.session_log then core.session_log:flush() end
  local window = renwindow.create("Sidebar", 240, 600)
  core.window, core.active_window = window, window
  SCALE = system.get_scale(window)
  load_collapsed()
  load_seen()
  load_reminders()
  load_zoom()
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
  publish_recents()
end
function core.run() end
function core.on_event(name, ...)
  if name == "quit" or name == "shelllost" then core.quit_request = true; return end
  if not current then return end
  if name == "projectsidebarchanged" then
    core.project_sidebar_request = nil
    current.query_needed = true
  elseif name == "projectsidebar" then saved_event(name, ...)
  elseif name == "menuchosen" then
    core.log_quiet("Sidebar menu result: Window=%d choice=%d", current.id, (...))
    current.view:on_menu_chosen(...)
    core.redraw = true
  elseif name == "focusgained" or name == "focuslost" then
    keymap.modkeys = {}
    current.suppress_text = false
    current.view:on_focus(name == "focusgained")
    core.log_quiet("Sidebar keyboard focus: Window=%d focused=%s", current.id, tostring(current.view.focused))
    core.redraw = true
  elseif name == "keypressed" then
    local _, info = ...
    current.key_repeat = info and info["repeat"] == true
    current.suppress_text = keymap.on_key_pressed(...)
    core.redraw = true
  elseif name == "keyreleased" then
    keymap.on_key_released(...)
  elseif name == "textinput" then
    if not current.suppress_text then current.view:on_text_input(...) end
    core.redraw = true
  elseif name == "mousepressed" then
    local button, x, y = ...
    core.log_quiet("Sidebar press: Window=%d button=%s x=%d y=%d", current.id, button, x, y)
    local width, height = renwindow.get_size(core.window)
    current.view:set_size(width, height)
    current.view:on_mouse_pressed(button, x, y); core.redraw = true
  elseif name == "mousereleased" then
    local button, x, y = ...
    core.log_quiet("Sidebar release: Window=%d button=%s x=%d y=%d drag=%s", current.id, button, x, y,
      tostring(current.view.drag ~= nil))
    current.view:on_mouse_released(button, x, y); core.redraw = true
  elseif name == "mousemoved" then
    local x, y = ...
    local width, height = renwindow.get_size(core.window)
    current.view:set_size(width, height)
    if current.view:on_mouse_moved(x, y) then core.redraw = true end
    current.pointer_y = y
  elseif name == "mouseleft" then
    current.pointer_y = nil
    if current.view:on_mouse_left() then core.redraw = true end
    -- The shell shows the Project's cursor outside the Sidebar.
    current.cursor = nil
  elseif name == "dropbegin" then
    current.view:on_drop_begin()
  elseif name == "dropmoved" then
    current.view:on_drop_moved(...); core.redraw = true
  elseif name == "filedropped" then
    local filename, x, y = ...
    current.view:on_file_dropped(system.absolute_path(filename) or filename, x, y)
  elseif name == "textdropped" then
    current.view:on_text_dropped(...)
  elseif name == "dropcomplete" then
    local taken = current.view:on_drop_complete()
    core.log_quiet("Sidebar drop: Window=%d taken=%s", current.id, tostring(taken))
    core.redraw = true
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
  if name:find("^mouse") and name ~= "mouseleft" then
    local cursor = current.view:pointer_cursor()
    if cursor ~= current.cursor then
      current.cursor = cursor
      system.set_cursor(cursor)
    end
  end
  save()
end
function core.run_step()
  sync_surfaces()
  -- A Theme Editor drag sends many previews. Only the latest one in this step matters.
  local theme_change
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
      theme_change = {}
    elseif event[1] == "colorthemepreview" then
      theme_change = {preview = event[2] ~= "" and event[2] or nil}
    elseif event[1] == "zoomchanged" then
      -- Each surface takes the new scale when it next activates.
      set_zoom(event[2])
    elseif event[1] == "menuchosen" then
      -- The result has no Window. It goes to the surface that asked for the menu.
      local id = menu_surface
      menu_surface = nil
      if id and activate(id) then core.on_event(table.unpack(event, 1, event.n)) end
    elseif event[1] == "projectsidebarchanged" and not native_id then
      for _, surface in pairs(surfaces) do surface.request, surface.query_needed = nil, true end
      core.project_sidebar_request = nil
    elseif activate(id) or event[1] == "quit" or event[1] == "shelllost" then
      core.on_event(table.unpack(event, 1, event.n))
    end
  end
  if theme_change then apply_color_theme(theme_change.preview) end
  sync_surfaces()
  if core.quit_request then
    if core.session_log then core.session_log:close(); core.session_log = nil end
    return false
  end
  local pending, spin_at, next_reminder = false, nil, nil
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
      if surface.view.next_reminder then
        next_reminder = math.min(next_reminder or math.huge, surface.view.next_reminder)
      end
      pending = pending or core.project_sidebar_request ~= nil
      save()
    end
  end
  -- Keep fonts only for scales still used by a live surface. Activation never resizes them.
  local used = {}
  for _, surface in pairs(surfaces) do used[surface.scale] = true end
  for scale in pairs(fonts) do if not used[scale] then fonts[scale] = nil end end
  -- Wake each minute so ages stay current, and when a Reminder comes due. The wait can stop counting while the
  -- computer sleeps, so each wake compares Reminders with the clock again.
  local minute = 60 - os.time() % 60
  if next_reminder then minute = math.max(0, math.min(minute, next_reminder - os.time())) end
  if pending then system.wait_event(.01)
  elseif spin_at then system.wait_event(math.max(0, math.min(minute, spin_at - system.get_time())))
  else system.wait_event(minute) end
  return true
end
return core
