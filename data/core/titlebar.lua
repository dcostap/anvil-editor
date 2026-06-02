local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"

local restore_command = {
  id = "restore", action = function() system.set_window_mode(core.window, "normal") end
}

local maximize_command = {
  id = "maximize", action = function() system.set_window_mode(core.window, "maximized") end
}

local title_commands = {
  {id = "minimize", action = function() system.set_window_mode(core.window, "minimized") end},
  maximize_command,
  {id = "close", action = function() core.quit() end},
}

local function window_frame_metrics()
  if core.window and system.get_window_frame_metrics then
    local button_width, title_height, resize_border = system.get_window_frame_metrics(core.window)
    if button_width then return button_width, title_height, resize_border end
  end
end

local function caption_button_width()
  local button_width = window_frame_metrics()
  return math.floor(math.max(button_width or 0, 46 * SCALE))
end

local caption_font
local caption_font_size
local title_logo
local title_logo_size
local caption_glyphs = {
  minimize = "\238\164\161", -- U+E921 ChromeMinimize
  maximize = "\238\164\162", -- U+E922 ChromeMaximize
  restore  = "\238\164\163", -- U+E923 ChromeRestore
  close    = "\238\162\187", -- U+E8BB ChromeClose
}

local function get_title_logo(size)
  if title_logo and title_logo_size == size then return title_logo end

  title_logo = nil
  title_logo_size = size

  local ok, logo = pcall(canvas.load_image, DATADIR .. "/icons/logo.png")
  if ok and logo then
    title_logo = logo:scaled(size, size, "linear")
  end
  return title_logo
end

local function get_caption_font()
  local size = 10 * SCALE
  if caption_font == false and caption_font_size == size then return nil end
  if caption_font and caption_font_size == size then return caption_font end

  caption_font = nil
  caption_font_size = size

  local candidates = {
    "C:/Windows/Fonts/segmdl2.ttf",
    "C:/Windows/Fonts/SegoeIcons.ttf",
  }
  for _, path in ipairs(candidates) do
    local ok, font = pcall(renderer.font.load, path, size, { antialiasing = "grayscale", hinting = "full" })
    if ok and font then
      caption_font = font
      return caption_font
    end
  end
  caption_font = false
end

---Title Bar: top application bar with native-looking window controls.
---@class core.titlebar : core.view
---@field super core.view
local TitleBar = View:extend()

function TitleBar:__tostring() return "TitleBar" end

local function title_bar_height()
  local _, title_height = window_frame_metrics()
  return math.max(style.font:get_height() + style.padding.y * 2, math.floor(title_height or 32 * SCALE))
end

local function title_tabs_x()
  return math.floor(220 * SCALE)
end

local function title_tabs_right_padding()
  return math.floor(80 * SCALE)
end

local function current_project_title()
  local project = core.root_project and core.root_project()
  if project and project.path and project.path ~= "" then
    return common.basename(project.path)
  end
  return "Anvil"
end

function TitleBar:new()
  TitleBar.super.new(self)
  self.visible = true
end

function TitleBar:get_tabs_node()
  if not core.root_panel then return nil end
  local node = core.root_panel:get_active_node()
  if node and not node.locked then return node end
  if core.last_active_view then
    node = core.root_panel.root_node:get_node_for_view(core.last_active_view)
    if node and not node.locked then return node end
  end
  return core.root_panel:get_main_panel()
end

function TitleBar:configure_hit_test(borderless)
  if borderless then
    local title_height = title_bar_height()
    local controls_width = caption_button_width() * #title_commands
    local client_x, client_width = 0, 0
    if config.integrated_titlebar_tabs then
      client_x = title_tabs_x()
      local available = math.max(0, self.size.x - client_x - controls_width - title_tabs_right_padding())
      local node = self:get_tabs_node()
      local count = (node and not node.locked and node.views) and #node.views or 0
      local tab_width = count > 0 and self:get_titlebar_tab_width(node, available) or 0
      local visible_count = tab_width > 0 and math.min(count, math.floor(available / tab_width)) or 0
      client_width = math.min(available, tab_width * visible_count)
    end
    local _, _, resize_border = window_frame_metrics()
    system.set_window_hit_test(core.window, title_height, controls_width, math.floor(resize_border or 8 * SCALE), client_x, client_width)
    -- core.hit_test_title_height = title_height
  else
    system.set_window_hit_test(core.window)
  end
end

function TitleBar:on_scale_change()
  caption_font = nil
  caption_font_size = nil
  self:configure_hit_test(self.visible)
end

function TitleBar:update()
  self.size.y = self.visible and title_bar_height() or 0
  title_commands[2] = core.window_mode == "maximized" and restore_command or maximize_command
  local node = self:get_tabs_node()
  local tab_count = (node and not node.locked and node.views) and #node.views or 0
  local tab_offset = node and node.tab_offset or 0
  if self.last_configured_width ~= self.size.x
     or self.last_configured_tab_count ~= tab_count
     or self.last_configured_tab_offset ~= tab_offset then
    self.last_configured_width = self.size.x
    self.last_configured_tab_count = tab_count
    self.last_configured_tab_offset = tab_offset
    self:configure_hit_test(self.visible)
  end
  TitleBar.super.update(self)
end


function TitleBar:has_window_focus()
  return not core.window or not system.window_has_focus or system.window_has_focus(core.window)
end

function TitleBar:draw_window_title()
  local h = style.font:get_height()
  local ox, oy = self:get_content_offset()
  local color = self:has_window_focus() and style.text or style.dim
  local y = oy + math.floor((self.size.y - h) / 2)

  local logo_slot = math.floor(math.min(22 * SCALE, self.size.y - 6 * SCALE))
  local logo_size = math.floor(math.min(16 * SCALE, logo_slot))
  local logo = get_title_logo(logo_size)
  if logo then
    renderer.draw_canvas(
      logo,
      ox + style.padding.x + math.floor((logo_slot - logo_size) / 2),
      oy + math.floor((self.size.y - logo_size) / 2)
    )
  end

  local controls_width = caption_button_width() * #title_commands
  local inset = math.max(logo_slot + style.padding.x * 2, controls_width + style.padding.x)
  local x = ox + inset
  local w = math.max(0, self.size.x - inset * 2)
  common.draw_text(style.font, color, current_project_title(), "center", x, y, w, h)
end

function TitleBar:get_tabs_rect()
  local controls_width = caption_button_width() * #title_commands
  local x = title_tabs_x()
  local w = math.max(0, self.size.x - x - controls_width - title_tabs_right_padding())
  return x, 0, w, self.size.y
end

function TitleBar:get_titlebar_tab_width(node, available_width)
  local count = math.max(1, #node.views)
  local min_width = config.integrated_titlebar_tab_min_width or 80 * SCALE
  local max_width = config.integrated_titlebar_tab_max_width or style.tab_width
  return math.max(1, math.min(max_width, math.max(min_width, available_width / count)))
end

function TitleBar:get_titlebar_tab_rect(node, idx)
  local x, y, w, h = self:get_tabs_rect()
  local tw = self:get_titlebar_tab_width(node, w)
  local visible_pos = idx - (node.tab_offset or 1) + 1
  return x + (visible_pos - 1) * tw, y, tw, h
end

function TitleBar:get_titlebar_tab_at(px, py)
  if not config.integrated_titlebar_tabs then return nil end
  local node = self:get_tabs_node()
  if not node or node.locked or not node.views or #node.views < 1 then return nil end
  local x, y, w, h = self:get_tabs_rect()
  if px < x or px >= x + w or py < y or py >= y + h then return nil end
  local tw = self:get_titlebar_tab_width(node, w)
  if tw <= 0 then return nil end
  local idx = math.floor((px - x) / tw) + (node.tab_offset or 1)
  local visible_count = math.floor(w / tw)
  local max_idx = math.min(#node.views, (node.tab_offset or 1) + visible_count - 1)
  if idx >= (node.tab_offset or 1) and idx <= max_idx and px < x + tw * visible_count then
    return node, idx
  end
end

local draw_caption_glyph

function TitleBar:draw_titlebar_tabs()
  if not config.integrated_titlebar_tabs then return end
  local node = self:get_tabs_node()
  if not node or node.locked or not node.views or #node.views < 1 then return end

  local x, y, w, h = self:get_tabs_rect()
  if w <= 0 then return end
  local tw = self:get_titlebar_tab_width(node, w)
  if tw <= 0 then return end
  local ds = style.divider_size
  core.push_clip_rect(x, y, w, h)
  local first = node.tab_offset or 1
  local visible_count = math.floor(w / tw)
  local last = math.min(#node.views, first + visible_count - 1)
  for i = first, last do
    local view = node.views[i]
    local tx, ty, tab_w, tab_h = self:get_titlebar_tab_rect(node, i)
    if tx >= x + w then break end
    local active = view == node.active_view
    local hovered = self.hovered_tab_index == i
    if active then
      renderer.draw_rect(tx, ty, tab_w, tab_h, style.background)
      renderer.draw_rect(tx, ty + tab_h - ds, tab_w, ds, style.caret)
    elseif hovered then
      renderer.draw_rect(tx, ty, tab_w, tab_h, { 255, 255, 255, 12 })
    end
    renderer.draw_rect(tx + tab_w, ty + style.padding.y, ds, tab_h - style.padding.y * 2, style.divider)

    local title_w = tab_w - style.padding.x * 2
    node:draw_tab_title(view, node:get_tab_title_font(), active, hovered, tx + style.padding.x, ty, title_w, tab_h)
  end
  core.pop_clip_rect()
end

function TitleBar:each_control_item()
  local ox, oy = self:get_content_offset()
  local button_w = caption_button_width()
  local h = self.size.y
  local i, n = 0, #title_commands
  local iter = function()
    i = i + 1
    if i <= n then
      return title_commands[i], ox + self.size.x - button_w * (n - i + 1), oy, button_w, h
    end
  end
  return iter
end


local function draw_glyph_line(x, y, w, h, color)
  renderer.draw_rect(math.floor(x), math.floor(y), math.max(1, math.floor(w)), math.max(1, math.floor(h)), color)
end

function draw_caption_glyph(item, x, y, w, h, color)
  local font = get_caption_font()
  local glyph = caption_glyphs[item.id]
  if font and glyph then
    common.draw_text(font, color, glyph, "center", x, y, w, h)
    return
  end

  local s = math.max(1, math.floor(SCALE))
  local gw = math.floor(10 * SCALE)
  local gh = math.floor(10 * SCALE)
  local cx = math.floor(x + (w - gw) / 2)
  local cy = math.floor(y + (h - gh) / 2)

  if item.id == "minimize" then
    draw_glyph_line(cx, cy + gh - 1 * SCALE, gw, s, color)
  elseif item.id == "maximize" then
    draw_glyph_line(cx, cy, gw, s, color)
    draw_glyph_line(cx, cy + gh - s, gw, s, color)
    draw_glyph_line(cx, cy, s, gh, color)
    draw_glyph_line(cx + gw - s, cy, s, gh, color)
  elseif item.id == "restore" then
    local off = math.floor(3 * SCALE)
    draw_glyph_line(cx + off, cy, gw - off, s, color)
    draw_glyph_line(cx + gw - s, cy, s, gh - off, color)
    draw_glyph_line(cx + off, cy + gh - off - s, gw - off, s, color)
    draw_glyph_line(cx, cy + off, gw - off, s, color)
    draw_glyph_line(cx, cy + gh - s, gw - off, s, color)
    draw_glyph_line(cx, cy + off, s, gh - off, color)
    draw_glyph_line(cx + gw - off - s, cy + off, s, gh - off, color)
  elseif item.id == "close" then
    local len = math.floor(10 * SCALE)
    local t = s
    for i = 0, len do
      draw_glyph_line(cx + i, cy + i, t, t, color)
      draw_glyph_line(cx + len - i, cy + i, t, t, color)
    end
  end
end

function TitleBar:draw_window_controls()
  for item, x, y, w, h in self:each_control_item() do
    local hovered = item == self.hovered_item
    local pressed = item == self.pressed_item
    if hovered then
      if item.id == "close" then
        renderer.draw_rect(x, y, w, h, pressed and { 153, 31, 32, 255 } or { 196, 43, 28, 255 })
      else
        renderer.draw_rect(x, y, w, h, pressed and { 255, 255, 255, 32 } or { 255, 255, 255, 18 })
      end
    end
    local color = (hovered and item.id == "close") and { 255, 255, 255, 255 } or (self:has_window_focus() and style.text or style.dim)
    draw_caption_glyph(item, x, y, w, h, color)
  end
end


function TitleBar:on_mouse_pressed(button, x, y, clicks)
  TitleBar.super.on_mouse_pressed(self, button, x, y, clicks)
  if button == "left" then
    self.pressed_item = self.hovered_item
    self.pressed_tab_index = self.hovered_tab_index
  end
end

function TitleBar:on_mouse_released(button, x, y)
  TitleBar.super.on_mouse_released(self, button, x, y)
  core.set_active_view(core.last_active_view)
  local item = self.hovered_item
  if button == "left" and item and item == self.pressed_item then
    item.action()
  elseif self.hovered_tab_index then
    local node, idx, close = self:get_titlebar_tab_at(x, y)
    if node and idx == self.hovered_tab_index then
      if button == "middle" then
        node:close_view(core.root_panel.root_node, node.views[idx])
      elseif button == "left" and idx == self.pressed_tab_index then
        node:set_active_view(node.views[idx])
      end
    end
  end
  self.pressed_item = nil
  self.pressed_tab_index = nil
end


function TitleBar:on_mouse_left()
  TitleBar.super.on_mouse_left(self)
  self.hovered_item = nil
  self.hovered_tab_index = nil
  self.pressed_item = nil
  self.pressed_tab_index = nil
end

function TitleBar:on_mouse_wheel(y, x)
  if not self.hovered_tab_index then return end
  local node = self:get_tabs_node()
  if not node or not node.views or #node.views < 2 then return true end
  local idx = node:get_view_idx(node.active_view) or self.hovered_tab_index
  idx = idx + (y > 0 and -1 or 1)
  if idx < 1 then idx = #node.views end
  if idx > #node.views then idx = 1 end
  node:set_active_view(node.views[idx])
  return true
end


function TitleBar:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  TitleBar.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  self.hovered_tab_index = nil
  local tab_node, tab_idx = self:get_titlebar_tab_at(px, py)
  if tab_node and tab_idx then
    self.hovered_tab_index = tab_idx
    return
  end
  for item, x, y, w, h in self:each_control_item() do
    if px >= x and py >= y and px <= x + w and py <= y + h then
      self.hovered_item = item
      return
    end
  end
end


function TitleBar:draw()
  self:draw_background(style.titlebar or style.background2)
  self:draw_window_title()
  self:draw_titlebar_tabs()
  self:draw_window_controls()
end

return TitleBar
