local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"

local TitleBar = View:extend()

local CAPTION_COUNT = 3

local function panes()
  return core.panes or require "core.panes"
end

local function window_frame_metrics()
  if core.window and system.get_window_frame_metrics then
    return system.get_window_frame_metrics(core.window)
  end
end

local function bar_height()
  local _, native_height = window_frame_metrics()
  return math.max(style.font:get_height() + style.padding.y * 2, math.floor(native_height or 32 * SCALE))
end

local function caption_width()
  local native_width = window_frame_metrics()
  return math.floor(math.max(native_width or 0, 46 * SCALE))
end

local function project_name()
  local project = core.root_project and core.root_project()
  if project and project.path and project.path ~= "" then return common.basename(project.path) end
  return "Anvil"
end

local function contains(rect, x, y)
  return rect and x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end

local function draw_centered_text(font, text, rect, color)
  local width = font:get_width(text)
  local height = font:get_height()
  renderer.draw_text(font, text, rect.x + math.max(0, (rect.w - width) / 2),
    rect.y + math.floor((rect.h - height) / 2), color)
end

function TitleBar:__tostring() return "TitleBar" end

function TitleBar:new()
  TitleBar.super.new(self)
  self.visible = true
  self.hovered_entry = nil
  self.hovered_caption = nil
  self.entries = {}
  self.caption_rects = {}
end

function TitleBar:get_pane_entries()
  local result = {}
  local active = panes().active()
  local visible = panes().visible_group()
  for i, pane in ipairs(panes().ordered()) do
    local name = pane.current_view.get_name and pane.current_view:get_name() or "View"
    local geometry = self.entries[i] or {}
    result[i] = {
      pane = pane,
      number = i,
      label = string.format("%d %s", i, name),
      active = pane == active,
      visible = pane.group == visible,
      x = geometry.x,
      y = geometry.y,
      w = geometry.w,
      h = geometry.h,
      close_x = geometry.close_x,
    }
  end
  return result
end

function TitleBar:update_geometry()
  local h = self.size.y
  local button_width = caption_width()
  local caption_start = self.position.x + self.size.x - button_width * CAPTION_COUNT
  self.caption_rects = {}
  for i = 1, CAPTION_COUNT do
    self.caption_rects[i] = {
      x = caption_start + (i - 1) * button_width,
      y = self.position.y,
      w = button_width,
      h = h,
    }
  end

  local project_width = math.min(220 * SCALE, style.font:get_width(project_name()) + style.padding.x * 2)
  self.project_rect = {
    x = self.position.x,
    y = self.position.y,
    w = project_width,
    h = h,
  }
  local start_x = self.project_rect.x + self.project_rect.w
  local available = math.max(0, caption_start - start_x)
  local ordered = panes().ordered()
  local count = #ordered
  self.entries = {}
  if count > 0 then
    local min_width = config.integrated_titlebar_tab_min_width or 48 * SCALE
    local max_width = config.integrated_titlebar_tab_max_width or 300 * SCALE
    local width = common.clamp(available / count, math.min(min_width, available / count), max_width)
    if width * count > available then width = available / count end
    for i = 1, count do
      local x = start_x + (i - 1) * width
      self.entries[i] = {
        x = x,
        y = self.position.y,
        w = width,
        h = h,
        close_x = x + width - math.min(22 * SCALE, width / 3),
      }
    end
  end
end

function TitleBar:configure_hit_test()
  if not core.window or not system.set_window_hit_test then return end
  local first = self.entries[1]
  local last = self.entries[#self.entries]
  local interactive_x = first and first.x or 0
  local interactive_width = first and last and (last.x + last.w - first.x) or 0
  local _, _, resize_border = window_frame_metrics()
  system.set_window_hit_test(core.window, self.size.y, caption_width() * CAPTION_COUNT,
    math.floor(resize_border or 8 * SCALE), interactive_x, interactive_width, 0, 0)
end

function TitleBar:update()
  self.size.y = self.visible and bar_height() or 0
  self:update_geometry()
  self:configure_hit_test()
  TitleBar.super.update(self)
end

function TitleBar:entry_at(x, y)
  for i, rect in ipairs(self.entries) do
    if contains(rect, x, y) then return i, rect end
  end
end

function TitleBar:caption_at(x, y)
  for i, rect in ipairs(self.caption_rects) do
    if contains(rect, x, y) then return i, rect end
  end
end

function TitleBar:on_mouse_moved(x, y, ...)
  self.hovered_entry = self:entry_at(x, y)
  self.hovered_caption = self:caption_at(x, y)
  core.redraw = true
  return TitleBar.super.on_mouse_moved(self, x, y, ...)
end

function TitleBar:on_mouse_left()
  self.hovered_entry, self.hovered_caption = nil, nil
  core.redraw = true
end

local function perform_caption(index)
  if index == 1 then
    if core.window then system.set_window_mode(core.window, "minimized") end
  elseif index == 2 then
    if core.window then
      local mode = core.window_mode == "maximized" and "normal" or "maximized"
      system.set_window_mode(core.window, mode)
    end
  elseif index == 3 then
    core.quit()
  end
end

function TitleBar:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then return false end
  local caption = self:caption_at(x, y)
  if caption then
    perform_caption(caption)
    return true
  end
  local index, rect = self:entry_at(x, y)
  if index then
    local pane = panes().ordered()[index]
    if pane and x >= rect.close_x then
      panes().close(pane)
    elseif pane then
      panes().focus(pane)
    end
    return true
  end
  if clicks == 2 and core.window then
    perform_caption(2)
    return true
  end
  return false
end

function TitleBar:on_mouse_released()
  return self.hovered_entry ~= nil or self.hovered_caption ~= nil
end

function TitleBar:draw()
  if self.size.y <= 0 then return end
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, style.titlebar)
  local font = style.font
  draw_centered_text(font, project_name(), self.project_rect, style.text)
  for i, entry in ipairs(self:get_pane_entries()) do
    local rect = self.entries[i]
    local color = entry.active and (style.titlebar_tab_active or style.background)
      or self.hovered_entry == i and (style.titlebar_tab_hover or style.background2)
      or entry.visible and (style.background2 or style.titlebar)
      or style.titlebar
    renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, color)
    local label_rect = { x = rect.x + style.padding.x, y = rect.y,
      w = math.max(0, rect.w - style.padding.x * 2 - 20 * SCALE), h = rect.h }
    local label = entry.label
    while #label > 1 and font:get_width(label) > label_rect.w do label = label:sub(1, -2) end
    if label ~= entry.label and #label > 1 then label = label:sub(1, -2) .. "…" end
    renderer.draw_text(font, label, label_rect.x,
      label_rect.y + math.floor((label_rect.h - font:get_height()) / 2), style.text)
    if self.hovered_entry == i then
      draw_centered_text(font, "×", { x = rect.close_x, y = rect.y,
        w = rect.x + rect.w - rect.close_x, h = rect.h }, style.text)
    end
  end
  local glyphs = { "—", core.window_mode == "maximized" and "❐" or "□", "×" }
  for i, rect in ipairs(self.caption_rects) do
    local color = self.hovered_caption == i
      and (i == 3 and style.titlebar_close_hover or style.titlebar_control_hover)
      or nil
    if color then renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, color) end
    draw_centered_text(font, glyphs[i], rect,
      i == 3 and (style.titlebar_close_text or style.text) or style.text)
  end
end

return TitleBar
