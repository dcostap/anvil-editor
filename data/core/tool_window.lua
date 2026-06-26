-- mod-version:3
-- Project-owned secondary window management for large singleton tools.

local common = require "core.common"
local keymap = require "core.keymap"
local ime = require "core.ime"
local RootPanel = require "core.rootpanel"

local tool_window = {
  windows = {},
  windows_by_id = {},
}

local function project_key(project)
  if type(project) == "table" then
    return project.path or tostring(project)
  end
  return tostring(project or "")
end

local function key_for(project, kind)
  return project_key(project) .. "\0" .. tostring(kind)
end

local function call_root_event(root, type, ...)
  if type == "textinput" then
    return root:on_text_input(...)
  elseif type == "mousemoved" then
    return root:on_mouse_moved(...)
  elseif type == "mousepressed" then
    return root:on_mouse_pressed(...)
  elseif type == "mousereleased" then
    return root:on_mouse_released(...)
  elseif type == "mouseleft" then
    return root:on_mouse_left(...)
  elseif type == "mousewheel" then
    return root:on_mouse_wheel(...)
  elseif type == "touchpressed" then
    return root:on_touch_pressed(...)
  elseif type == "touchreleased" then
    return root:on_touch_released(...)
  elseif type == "touchmoved" then
    return root:on_touch_moved(...)
  elseif type == "filedropped" then
    return root:on_file_dropped(...)
  elseif type == "focuslost" then
    return root:on_focus_lost(...)
  elseif type == "windowclose" then
    return true
  elseif type == "keypressed" then
    if ime.editing then return false end
    return keymap.on_key_pressed(...)
  elseif type == "keyreleased" then
    keymap.on_key_released(...)
    return true
  elseif type == "textediting" then
    local text, start, len = ...
    if ime.editing or #(text or "") > 0 then
      root:on_ime_text_editing(ime.ingest(text, start, len))
    end
    return true
  end
end

local function window_id(window)
  return window and system.get_window_id and system.get_window_id(window)
end

local ToolWindow = {}
ToolWindow.__index = ToolWindow

local function active_leaf_view(node)
  if not node then return nil end
  if node.type == "leaf" then return node.active_view or node.views and node.views[1] end
  return active_leaf_view(node.a) or active_leaf_view(node.b)
end

function ToolWindow:get_state()
  return {
    project_key = self.project_key,
    kind = self.kind,
    hidden = self.hidden,
    bounds = self.bounds,
    state = self.state,
  }
end

function ToolWindow:raise()
  if self.window and system.raise_window then pcall(system.raise_window, self.window) end
  self.hidden = false
  return self
end

function ToolWindow:hide()
  self.hidden = true
  local core = require "core"
  local owns_active_view = self.root and self.root.root_node
    and self.root.root_node.get_node_for_view
    and self.root.root_node:get_node_for_view(core.active_view) ~= nil
  if self.window and system.text_input then pcall(system.text_input, self.window, false) end
  if self.window and system.set_window_visible then pcall(system.set_window_visible, self.window, false) end
  if (self.window and core.active_window == self.window) or owns_active_view then
    local restore_last_active_view = core.last_active_view
    local app_root_panel = core.tool_window_main_root_panel or core.root_panel
    if app_root_panel == self.root then app_root_panel = nil end
    local main_node = app_root_panel and app_root_panel.get_main_panel and app_root_panel:get_main_panel()
    local fallback_view = main_node and main_node.active_view or nil
    if fallback_view then
      local previous_event_window = core.event_window
      core.active_window = core.window
      core.event_window = core.window
      core.set_active_view(fallback_view)
      core.event_window = previous_event_window
      core.last_active_view = restore_last_active_view
    else
      core.active_window = core.window
    end
  end
  return self
end

function ToolWindow:activate_root()
  local core = require "core"
  local view = active_leaf_view(self.root and self.root.root_node)
  if view then
    local previous_event_window = core.event_window
    core.event_window = self.window
    core.set_active_view(view)
    core.event_window = previous_event_window
  elseif self.root and self.root.root_node then
    core.active_window = self.window
  end
  return view
end

function ToolWindow:show()
  self.hidden = false
  if self.window and system.set_window_visible then pcall(system.set_window_visible, self.window, true) end
  self:activate_root()
  return self:raise()
end

function ToolWindow:handle_event(type, ...)
  local core = require "core"
  local previous_event_window = core.event_window
  core.event_window = self.window
  self.last_event = { type, ... }
  local ok, result = pcall(function(...)
    if type == "windowclose" then
      self:hide()
      return true
    end
    if type == "focusgained" then
      self:activate_root()
      return true
    end
    if type == "keypressed" or type == "keyreleased" or type == "textinput" or type == "textediting" then
      self:activate_root()
    end
    if self.on_event then
      local handled = self:on_event(type, ...)
      if handled ~= nil then return handled end
    end
    if type == "keypressed" then
      local previous_root_panel = core.root_panel
      core.tool_window_main_root_panel = previous_root_panel
      core.root_panel = self.root
      local ok, handled = pcall(call_root_event, self.root, type, ...)
      core.root_panel = previous_root_panel
      core.tool_window_main_root_panel = nil
      if not ok then error(handled, 0) end
      return handled
    end
    return call_root_event(self.root, type, ...)
  end, ...)
  core.event_window = previous_event_window
  if not ok then error(result, 0) end
  return result
end

function ToolWindow:sync_root_size()
  if not self.window or not self.root or not self.window.get_size then return end
  local ok, width, height = pcall(self.window.get_size, self.window)
  if ok and width and height then
    self.root.size.x, self.root.size.y = width, height
  end
end

function ToolWindow:update()
  self:sync_root_size()
  if self.root and self.root.update then self.root:update() end
  if self.on_update then self:on_update() end
end

function ToolWindow:draw()
  if self.hidden or not self.window then return end
  local core = require "core"
  local renderer = renderer
  self:sync_root_size()
  local width, height = self.root.size.x, self.root.size.y
  local old_clip_stack = core.clip_rect_stack
  core.clip_rect_stack = { { 0, 0, width, height } }
  renderer.begin_frame(self.window)
  renderer.set_clip_rect(0, 0, width, height)
  self.root:draw()
  renderer.end_frame()
  core.clip_rect_stack = old_clip_stack
end

function tool_window.open(project, kind, opts)
  opts = opts or {}
  local key = key_for(project, kind)
  local existing = tool_window.windows[key]
  if existing then return existing:show(), false end

  local title = opts.title or tostring(kind)
  local window = opts.window
    or (opts.create_window and opts.create_window(title, opts.width or 900, opts.height or 700))
    or renwindow.create(title, opts.width or 900, opts.height or 700)
  local root = opts.root or (opts.create_root and opts.create_root()) or RootPanel()
  local id = opts.window_id or window_id(window)
  local tw = setmetatable({
    project = project,
    project_key = project_key(project),
    kind = kind,
    key = key,
    title = title,
    window = window,
    window_id = id,
    root = root,
    hidden = false,
    state = opts.state or {},
    bounds = opts.bounds,
    on_event = opts.on_event,
    on_update = opts.on_update,
  }, ToolWindow)
  tool_window.windows[key] = tw
  if id then tool_window.windows_by_id[id] = tw end
  tw:show()
  return tw, true
end

function tool_window.get(project, kind)
  return tool_window.windows[key_for(project, kind)]
end

function tool_window.hide(project, kind)
  local tw = tool_window.get(project, kind)
  if tw then tw:hide() end
  return tw
end

function tool_window.remove(project, kind)
  local key = key_for(project, kind)
  local tw = tool_window.windows[key]
  if not tw then return nil end
  tool_window.windows[key] = nil
  if tw.window_id then tool_window.windows_by_id[tw.window_id] = nil end
  return tw
end

function tool_window.by_window_id(id)
  return id and tool_window.windows_by_id[id] or nil
end

function tool_window.handle_event(window_id, type, ...)
  tool_window.last_did_keymap = false
  local tw = tool_window.by_window_id(window_id)
  if not tw then return false end
  if tw.hidden then return true end
  local result = tw:handle_event(type, ...)
  if type == "keypressed" then tool_window.last_did_keymap = result == true end
  return true
end

function tool_window.update_all()
  for _, tw in pairs(tool_window.windows) do
    if not tw.hidden then tw:update() end
  end
end

function tool_window.draw_all()
  for _, tw in pairs(tool_window.windows) do
    if not tw.hidden then tw:draw() end
  end
end

function tool_window.reset_for_tests()
  local core = require "core"
  for _, tw in pairs(tool_window.windows) do
    if tw.window and system.text_input then pcall(system.text_input, tw.window, false) end
    if tw.window and system.set_window_visible then pcall(system.set_window_visible, tw.window, false) end
  end
  tool_window.windows = {}
  tool_window.windows_by_id = {}
  core.active_window = core.window
  core.event_window = core.window
end

return tool_window
