local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local layout = require "core.pane_layout"

local RootPanel = View:extend()

local APP_OVERLAY_FADE_DURATION = 0.08
local DIVIDER_TOLERANCE = 4

function RootPanel:__tostring() return "RootPanel" end

local function panes()
  return core.panes or require "core.panes"
end

local function call_view(view, name, ...)
  local method = view and view[name]
  if not method then return nil end
  if view.with_selection_state then
    return view:with_selection_state(method, view, ...)
  end
  return method(view, ...)
end

local function point_in_view(view, x, y)
  return view and x >= view.position.x and y >= view.position.y
    and x < view.position.x + view.size.x
    and y < view.position.y + view.size.y
end

local function set_rect(view, x, y, w, h)
  if not view then return end
  view.position.x, view.position.y = x, y
  view.size.x, view.size.y = w, h
end

function RootPanel:new()
  RootPanel.super.new(self)
  self.mouse = { x = 0, y = 0 }
  self.deferred_draws = {}
  self.app_overlay = nil
  self.grab = nil
  self.overlapping_view = nil
  self.touched_view = nil
  self.dragged_divider = nil
  self.content_rect = { x = 0, y = 0, w = 0, h = 0 }
end

function RootPanel:defer_draw(fn, ...)
  table.insert(self.deferred_draws, 1, { fn = fn, ... })
end

local function quadratic_ease_in_out(progress)
  if progress < 0.5 then return 2 * progress * progress end
  local remaining = 1 - progress
  return 1 - 2 * remaining * remaining
end

function RootPanel:update_app_overlay(now)
  local overlay = self.app_overlay
  if not overlay then return 0 end
  now = now or system.get_time()
  local transition_disabled = not config.transitions
    or (overlay.transition_name and config.disabled_transitions[overlay.transition_name])
    or (overlay.transition_name == "global_prompt_bar" and config.disabled_transitions.commandview)
    or core.in_live_resize_frame
    or (core.fps or config.fps) < 30
  local progress = overlay.progress
  if transition_disabled then
    progress = overlay.target
  elseif overlay.target ~= progress then
    local elapsed = math.max(0, now - overlay.last_time)
    local direction = overlay.target > progress and 1 or -1
    progress = common.clamp(progress + direction * elapsed / APP_OVERLAY_FADE_DURATION, 0, 1)
  end
  overlay.last_time = now
  if progress ~= overlay.progress then overlay.progress, core.redraw = progress, true end
  if overlay.target == 0 and progress == 0 then self.app_overlay = nil end
  return progress
end

function RootPanel:show_app_overlay(owner, color, options)
  assert(owner ~= nil, "app overlay owner is required")
  options = options or {}
  local now = system.get_time()
  self:update_app_overlay(now)
  local overlay = self.app_overlay
  if not overlay then
    overlay = { progress = 0, target = 0, last_time = now }
    self.app_overlay = overlay
  end
  overlay.owner = owner
  overlay.color = color
  overlay.unobscured_view = options.unobscured_view
  overlay.transition_name = options.transition_name
  overlay.target = 1
  overlay.last_time = now
  core.redraw = true
end

function RootPanel:hide_app_overlay(owner)
  local overlay = self.app_overlay
  if not overlay or overlay.owner ~= owner then return false end
  local now = system.get_time()
  self:update_app_overlay(now)
  overlay = self.app_overlay
  if not overlay or overlay.owner ~= owner then return false end
  overlay.target = 0
  overlay.unobscured_view = nil
  overlay.last_time = now
  core.redraw = true
  return true
end

function RootPanel:draw_app_overlay(color, unobscured_view)
  local left, top = self.position.x, self.position.y
  local right, bottom = left + self.size.x, top + self.size.y
  if not unobscured_view then
    renderer.draw_rect(left, top, self.size.x, self.size.y, color)
    return
  end
  local view_left = common.clamp(unobscured_view.position.x, left, right)
  local view_top = common.clamp(unobscured_view.position.y, top, bottom)
  local view_right = common.clamp(unobscured_view.position.x + unobscured_view.size.x, left, right)
  local view_bottom = common.clamp(unobscured_view.position.y + unobscured_view.size.y, top, bottom)
  if view_top > top then renderer.draw_rect(left, top, self.size.x, view_top - top, color) end
  if view_bottom < bottom then renderer.draw_rect(left, view_bottom, self.size.x, bottom - view_bottom, color) end
  if view_left > left and view_bottom > view_top then
    renderer.draw_rect(left, view_top, view_left - left, view_bottom - view_top, color)
  end
  if view_right < right and view_bottom > view_top then
    renderer.draw_rect(view_right, view_top, right - view_right, view_bottom - view_top, color)
  end
end

function RootPanel:draw_active_app_overlay()
  local overlay = self.app_overlay
  if not overlay or overlay.progress <= 0 then return end
  local source = type(overlay.color) == "string" and style[overlay.color] or overlay.color
  if type(source) ~= "table" then return end
  local color = { table.unpack(source) }
  color[4] = (color[4] or 255) * quadratic_ease_in_out(overlay.progress)
  self:draw_app_overlay(color, overlay.unobscured_view)
end

function RootPanel:shell_views()
  return { core.title_bar, core.nag_view, core.global_prompt_bar, core.status_bar }
end

function RootPanel:pane_views()
  local group = panes().visible_group()
  if not group then return {} end
  local result = {}
  for _, pane in ipairs(layout.leaves(group.root)) do
    if pane.current_view then result[#result + 1] = pane.current_view end
  end
  return result
end

function RootPanel:children()
  local result = {}
  for _, view in ipairs(self:shell_views()) do if view then result[#result + 1] = view end end
  for _, view in ipairs(self:pane_views()) do result[#result + 1] = view end
  return result
end

function RootPanel:contains_view(view)
  if not view then return false end
  for _, child in ipairs(self:children()) do
    if child == view then return true end
  end
  local owner = panes().owner_for_view(view)
  local pane = owner and panes().pane_for_view(owner)
  return pane ~= nil and panes().is_visible(pane)
end

function RootPanel:view_at(x, y)
  for _, view in ipairs(self:shell_views()) do
    if point_in_view(view, x, y) then return view end
  end
  local group = panes().visible_group()
  local pane = group and layout.pane_at(group.root, x, y)
  return pane and pane.current_view or nil
end

function RootPanel:get_active_pane()
  return panes().active()
end

function RootPanel:open_buffer(buffer, opts)
  opts = opts or {}
  local Editor = require "core.editor"
  local target = panes().find(opts.pane or panes().active())
  if target and (opts.placement == nil or opts.placement == "current") then
    for _, view in ipairs(panes().history_views(target)) do
      if view.extends and view:extends(Editor) and view.buffer == buffer then
        panes().present(view, { pane = target, focus = opts.focus })
        return view
      end
    end
  end
  return panes().place(function() return Editor(buffer) end, {
    pane = opts.pane,
    placement = opts.placement or "current",
    direction = opts.direction,
    focus = opts.focus,
    preserve_focus = opts.preserve_focus,
    reason = opts.reason,
  })
end

function RootPanel:close_all_views(keep_view)
  for i = #panes().ordered(), 1, -1 do
    local pane = panes().ordered()[i]
    if pane.current_view ~= keep_view then panes().close(pane) end
  end
end

function RootPanel:close_all_textviews(keep_active)
  local Editor = require "core.editor"
  local keep = keep_active and panes().active()
  for i = #panes().ordered(), 1, -1 do
    local pane = panes().ordered()[i]
    if pane ~= keep and pane.current_view:is(Editor) then panes().close(pane) end
  end
end

function RootPanel:update_layout()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local title, nag, prompt, status = core.title_bar, core.nag_view, core.global_prompt_bar, core.status_bar

  for _, view in ipairs { title, nag, prompt, status } do
    if view then
      view.position.x, view.size.x = x, w
      call_view(view, "update")
    end
  end

  local title_h = title and title.size.y or 0
  local nag_h = nag and (nag.show_height or nag.size.y) or 0
  local pane_prompt = prompt and prompt.pane_scope and panes().find(prompt.pane_scope)
  local prompt_h = prompt and prompt.size.y or 0
  local global_prompt_h = pane_prompt and 0 or prompt_h
  local status_h = status and status.size.y or 0
  set_rect(title, x, y, w, title_h)
  set_rect(nag, x, y + title_h, w, nag_h)
  set_rect(status, x, y + h - status_h, w, status_h)
  if not pane_prompt then set_rect(prompt, x, y + h - status_h - prompt_h, w, prompt_h) end

  local content_y = y + title_h + nag_h
  local content_h = math.max(0, h - title_h - nag_h - global_prompt_h - status_h)
  self.content_rect = { x = x, y = content_y, w = w, h = content_h }
  local group = panes().visible_group()
  if group then
    layout.update_rects(group.root, self.content_rect)
    for _, pane in ipairs(layout.leaves(group.root)) do
      set_rect(pane.current_view, pane.position.x, pane.position.y, pane.size.x, pane.size.y)
    end
    if pane_prompt and pane_prompt.group == group then
      local bar_h = math.min(prompt_h, pane_prompt.size.y)
      set_rect(prompt, pane_prompt.position.x,
        pane_prompt.position.y + pane_prompt.size.y - bar_h,
        pane_prompt.size.x, bar_h)
      set_rect(pane_prompt.current_view, pane_prompt.position.x, pane_prompt.position.y,
        pane_prompt.size.x, math.max(0, pane_prompt.size.y - bar_h))
    end
  end
end

function RootPanel:update()
  self:update_app_overlay()
  self:update_layout()
  local current = {}
  for _, view in ipairs(self:pane_views()) do
    current[view] = true
    call_view(view, "update")
  end
  local serviced = {}
  for _, pane in ipairs(panes().ordered()) do
    for _, view in ipairs(panes().history_views(pane)) do
      if not current[view] and not serviced[view] and view.update_suspended then
        serviced[view] = true
        call_view(view, "update_suspended")
      end
    end
  end
  self.overlapping_view = self:view_at(self.mouse.x, self.mouse.y)
end

function RootPanel:grab_mouse(button, view)
  self.grab = { button = button, view = view }
end

function RootPanel:ungrab_mouse(button)
  if self.grab and (not button or self.grab.button == button) then self.grab = nil end
end

function RootPanel:on_mouse_pressed(button, x, y, clicks)
  self.mouse.x, self.mouse.y = x, y
  local group = panes().visible_group()
  if button == "left" and group then
    local divider = layout.divider_at(group.root, x, y, DIVIDER_TOLERANCE * SCALE)
    if divider then
      self.dragged_divider = divider
      return true
    end
  end
  local view = self:view_at(x, y)
  self.overlapping_view = view
  local pane = panes().pane_for_view(view)
  if pane then panes().focus(pane) end
  return call_view(view, "on_mouse_pressed", button, x, y, clicks)
end

function RootPanel:on_mouse_released(button, x, y, ...)
  self.mouse.x, self.mouse.y = x, y
  if button == "left" and self.dragged_divider then
    self.dragged_divider = nil
    return true
  end
  local view = self.grab and self.grab.view or self:view_at(x, y)
  local result = call_view(view, "on_mouse_released", button, x, y, ...)
  self:ungrab_mouse(button)
  return result
end

function RootPanel:on_mouse_moved(x, y, dx, dy)
  self.mouse.x, self.mouse.y = x, y
  if self.dragged_divider then
    layout.resize(self.dragged_divider, { x = x, y = y })
    core.redraw = true
    return true
  end
  local view = self.grab and self.grab.view or self:view_at(x, y)
  self.overlapping_view = view
  return call_view(view, "on_mouse_moved", x, y, dx, dy)
end

function RootPanel:on_mouse_left()
  local view = self.overlapping_view
  self.overlapping_view = nil
  return call_view(view, "on_mouse_left")
end

function RootPanel:on_mouse_wheel(...)
  return call_view(self.overlapping_view or self:view_at(self.mouse.x, self.mouse.y), "on_mouse_wheel", ...)
end

function RootPanel:keyboard_target()
  if self:contains_view(core.active_view) then return core.active_view end
  local pane = panes().active()
  return pane and pane.current_view or nil
end

function RootPanel:on_text_input(...)
  return call_view(self:keyboard_target(), "on_text_input", ...)
end

function RootPanel:on_key_pressed(...)
  return call_view(self:keyboard_target(), "on_key_pressed", ...)
end

function RootPanel:on_key_pressed_before_keymap(...)
  return call_view(self:keyboard_target(), "on_key_pressed_before_keymap", ...)
end

function RootPanel:on_key_released(...)
  return call_view(self:keyboard_target(), "on_key_released", ...)
end

function RootPanel:on_ime_text_editing(...)
  return call_view(self:keyboard_target(), "on_ime_text_editing", ...)
end

function RootPanel:on_focus_lost(...)
  return call_view(self:keyboard_target(), "on_focus_lost", ...)
end

function RootPanel:on_touch_pressed(x, y, ...)
  self.touched_view = self:view_at(x, y)
  return call_view(self.touched_view, "on_touch_pressed", x, y, ...)
end

function RootPanel:on_touch_released(x, y, ...)
  local view = self.touched_view
  self.touched_view = nil
  return call_view(view, "on_touch_released", x, y, ...)
end

function RootPanel:on_touch_moved(x, y, ...)
  return call_view(self.touched_view, "on_touch_moved", x, y, ...)
end

function RootPanel:on_file_dropped(filename, x, y)
  local group = panes().visible_group()
  local pane = group and x and y and layout.pane_at(group.root, x, y) or panes().active()
  if core.open_file then
    return core.open_file(filename, { pane = pane, placement = "current", reason = "file-drop" })
  end
end

local function draw_split_dividers(node)
  if not node or node.kind ~= "split" or not node.rect then return end
  local color = style.divider or style.background3 or style.background2
  if node.axis == "x" then
    local x = node.rect.x + node.rect.w * node.ratio
    renderer.draw_rect(x - 1, node.rect.y, 2, node.rect.h, color)
  else
    local y = node.rect.y + node.rect.h * node.ratio
    renderer.draw_rect(node.rect.x, y - 1, node.rect.w, 2, color)
  end
  draw_split_dividers(node.a)
  draw_split_dividers(node.b)
end

function RootPanel:draw()
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, style.background)
  local group = panes().visible_group()
  for _, view in ipairs(self:pane_views()) do call_view(view, "draw") end
  if group then draw_split_dividers(group.root) end
  for _, view in ipairs(self:shell_views()) do call_view(view, "draw") end
  self:draw_active_app_overlay()
  for i = #self.deferred_draws, 1, -1 do
    local item = self.deferred_draws[i]
    item.fn(table.unpack(item, 1, #item))
  end
  self.deferred_draws = {}
end

return RootPanel
