local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local view_icons = require "core.view_icons"
local View = require "core.view"

local TitleBar = View:extend()

local CAPTION_COUNT = 3
local DRAG_THRESHOLD = 6
local DRAG_SCROLL_EDGE = 28
local DRAG_SCROLL_INTERVAL = 0.12
local TAB_SIDE_INSET = math.floor(3 * SCALE)
local TAB_TOP_INSET = math.floor(4 * SCALE)
local TAB_RADIUS = math.floor(8 * SCALE)
-- Text metrics and layout geometry can differ by a subpixel at fractional
-- Zoom. Keep one pixel outside content-sized labels and ignore subpixel noise.
local TEXT_FIT_RESERVE = 1
local TEXT_OVERFLOW_TOLERANCE = 0.5
local function tab_group_gap() return math.max(4, math.floor(8 * SCALE)) end
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
  if font:get_width(text) <= max_width + TEXT_OVERFLOW_TOLERANCE then return text end
  local ellipsis = "…"
  if font:get_width(ellipsis) > max_width + TEXT_OVERFLOW_TOLERANCE then return "" end
  local low, high = 0, text:ulen()
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if font:get_width(text:usub(1, middle) .. ellipsis)
      <= max_width + TEXT_OVERFLOW_TOLERANCE
    then
      low = middle
    else
      high = middle - 1
    end
  end
  return text:usub(1, low) .. ellipsis
end

local function pane_name(pane)
  local view = pane.current_view
  return view.get_name and view:get_name() or "View"
end

local function pane_label(number, pane)
  return string.format("%d %s", number, pane_name(pane))
end

function TitleBar.pane_marker_font()
  local size = math.max(common.round(8 * SCALE), common.round(style.font:get_size() * 0.8))
  return style.get_scaled_font(style.prose_heading_font, size)
end

local function pane_number_gap()
  return math.max(3 * SCALE, style.padding.x / 3)
end

local function pane_icon(pane)
  return view_icons.for_view(pane.current_view)
end

local function pane_icon_gap()
  return math.max(4 * SCALE, style.padding.x / 2)
end

local function pane_label_metrics(number, pane, row_height)
  local icon = pane_icon(pane)
  local number_font = style.font
  local name_font = style.prose_font
  local number_text = tostring(number)
  local name = pane_name(pane)
  local number_width = number_font:get_width(number_text)
  local icon_width = icon and view_icons.width(icon, row_height) or 0
  local width = number_width + pane_number_gap()
    + icon_width + (icon and pane_icon_gap() or 0)
    + name_font:get_width(name)
  return {
    icon = icon,
    icon_width = icon_width,
    number_font = number_font,
    number_text = number_text,
    number_width = number_width,
    name_font = name_font,
    name = name,
    width = width,
  }
end

local function draw_pane_label(number, pane, rect, name_color)
  local x = rect.x
  local metrics = pane_label_metrics(number, pane, rect.h)
  renderer.draw_text(
    metrics.number_font, metrics.number_text, x,
    rect.y + math.floor((rect.h - metrics.number_font:get_height()) / 2),
    style.titlebar_pane_number
  )
  x = x + metrics.number_width + pane_number_gap()
  if metrics.icon then
    view_icons.draw(metrics.icon, x, rect.y, rect.h, name_color)
    x = x + metrics.icon_width + pane_icon_gap()
  end
  local name = fit_text(metrics.name_font, metrics.name,
    math.max(0, rect.x + rect.w - x))
  renderer.draw_text(
    metrics.name_font, name, x,
    rect.y + math.floor((rect.h - metrics.name_font:get_height()) / 2), name_color
  )
end

local function preferred_tab_width(number, pane, row_height)
  local min_width = config.integrated_titlebar_tab_min_width or 80 * SCALE
  local max_width = config.integrated_titlebar_tab_max_width or style.tab_width
  local width = math.ceil(
    pane_label_metrics(number, pane, row_height).width + style.padding.x * 2
  )
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
  self.pressed_pane = nil
  self.dragged_pane = nil
  self.drag_target = nil
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

  local project_width = math.min(220 * SCALE, math.ceil(
    style.font:get_width(project_name()) + style.padding.x * 2 + TEXT_FIT_RESERVE
  ))
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
    for i, pane in ipairs(ordered) do widths[i] = preferred_tab_width(i, pane, h) end
    self.tab_offset = common.clamp(self.tab_offset or 1, 1, count)
    local active = panes().active()
    if active ~= self.last_active_pane then
      self.last_active_pane = active
      local active_index = panes().number(active)
      if active_index and active_index < self.tab_offset then self.tab_offset = active_index end
      if active_index then
        local used = 0
        for i = self.tab_offset, active_index do
          if i > self.tab_offset and ordered[i - 1].group ~= ordered[i].group then
            used = used + tab_group_gap()
          end
          used = used + widths[i]
        end
        while used > available and self.tab_offset < active_index do
          used = used - widths[self.tab_offset]
          if ordered[self.tab_offset].group ~= ordered[self.tab_offset + 1].group then
            used = used - tab_group_gap()
          end
          self.tab_offset = self.tab_offset + 1
        end
      end
    end
    local x = start_x
    for i = self.tab_offset, count do
      local gap = i > self.tab_offset and ordered[i - 1].group ~= ordered[i].group
        and tab_group_gap() or 0
      local width = math.min(widths[i], available)
      if i > self.tab_offset and x + gap + width > start_x + available then break end
      x = x + gap
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
  if self.pressed_pane then
    self.drag_x, self.drag_y = x, y
    if not self.dragged_pane and common.distance(
      x, y, self.drag_start_x, self.drag_start_y
    ) >= DRAG_THRESHOLD * SCALE then
      self.dragged_pane = self.pressed_pane
      core.log_quiet("Pane drag: started %s", self.dragged_pane.id)
    end
    if self.dragged_pane then
      local now = system.get_time()
      local lane_left = self.project_rect.x + self.project_rect.w
      local lane_right = self.caption_rects[1] and self.caption_rects[1].x
        or self.position.x + self.size.x
      if y >= self.position.y and y < self.position.y + self.size.y
      and now - (self.last_drag_scroll or 0) >= DRAG_SCROLL_INTERVAL then
        local count = #panes().ordered()
        local last_visible = 0
        for index in pairs(self.entries) do last_visible = math.max(last_visible, index) end
        if x < lane_left + DRAG_SCROLL_EDGE * SCALE and self.tab_offset > 1 then
          self.tab_offset = self.tab_offset - 1
          self.last_drag_scroll = now
          self:update_geometry()
        elseif x > lane_right - DRAG_SCROLL_EDGE * SCALE and last_visible < count then
          self.tab_offset = self.tab_offset + 1
          self.last_drag_scroll = now
          self:update_geometry()
        end
      end
      self.drag_target = self:resolve_pane_drag_target(x, y)
      core.request_cursor("hand")
      core.redraw = true
      return true
    end
  end
  core.redraw = true
  return TitleBar.super.on_mouse_moved(self, x, y, ...)
end

function TitleBar:on_mouse_left()
  self.hovered_entry, self.hovered_caption = nil, nil
  if not self.pressed_pane then self.pressed_caption = nil end
  core.redraw = true
end

local function group_entry_edge(title, group, placement)
  local edge
  for index, pane in ipairs(panes().ordered()) do
    local rect = pane.group == group and title.entries[index] or nil
    if rect then
      local value = placement == "before" and rect.x or rect.x + rect.w
      edge = edge and (placement == "before" and math.min(edge, value)
        or math.max(edge, value)) or value
    end
  end
  return edge
end

function TitleBar:resolve_pane_drag_target(x, y)
  local source = self.dragged_pane
  if not source then return nil end
  local destination, direction = panes().drop_target_at(x, y)
  if destination then
    if destination == source then return nil end
    local rect = {
      x = destination.position.x, y = destination.position.y,
      w = destination.size.x, h = destination.size.y,
    }
    if direction == "left" then
      rect.w = rect.w * 0.3
    elseif direction == "right" then
      rect.x, rect.w = rect.x + rect.w * 0.7, rect.w * 0.3
    elseif direction == "up" then
      rect.h = rect.h * 0.3
    elseif direction == "down" then
      rect.y, rect.h = rect.y + rect.h * 0.7, rect.h * 0.3
    else
      rect.x, rect.y = rect.x + rect.w * 0.2, rect.y + rect.h * 0.2
      rect.w, rect.h = rect.w * 0.6, rect.h * 0.6
    end
    return { kind = "work", pane = destination, direction = direction, rect = rect }
  end

  local index, rect = self:entry_at(x, y)
  local target = index and panes().ordered()[index]
  if not target then
    local lane_left = self.project_rect.x + self.project_rect.w
    local lane_right = self.caption_rects[1] and self.caption_rects[1].x
      or self.position.x + self.size.x
    if y >= self.position.y and y < self.position.y + self.size.y
    and x >= lane_left and x < lane_right then
      local first_index, last_index
      for entry_index in pairs(self.entries) do
        first_index = math.min(first_index or entry_index, entry_index)
        last_index = math.max(last_index or entry_index, entry_index)
      end
      local first_rect = first_index and self.entries[first_index]
      local last_rect = last_index and self.entries[last_index]
      local placement = first_rect and x < first_rect.x and "before"
        or last_rect and x >= last_rect.x + last_rect.w and "after" or nil
      local boundary_index = placement == "before" and first_index or last_index
      target = boundary_index and panes().ordered()[boundary_index] or nil
      if target and placement then
        return {
          kind = "group-boundary", pane = target, placement = placement,
          indicator_x = group_entry_edge(self, target.group, placement),
        }
      end
    end
    return nil
  end
  if target == source then return nil end
  if target.group == source.group then
    local placement = x < rect.x + rect.w / 2 and "before" or "after"
    return {
      kind = "reorder", pane = target,
      direction = placement == "before" and "left" or "right",
      indicator_x = placement == "before" and rect.x or rect.x + rect.w,
    }
  end
  local placement = x < rect.x + rect.w / 2 and "before" or "after"
  return {
    kind = "group-boundary", pane = target, placement = placement,
    indicator_x = group_entry_edge(self, target.group, placement),
  }
end

function TitleBar:apply_pane_drag_target(target)
  local source = self.dragged_pane
  if not source or not target then return nil end
  if target.kind == "work" then
    return panes().drop(source, self.drag_x, self.drag_y)
  elseif target.kind == "reorder" then
    return panes().move(source, target.pane, target.direction)
  elseif target.kind == "group-boundary" then
    return panes().move_to_group_boundary(source, target.pane, target.placement)
  end
end

function TitleBar:clear_pane_drag(outcome)
  local dragged = self.dragged_pane
  self.pressed_pane = nil
  self.dragged_pane = nil
  self.drag_target = nil
  self.drag_start_x, self.drag_start_y = nil, nil
  self.drag_x, self.drag_y = nil, nil
  self.last_drag_scroll = nil
  if dragged then
    core.log_quiet("Pane drag: finished %s outcome=%s", dragged.id, tostring(outcome))
  end
  core.request_cursor("arrow")
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
    if pane then
      self.pressed_pane = pane
      self.drag_start_x, self.drag_start_y = x, y
      self.drag_x, self.drag_y = x, y
    end
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
  if self.pressed_pane then
    local source = self.pressed_pane
    local dragged = self.dragged_pane ~= nil
    self.drag_x, self.drag_y = x, y
    local target = dragged and self:resolve_pane_drag_target(x, y) or nil
    local outcome = dragged and self:apply_pane_drag_target(target) or nil
    if not dragged and button == "left" then
      local index = self:entry_at(x, y)
      if index and panes().ordered()[index] == source then outcome = panes().focus(source) end
    end
    self:clear_pane_drag(outcome and "dropped" or "cancelled")
    return true
  end
  return pressed ~= nil or self.hovered_entry ~= nil or self.hovered_caption ~= nil
end

function TitleBar:on_focus_lost()
  self.pressed_caption = nil
  if self.pressed_pane then self:clear_pane_drag("cancelled") end
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

function TitleBar:draw_pane_drag()
  local pane = self.dragged_pane
  if not pane then return end
  local target = self.drag_target
  if target and target.kind == "work" and target.rect then
    renderer.draw_rect(
      target.rect.x, target.rect.y, target.rect.w, target.rect.h,
      style.drag_overlay
    )
  elseif target and target.indicator_x then
    local width = math.max(2, math.floor(2 * SCALE))
    renderer.draw_rect(
      target.indicator_x - width / 2, self.position.y + TAB_TOP_INSET,
      width, math.max(1, self.size.y - TAB_TOP_INSET),
      style.drag_overlay_tab
    )
  end

  local number = panes().number(pane) or 1
  local width = preferred_tab_width(number, pane, self.size.y)
  local height = self.size.y
  local x = common.clamp(
    (self.drag_x or 0) - width / 2,
    self.position.x,
    math.max(self.position.x, self.position.x + self.size.x - width)
  )
  local y = common.clamp(
    (self.drag_y or 0) - height / 2,
    self.position.y,
    math.max(self.position.y, self.position.y + self.size.y - height)
  )
  draw_tab_tile(x, y, width, height, style.titlebar_tab_hover or style.background2)
  draw_pane_label(number, pane, {
    x = x + style.padding.x, y = y,
    w = math.max(0, width - style.padding.x * 2), h = height,
  }, style.text)
end

function TitleBar:draw()
  if self.size.y <= 0 then return end
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, style.titlebar)
  local font = style.font
  local pane_entries = self:get_pane_entries()
  draw_centered_text(font,
    fit_text(font, project_name(), math.max(0, self.project_rect.w - style.padding.x * 2)),
    self.project_rect, style.text)
  for i, entry in ipairs(pane_entries) do
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
      draw_pane_label(entry.number, entry.pane, label_rect,
        (entry.active or entry.visible or hovered) and style.text or style.dim)
    end
  end
  local first_visible, last_visible
  for i, entry in ipairs(pane_entries) do
    local rect = entry.visible and self.entries[i] or nil
    if rect then
      first_visible = first_visible or rect
      last_visible = rect
    end
  end
  if first_visible then
    local height = math.max(2, math.floor(2 * SCALE))
    local left = first_visible.x + TAB_SIDE_INSET
    local right = last_visible.x + last_visible.w - TAB_SIDE_INSET
    renderer.draw_rect(
      math.floor(left), self.position.y + self.size.y - height,
      math.max(1, math.floor(right - left)), height,
      style.titlebar_group_indicator
    )
  end
  local window_focused = not core.window or not system.window_has_focus
    or system.window_has_focus(core.window)
  for i, rect in ipairs(self.caption_rects) do
    local hovered = self.hovered_caption == i
    local pressed = hovered and self.pressed_caption == i
    local background = pressed
      and (i == 3 and style.titlebar_close_pressed or style.titlebar_control_pressed)
      or hovered
      and (i == 3 and style.titlebar_close_hover or style.titlebar_control_hover)
      or nil
    if background then renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, background) end
    local color = hovered and i == 3 and (style.titlebar_close_text or style.text)
      or window_focused and style.text or style.dim
    draw_caption_glyph(i, rect, color)
  end
  self:draw_pane_drag()
end

return TitleBar
