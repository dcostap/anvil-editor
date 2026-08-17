local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"

local TitleBar = View:extend()

local CAPTION_COUNT = 3
local TAB_SIDE_INSET = math.floor(3 * SCALE)
local TAB_TOP_INSET = math.floor(4 * SCALE)
local TAB_RADIUS = math.floor(8 * SCALE)
local caption_font
local caption_font_size
local caption_glyphs = {
  "\238\164\161", -- U+E921 ChromeMinimize
  "\238\164\162", -- U+E922 ChromeMaximize
  "\238\164\163", -- U+E923 ChromeRestore
  "\238\162\187", -- U+E8BB ChromeClose
}

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

local function get_caption_font()
  local size = 10 * SCALE
  if caption_font == false and caption_font_size == size then return nil end
  if caption_font and caption_font_size == size then return caption_font end
  caption_font, caption_font_size = nil, size
  for _, path in ipairs {
    "C:/Windows/Fonts/segmdl2.ttf",
    "C:/Windows/Fonts/SegoeIcons.ttf",
  } do
    local ok, font = pcall(renderer.font.load, path, size, {
      antialiasing = "grayscale", hinting = "full"
    })
    if ok and font then caption_font = font; return font end
  end
  caption_font = false
end

local function draw_glyph_line(x, y, w, h, color)
  renderer.draw_rect(math.floor(x), math.floor(y),
    math.max(1, math.floor(w)), math.max(1, math.floor(h)), color)
end

local function draw_caption_glyph(index, rect, color)
  local font = get_caption_font()
  local glyph = index == 1 and caption_glyphs[1]
    or index == 2 and caption_glyphs[core.window_mode == "maximized" and 3 or 2]
    or caption_glyphs[4]
  if font and glyph then
    draw_centered_text(font, glyph, rect, color)
    return
  end
  local scale = math.max(1, math.floor(SCALE))
  local width = math.floor(10 * SCALE)
  local height = math.floor(10 * SCALE)
  local x = math.floor(rect.x + (rect.w - width) / 2)
  local y = math.floor(rect.y + (rect.h - height) / 2)
  if index == 1 then
    draw_glyph_line(x, y + height - SCALE, width, scale, color)
  elseif index == 2 and core.window_mode ~= "maximized" then
    draw_glyph_line(x, y, width, scale, color)
    draw_glyph_line(x, y + height - scale, width, scale, color)
    draw_glyph_line(x, y, scale, height, color)
    draw_glyph_line(x + width - scale, y, scale, height, color)
  elseif index == 2 then
    local offset = math.floor(3 * SCALE)
    draw_glyph_line(x + offset, y, width - offset, scale, color)
    draw_glyph_line(x + width - scale, y, scale, height - offset, color)
    draw_glyph_line(x + offset, y + height - offset - scale, width - offset, scale, color)
    draw_glyph_line(x, y + offset, width - offset, scale, color)
    draw_glyph_line(x, y + height - scale, width - offset, scale, color)
    draw_glyph_line(x, y + offset, scale, height - offset, color)
    draw_glyph_line(x + width - offset - scale, y + offset, scale, height - offset, color)
  else
    for i = 0, width do
      draw_glyph_line(x + i, y + i, scale, scale, color)
      draw_glyph_line(x + width - i, y + i, scale, scale, color)
    end
  end
end

local function fit_text(font, text, max_width)
  if max_width <= 0 then return "" end
  if font:get_width(text) <= max_width then return text end
  local ellipsis = "…"
  if font:get_width(ellipsis) > max_width then return "" end
  local low, high = 0, text:ulen()
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if font:get_width(text:usub(1, middle) .. ellipsis) <= max_width then
      low = middle
    else
      high = middle - 1
    end
  end
  return text:usub(1, low) .. ellipsis
end

local function pane_label(number, pane)
  local view = pane.current_view
  local name = view.get_name and view:get_name() or "View"
  return string.format("%d %s", number, name)
end

local function preferred_tab_width(number, pane)
  local min_width = config.integrated_titlebar_tab_min_width or 80 * SCALE
  local max_width = config.integrated_titlebar_tab_max_width or style.tab_width
  local width = style.font:get_width(pane_label(number, pane)) + style.padding.x * 2
  return common.clamp(width, min_width, math.max(min_width, max_width))
end

local function draw_tab_tile(x, y, w, h, color)
  local side_inset = math.min(TAB_SIDE_INSET, math.max(0, w / 2 - 1))
  local top_inset = math.min(TAB_TOP_INSET, math.max(0, h - 1))
  local tile_width = math.max(1, w - side_inset * 2)
  local radius = math.min(TAB_RADIUS, tile_width / 2)
  renderer.draw_rounded_rect(x + side_inset, y + top_inset, tile_width,
    math.max(1, h - top_inset + radius), radius, color)
end

function TitleBar:__tostring() return "TitleBar" end

function TitleBar:new()
  TitleBar.super.new(self)
  self.visible = true
  self.hovered_entry = nil
  self.hovered_caption = nil
  self.pressed_caption = nil
  self.entries = {}
  self.caption_rects = {}
  self.tab_offset = 1
end

function TitleBar:get_pane_entries()
  local result = {}
  local active = panes().active()
  local visible = panes().visible_group()
  local ordered = panes().ordered()
  for i, pane in ipairs(ordered) do
    local geometry = self.entries[i] or {}
    result[i] = {
      pane = pane,
      number = i,
      label = pane_label(i, pane),
      active = pane == active,
      visible = pane.group == visible,
      x = geometry.x,
      y = geometry.y,
      w = geometry.w,
      h = geometry.h,
      group_start = i == 1 or ordered[i - 1].group ~= pane.group,
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
  if count > 0 and available > 0 then
    local widths = {}
    for i, pane in ipairs(ordered) do widths[i] = preferred_tab_width(i, pane) end
    self.tab_offset = common.clamp(self.tab_offset or 1, 1, count)
    local active = panes().active()
    if active ~= self.last_active_pane then
      self.last_active_pane = active
      local active_index = panes().number(active)
      if active_index and active_index < self.tab_offset then self.tab_offset = active_index end
      if active_index then
        local used = 0
        for i = self.tab_offset, active_index do used = used + widths[i] end
        while used > available and self.tab_offset < active_index do
          used = used - widths[self.tab_offset]
          self.tab_offset = self.tab_offset + 1
        end
      end
    end
    local x = start_x
    for i = self.tab_offset, count do
      local width = math.min(widths[i], available)
      if i > self.tab_offset and x + width > start_x + available then break end
      self.entries[i] = {
        x = x,
        y = self.position.y,
        w = width,
        h = h,
      }
      x = x + width
      if x >= start_x + available then break end
    end
  end
end

function TitleBar:configure_hit_test(enabled)
  if not core.window or not system.set_window_hit_test then return end
  if enabled == nil then enabled = self.visible end
  if not enabled then
    if self.hit_test_signature ~= "disabled" then
      self.hit_test_signature = "disabled"
      system.set_window_hit_test(core.window)
    end
    return
  end
  local interactive_x, interactive_right
  for _, rect in pairs(self.entries) do
    interactive_x = math.min(interactive_x or rect.x, rect.x)
    interactive_right = math.max(interactive_right or (rect.x + rect.w), rect.x + rect.w)
  end
  local interactive_width = interactive_x and interactive_right - interactive_x or 0
  interactive_x = interactive_x or 0
  local _, _, resize_border = window_frame_metrics()
  local signature = table.concat({
    tostring(core.window), tostring(self.size.y), tostring(interactive_x),
    tostring(interactive_width), tostring(resize_border), tostring(caption_width())
  }, ":")
  if signature == self.hit_test_signature then return end
  self.hit_test_signature = signature
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
  for i = 1, #panes().ordered() do
    local rect = self.entries[i]
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
  self.hovered_entry, self.hovered_caption, self.pressed_caption = nil, nil, nil
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
  if button == "middle" then
    local index = self:entry_at(x, y)
    local pane = index and panes().ordered()[index]
    if pane then panes().close(pane); return true end
    return false
  end
  if button ~= "left" then return false end
  local caption = self:caption_at(x, y)
  if caption then
    self.pressed_caption = caption
    core.redraw = true
    return true
  end
  local index = self:entry_at(x, y)
  if index then
    local pane = panes().ordered()[index]
    if pane then panes().focus(pane) end
    return true
  end
  if clicks == 2 and core.window then
    perform_caption(2)
    return true
  end
  return false
end

function TitleBar:on_mouse_released(button, x, y)
  local pressed = self.pressed_caption
  local released = button == "left" and self:caption_at(x, y) or nil
  self.pressed_caption = nil
  if pressed and released == pressed then perform_caption(pressed) end
  if pressed then core.redraw = true end
  return pressed ~= nil or self.hovered_entry ~= nil or self.hovered_caption ~= nil
end

function TitleBar:on_scale_change()
  caption_font, caption_font_size = nil, nil
  self.hit_test_signature = nil
end

function TitleBar:on_mouse_wheel(y, x)
  if self.size.y <= 0 then return false end
  local count = #panes().ordered()
  local visible = 0
  for _ in pairs(self.entries) do visible = visible + 1 end
  if count <= visible or visible == 0 then return false end
  local direction = y > 0 and -1 or 1
  self.tab_offset = common.clamp(self.tab_offset + direction * visible, 1,
    math.max(1, count - visible + 1))
  self:update_geometry()
  core.redraw = true
  return true
end

function TitleBar:draw()
  if self.size.y <= 0 then return end
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, style.titlebar)
  local font = style.font
  draw_centered_text(font,
    fit_text(font, project_name(), math.max(0, self.project_rect.w - style.padding.x * 2)),
    self.project_rect, style.text)
  for i, entry in ipairs(self:get_pane_entries()) do
    local rect = self.entries[i]
    if rect then
      local hovered = self.hovered_entry == i
      if entry.active then
        draw_tab_tile(rect.x, rect.y, rect.w, rect.h,
          style.titlebar_tab_active or style.background)
      end
      if hovered then
        draw_tab_tile(rect.x, rect.y, rect.w, rect.h,
          style.titlebar_tab_hover or style.background2)
      end
      local label_rect = { x = rect.x + style.padding.x, y = rect.y,
        w = math.max(0, rect.w - style.padding.x * 2), h = rect.h }
      local label = fit_text(font, entry.label, label_rect.w)
      renderer.draw_text(font, label, label_rect.x,
        label_rect.y + math.floor((label_rect.h - font:get_height()) / 2),
        (entry.active or hovered) and style.text or style.dim)
    end
  end
  for i, rect in ipairs(self.caption_rects) do
    local hovered = self.hovered_caption == i
    local pressed = hovered and self.pressed_caption == i
    local background = pressed
      and (i == 3 and style.titlebar_close_pressed or style.titlebar_control_pressed)
      or hovered
      and (i == 3 and style.titlebar_close_hover or style.titlebar_control_hover)
      or nil
    if background then renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, background) end
    local focused = not core.window or not system.window_has_focus
      or system.window_has_focus(core.window)
    local color = hovered and i == 3 and (style.titlebar_close_text or style.text)
      or focused and style.text or style.dim
    draw_caption_glyph(i, rect, color)
  end
end

return TitleBar
