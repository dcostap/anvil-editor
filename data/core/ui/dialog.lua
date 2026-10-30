local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local card = require "core.card"
local ui = require "core.ui"
local Button = require "core.ui.button"

-- A Dialog: a modal card over the Project with a title and controls. It dims the rest of the Window, including a
-- hosted shell's Sidebar, and takes all input while it is open. One Dialog is open at a time.
--
-- A subclass adds its controls with `add`, places them in `layout_content`, and draws its other content in
-- `draw_content`. Tab moves the keyboard focus through the controls. Enter activates the focused control,
-- Escape cancels its edit or closes the Dialog, and a click outside the card closes it.
-- Keys reach the focused control as the editor's commands, with the user's bindings: Up and Down are
-- "move_to_previous_line" and "move_to_next_line", for example. A subclass can take them first in `perform`.
local dialog = {}

-- How fast the card fades in and out, per second.
local SHOW_RATE, HIDE_RATE = 18, 26

-- The Dialogs that show or fade out, oldest first. The last open one takes input.
local shown = {}
local current

local Dialog = View:extend()
dialog.Dialog = Dialog

function Dialog:__tostring() return "Dialog(" .. tostring(self.title) .. ")" end

---@param options { title: string, width: number? } `width` is the card's width at scale 1.
function Dialog:new(options)
  Dialog.super.new(self)
  options = options or {}
  self.title = options.title or ""
  self.width = options.width or 560
  self.controls = {}
  self.progress = 0
  self.is_open = false
  self.rect = { x = 0, y = 0, w = 0, h = 0 }
  self.close_button = self:add(Button({
    icon = ui.icons.close, kind = "ghost", focusable = false,
    on_click = function() self:close() end,
  }))
end

function Dialog:get_name() return self.title end
function Dialog:supports_text_input() return true end

---Add a control. Tab visits the controls in the order they were added.
function Dialog:add(control)
  self.controls[#self.controls + 1] = control
  return control
end

---Sizes in pixels at the current scale.
function Dialog:metrics()
  return {
    pad = math.floor(20 * SCALE + 0.5),
    side = math.floor(24 * SCALE + 0.5),
    radius = math.floor(10 * SCALE + 0.5),
    header_gap = math.floor(14 * SCALE + 0.5),
    top = math.floor(72 * SCALE + 0.5),
  }
end

------------------------------------------------------------------------------------------------------------------
-- Open and close

---Open the Dialog with keyboard focus on `focus`, or on its first control that takes focus.
function Dialog:open(focus)
  if current and current ~= self then current:close() end
  if self.is_open then
    if focus then self:focus(focus) end
    return self
  end
  self.is_open = true
  current = self
  for i = #shown, 1, -1 do
    if shown[i] == self then table.remove(shown, i) end
  end
  shown[#shown + 1] = self
  self.restore_view = core.active_view
  core.root_panel:push_modal_input(self, { label = "dialog" })
  core.set_active_view(self)
  -- Focus stays on the Dialog while it is open. A focus request waits in core.next_active_view.
  self.force_focus = true
  self.focused = nil
  self:layout()
  self:focus(focus or self:focusables()[1])
  core.log_quiet("Dialog opened: %s", self.title)
  core.redraw = true
  return self
end

---Close the Dialog. The focused control gets `on_blur`, so a text field submits its text.
function Dialog:close()
  if not self.is_open then return false end
  self:focus(nil)
  self.is_open = false
  if current == self then current = nil end
  self:release_pointer()
  core.root_panel:pop_modal_input(self)
  self.force_focus = false
  local restore = core.next_active_view or self.restore_view
  core.next_active_view, self.restore_view = nil, nil
  if not (restore and core.root_panel:contains_view(restore)) then restore = core.root_panel:keyboard_target() end
  if core.active_view == self and restore then core.set_active_view(restore) end
  self:on_close()
  core.log_quiet("Dialog closed: %s", self.title)
  core.redraw = true
  return true
end

---Called after the Dialog closes.
function Dialog:on_close() end

---Enter: activate the focused control, or else `on_confirm`.
function Dialog:confirm()
  if self.focused and self.focused:activate() then return true end
  return self:on_confirm()
end

---Enter on a control that does not activate. The default does nothing.
function Dialog:on_confirm() return false end

---Escape: cancel the focused control's edit, or else close the Dialog.
function Dialog:cancel()
  if self.focused and self.focused:cancel() then return true end
  return self:close()
end

------------------------------------------------------------------------------------------------------------------
-- Focus

function Dialog:focusables()
  local result = {}
  for _, control in ipairs(self.controls) do
    if control:can_focus() then result[#result + 1] = control end
  end
  return result
end

---Give `control` keyboard focus, or take focus from all controls with nil.
function Dialog:focus(control)
  if control == self.focused or (control and not control:can_focus()) then return false end
  local previous = self.focused
  self.focused = control
  if previous then previous:on_blur() end
  if control and self.focused == control then control:on_focus() end
  core.redraw = true
  return true
end

---Move keyboard focus to the next control, or the previous one with a negative `delta`.
function Dialog:focus_next(delta)
  local list = self:focusables()
  if #list == 0 then return false end
  local index
  for i, control in ipairs(list) do
    if control == self.focused then index = i end
  end
  index = index and (index - 1 + delta) % #list + 1 or (delta > 0 and 1 or #list)
  return self:focus(list[index])
end

------------------------------------------------------------------------------------------------------------------
-- Input

---Perform the editor command `name`, without its "core:" prefix, on the focused control.
---A subclass can override this to take a command first.
function Dialog:perform(name)
  local control = self.focused
  return control ~= nil and control:perform(name)
end

function Dialog:on_modal_key_pressed(key, event)
  if keymap.is_modifier_key(key) then return "keymap" end
  local stroke = keymap.stroke_for_event(key, event)
  for _, name in ipairs(keymap.map[stroke] or {}) do
    if type(name) == "string" then
      if name:match("^dialog:") then
        if command.perform(name) then return true end
      else
        local editor_command = name:match("^core:(.+)$")
        if editor_command and self:perform(editor_command) then return true end
      end
    end
  end
  local control = self.focused
  local modkeys = keymap.modkeys
  if control and control.takes_text and control.enabled
    and not (modkeys.ctrl or modkeys.alt or modkeys.super or modkeys.cmd) then
    -- The key's text arrives in a later text event.
    return "text"
  end
  return true
end

function Dialog:on_modal_text_input(text)
  local control = self.focused
  if control and control.takes_text then control:on_text(text) end
  return true
end

function Dialog:on_modal_ime_text_editing() return true end
function Dialog:on_modal_key_released() return true end

---The control under a point, or nil.
function Dialog:control_at(x, y)
  for i = #self.controls, 1, -1 do
    local control = self.controls[i]
    if control:contains(x, y) then return control end
  end
end

function Dialog:set_hovered(control)
  for _, other in ipairs(self.controls) do
    local hovered = other == control
    if other.hovered ~= hovered then
      other.hovered = hovered
      core.redraw = true
    end
  end
end

function Dialog:release_pointer()
  if self.pressed_control then self.pressed_control.pressed = false end
  self.pressed_control = nil
  self:set_hovered(nil)
end

local function inside(rect, x, y)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end

function Dialog:on_modal_mouse_moved(x, y)
  self.mouse_x, self.mouse_y = x, y
  local pressed = self.pressed_control
  local over = self:control_at(x, y)
  if pressed then
    self:set_hovered(over == pressed and pressed or nil)
    pressed:on_mouse_moved(x, y)
    core.request_cursor(pressed.cursor)
    return true
  end
  self:set_hovered(over)
  if over then over:on_mouse_moved(x, y) end
  core.request_cursor(over and over.enabled and over.cursor or "arrow")
  return true
end

function Dialog:on_modal_mouse_pressed(button, x, y, clicks)
  if not inside(self.rect, x, y) then
    -- A press beside the card closes the Dialog, as in a Context Menu.
    if button == "left" or button == "right" then self:close() end
    return true
  end
  if button ~= "left" then return true end
  local control = self:control_at(x, y)
  if not (control and control.enabled) then return true end
  if control:can_focus() then self:focus(control) end
  control.pressed = true
  self.pressed_control = control
  control:on_mouse_pressed(x, y, clicks)
  return true
end

function Dialog:on_modal_mouse_released(button, x, y)
  local control = self.pressed_control
  if button ~= "left" or not control then return true end
  control:on_mouse_released(x, y)
  control.pressed = false
  self.pressed_control = nil
  if self.is_open then self:on_modal_mouse_moved(x, y) end
  return true
end

function Dialog:on_modal_mouse_wheel(dy)
  local control = self.mouse_x and self:control_at(self.mouse_x, self.mouse_y)
  if control then control:on_mouse_wheel(dy) end
  return true
end

function Dialog:on_modal_mouse_left()
  if not self.pressed_control then self:set_hovered(nil) end
  return true
end

------------------------------------------------------------------------------------------------------------------
-- Layout and drawing

---Place the content's controls in the column at (x, y) with width `w`, and return the content's height.
---`max_h` is the most height that the card has room for. The default content is empty.
function Dialog:layout_content(x, y, w, max_h) return 0 end

---Draw the content other than its controls, then the controls. The default draws only the controls.
function Dialog:draw_content()
  for _, control in ipairs(self.controls) do
    if control ~= self.close_button and control.visible then
      control:draw(self.is_open and control == self.focused)
    end
  end
end

---Called each frame while the Dialog is open, before its layout.
function Dialog:on_update() end

-- The card is centred on the Window, near the top of the area below the Title Bar. Its content sets its height.
function Dialog:layout()
  local m, um = self:metrics(), ui.metrics()
  local root = core.root_panel
  local bx, _, bw, bh = root:backdrop_rect()
  local top = root.position.y + (core.title_bar and core.title_bar.size.y or 0)
  local w = math.floor(math.max(1, math.min(self.width * SCALE, bw - 2 * m.side)))
  local header_h = um.control_h
  local fixed_h = 2 * m.pad + header_h + m.header_gap
  local available_h = math.max(fixed_h, bh - top - 2 * m.side)
  local inner_w = w - 2 * m.pad
  local content_h = self:layout_content(0, 0, inner_w, available_h - fixed_h)
  local h = math.min(fixed_h + content_h, available_h)
  local x = math.floor(bx + (bw - w) / 2)
  local y = math.floor(top + math.max(m.side, math.min((bh - top - h) / 2, m.top)))
  self.rect.x, self.rect.y, self.rect.w, self.rect.h = x, y, w, h
  self.header = { x = x + m.pad, y = y + m.pad, w = inner_w, h = header_h }
  self.close_button:set_rect(x + w - m.pad - header_h + um.gap, y + m.pad, header_h, header_h)
  self:layout_content(x + m.pad, y + m.pad + header_h + m.header_gap, inner_w, available_h - fixed_h)
end

function Dialog:step()
  local target = self.is_open and 1 or 0
  local now = system.get_time()
  local dt = self.last_step and math.min(0.1, now - self.last_step) or 0
  self.last_step = now
  if not config.transitions or config.disabled_transitions.dialog or core.in_live_resize_frame then
    self.progress = target
  elseif self.progress ~= target then
    local rate = (self.is_open and SHOW_RATE or HIDE_RATE) * (config.animation_rate or 1)
    self.progress = target + (self.progress - target) * math.exp(-rate * dt)
    if math.abs(self.progress - target) < 0.004 then self.progress = target end
    core.redraw = true
  end
  if self.is_open then
    if self.focused and not self.focused:can_focus() then self:focus(self:focusables()[1]) end
    self:on_update()
    self:layout()
  end
end

function Dialog:draw_dialog()
  local p = self.progress
  local m = self:metrics()
  local root = core.root_panel
  local bx, _, bw, bh = root:backdrop_rect()
  local top = root.position.y + (core.title_bar and core.title_bar.size.y or 0)
  local dim = ui.fade(style.dialog_dim, p)
  renderer.draw_rect(bx, top, bw, bh - top, dim)
  root:dim_sidebar(dim)
  local r = self.rect
  card.show_above_sidebar(r.x, r.y, r.w, r.h, m.radius)
  -- The card settles into place from a slightly smaller size.
  local transformed = p < 0.999
  if transformed then renderer.push_transform(r.x + r.w / 2, r.y, 0.97 + 0.03 * p, p) end
  card.draw(r.x, r.y, r.w, r.h, m.radius)
  core.push_clip_rect(r.x, r.y, r.w, r.h)
  local header = self.header
  local title_w = header.w - self.close_button.w
  common.draw_text(ui.bold_font(), style.text, ui.fit_text(ui.bold_font(), self.title, title_w), "left",
    header.x, header.y, title_w, header.h)
  self.close_button:draw(false)
  self:draw_content()
  core.pop_clip_rect()
  if transformed then renderer.pop_transform() end
end

------------------------------------------------------------------------------------------------------------------
-- Module

---The open Dialog, or nil.
function dialog.current()
  return current
end

---Move each shown Dialog one frame, and forget the ones that faded out.
function dialog.update()
  for i = #shown, 1, -1 do
    local item = shown[i]
    item:step()
    if not item.is_open and item.progress <= 0 then table.remove(shown, i) end
  end
end

function dialog.draw()
  for _, item in ipairs(shown) do
    if item.progress > 0 then item:draw_dialog() end
  end
end

return dialog
