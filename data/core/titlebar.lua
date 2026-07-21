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

local function current_project_title()
  local project = core.root_project and core.root_project()
  if project and project.path and project.path ~= "" then
    return common.basename(project.path)
  end
  return "Anvil"
end

local function title_tabs_x()
  local logo_slot = math.floor(math.min(22 * SCALE, title_bar_height() - 6 * SCALE))
  local title_x = logo_slot + style.padding.x * 2
  local natural_x = title_x + style.font:get_width(current_project_title()) + style.padding.x
  return math.ceil(math.min(220 * SCALE, natural_x))
end

local TITLEBAR_SAFE_ZONE_RATIO = 0.10
local HIDDEN_RIGHT_TABS_OPACITY = 0.60

local function titlebar_safe_zone_min_width()
  return math.floor(80 * SCALE)
end

local function titlebar_tab_width_limits()
  local min_width = config.integrated_titlebar_tab_min_width or 80 * SCALE
  local max_width = config.integrated_titlebar_tab_max_width or style.tab_width
  return math.max(1, min_width), math.max(min_width, max_width)
end

local function node_view_index(node, view)
  for i, candidate in ipairs(node and node.views or {}) do
    if candidate == view then return i end
  end
end

local function titlebar_tab_preferred_width(node, view)
  local min_width, max_width = titlebar_tab_width_limits()
  local idx = node_view_index(node, view)
  local width = idx and node.get_tab_preferred_width and node:get_tab_preferred_width(idx)
  if not width and view and view.get_name and node and node.get_tab_title_font then
    local font = node:get_tab_title_font()
    width = font:get_width(view:get_name() or "") + style.padding.x * 2 + style.divider_size * 2
  end
  return common.clamp(width or min_width, min_width, max_width)
end

local function titlebar_tab_width_demand(node, views)
  local min_width = titlebar_tab_width_limits()
  local minimum = #views * min_width
  local preferred = 0
  for _, view in ipairs(views) do
    preferred = preferred + titlebar_tab_preferred_width(node, view)
  end
  return minimum, preferred
end

local function sum_widths(widths, first, last)
  local total = 0
  for i = first, last do total = total + (widths[i] or 0) end
  return total
end

local function visible_tab_count(widths, first, available_width)
  local count, used = 0, 0
  for i = first, #widths do
    local width = widths[i]
    if count > 0 and used + width > available_width + 0.001 then break end
    if count == 0 and available_width <= 0 then break end
    count = count + 1
    used = used + width
    if used >= available_width - 0.001 then break end
  end
  return count
end

local function color_faded_over_titlebar(color, opacity)
  if not color or opacity >= 1 then return color end
  local effective_opacity = opacity * (color[4] or 255) / 255
  local background = style.titlebar
  return {
    math.floor(background[1] + ((color[1] or 0) - background[1]) * effective_opacity + 0.5),
    math.floor(background[2] + ((color[2] or 0) - background[2]) * effective_opacity + 0.5),
    math.floor(background[3] + ((color[3] or 0) - background[3]) * effective_opacity + 0.5),
    255,
  }
end

local function titlebar_scroll_button_width()
  return math.floor(24 * SCALE)
end

local function panes()
  return core.panes or require "core.panes"
end

local function pane_tab_views(node)
  local views = {}
  for _, view in ipairs(node and node.views or {}) do
    if not panes().is_placeholder(view) then views[#views + 1] = view end
  end
  return views
end

local TITLE_ELLIPSIS = "…"

local function truncate_text_right(font, text, max_width)
  max_width = math.max(0, max_width or 0)
  if font:get_width(text) <= max_width then return text end

  local ellipsis_width = font:get_width(TITLE_ELLIPSIS)
  if ellipsis_width > max_width then return "" end

  local remaining = max_width - ellipsis_width
  local prefix = ""
  for ch in common.utf8_chars(text) do
    local candidate = prefix .. ch
    if font:get_width(candidate) > remaining then break end
    prefix = candidate
  end
  return prefix .. TITLE_ELLIPSIS
end

function TitleBar:new()
  TitleBar.super.new(self)
  self.visible = true
end

function TitleBar:get_tabs_node(pane)
  if not core.root_panel then return nil end
  return panes().node(pane or "left")
end

function TitleBar:configure_hit_test(borderless)
  if borderless then
    local title_height = title_bar_height()
    local controls_width = caption_button_width() * #title_commands
    local left_x, _, left_width = self:get_pane_tabs_interactive_rect("left")
    local right_x, _, right_width = self:get_pane_tabs_interactive_rect("right")
    local _, _, resize_border = window_frame_metrics()
    system.set_window_hit_test(
      core.window,
      title_height,
      controls_width,
      math.floor(resize_border or 8 * SCALE),
      left_x,
      left_width,
      right_x,
      right_width
    )
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

function TitleBar:scroll_titlebar_tabs_to_active(pane, node)
  if not (node and node.views and node.active_view) then return end
  local views = pane_tab_views(node)
  local idx
  for i, view in ipairs(views) do
    if view == node.active_view then idx = i; break end
  end
  if not idx then return end
  local _, _, full_w = self:get_pane_tabs_rect(pane)
  if full_w <= 0 then return end
  local function visible_count_for_offset(offset)
    local _, _, w = self:get_titlebar_tabs_content_rect(pane, node, views, offset)
    local widths = self:get_titlebar_tab_widths(node, views, w)
    return math.max(1, visible_tab_count(widths, offset, w))
  end

  local capacity_changed = node.titlebar_tab_capacity ~= full_w
  node.titlebar_tab_capacity = full_w
  if node.manual_tab_scroll and not capacity_changed then return end
  if capacity_changed then node.manual_tab_scroll = nil end

  local offset = common.clamp(node.titlebar_tab_offset or 1, 1, math.max(1, #views))
  if idx < offset then offset = idx end
  local visible_count = visible_count_for_offset(offset)
  if idx > offset + visible_count - 1 then
    offset = idx - visible_count + 1
  end
  while offset > 1 do
    local candidate = offset - 1
    local candidate_visible_count = visible_count_for_offset(candidate)
    if idx > candidate + candidate_visible_count - 1 then break end
    offset = candidate
  end
  node.titlebar_tab_offset = common.clamp(offset, 1, math.max(1, #views))
end

function TitleBar:update()
  self.size.y = self.visible and title_bar_height() or 0
  title_commands[2] = core.window_mode == "maximized" and restore_command or maximize_command
  local signature = { tostring(self.size.x), tostring(title_tabs_x()) }
  for _, pane in ipairs({ "left", "right" }) do
    local node = self:get_tabs_node(pane)
    self:scroll_titlebar_tabs_to_active(pane, node)
    signature[#signature + 1] = tostring(#pane_tab_views(node))
    signature[#signature + 1] = tostring(node and node.titlebar_tab_offset or 0)
  end
  for _, pane in ipairs({ "left", "right" }) do
    local x, _, width = self:get_pane_tabs_interactive_rect(pane)
    signature[#signature + 1] = tostring(x)
    signature[#signature + 1] = tostring(width)
  end
  signature = table.concat(signature, ":")
  if self.last_configured_signature ~= signature then
    self.last_configured_signature = signature
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
  local title_x = logo_slot + style.padding.x * 2
  local right_x = self.size.x - controls_width - style.padding.x
  right_x = math.min(right_x, title_tabs_x() - style.padding.x)
  local x = ox + title_x
  local w = math.max(0, right_x - title_x)
  local title = truncate_text_right(style.font, current_project_title(), w)
  common.draw_text(style.font, color, title, "left", x, y, w, h)
end

local function allocate_cooperative_tab_widths(
  available_width, left_min, left_preferred, right_min, right_preferred
)
  local total_min = left_min + right_min
  local total_preferred = left_preferred + right_preferred

  if total_preferred <= available_width then
    return left_preferred, right_preferred
  end

  if total_min <= available_width then
    local distributable = available_width - total_min
    local left_flexible = left_preferred - left_min
    local right_flexible = right_preferred - right_min
    local total_flexible = left_flexible + right_flexible
    if total_flexible <= 0 then return left_min, right_min end
    return left_min + distributable * left_flexible / total_flexible,
      right_min + distributable * right_flexible / total_flexible
  end

  local populated = (left_min > 0 and 1 or 0) + (right_min > 0 and 1 or 0)
  if populated == 0 or available_width <= 0 then return 0, 0 end
  local base = available_width / populated
  local left_width = left_min > 0 and math.min(left_min, base) or 0
  local right_width = right_min > 0 and math.min(right_min, base) or 0
  local remaining = math.max(0, available_width - left_width - right_width)
  local left_unmet = math.max(0, left_min - left_width)
  local right_unmet = math.max(0, right_min - right_width)
  local total_unmet = left_unmet + right_unmet
  if total_unmet > 0 then
    left_width = left_width + remaining * left_unmet / total_unmet
    right_width = right_width + remaining * right_unmet / total_unmet
  end
  return left_width, right_width
end

function TitleBar:get_titlebar_layout()
  local lane_x = title_tabs_x()
  local controls_width = caption_button_width() * #title_commands
  local lane_right = math.max(lane_x, self.size.x - controls_width)
  local lane_width = math.max(0, lane_right - lane_x)
  local safe_width = math.min(lane_width,
    math.max(math.ceil(self.size.x * TITLEBAR_SAFE_ZONE_RATIO), titlebar_safe_zone_min_width()))
  local tabs_width = math.max(0, lane_width - safe_width)

  local left_node = self:get_tabs_node("left")
  local right_node = self:get_tabs_node("right")
  local left_views = pane_tab_views(left_node)
  local right_views = pane_tab_views(right_node)
  local left_min, left_preferred = titlebar_tab_width_demand(left_node, left_views)
  local right_min, right_preferred = titlebar_tab_width_demand(right_node, right_views)
  local left_width, right_width = allocate_cooperative_tab_widths(
    tabs_width, left_min, left_preferred, right_min, right_preferred)
  local right_x = lane_right - right_width
  local safe_x = lane_x + left_width
  return lane_x, left_width, safe_x, math.max(0, right_x - safe_x), right_x, right_width
end

function TitleBar:get_titlebar_safe_rect()
  local _, _, x, w = self:get_titlebar_layout()
  return x, 0, w, self.size.y
end

function TitleBar:get_pane_tabs_rect(pane)
  local left_x, left_width, _, _, right_x, right_width = self:get_titlebar_layout()
  if pane == "right" then return right_x, 0, right_width, self.size.y end
  return left_x, 0, left_width, self.size.y
end

function TitleBar:get_titlebar_tab_widths(node, views, available_width)
  local min_width, max_width = titlebar_tab_width_limits()
  local widths = {}
  local total_preferred = 0
  for i, view in ipairs(views) do
    local width = common.clamp(titlebar_tab_preferred_width(node, view), min_width, max_width)
    widths[i] = width
    total_preferred = total_preferred + width
  end

  local total_minimum = #views * min_width
  if total_preferred <= available_width or total_preferred <= total_minimum then
    return widths
  end
  if total_minimum > available_width then
    for i = 1, #widths do widths[i] = min_width end
    return widths
  end

  local ratio = (available_width - total_minimum) / (total_preferred - total_minimum)
  for i, width in ipairs(widths) do
    widths[i] = min_width + (width - min_width) * ratio
  end
  return widths
end

function TitleBar:get_titlebar_tabs_content_rect(pane, node, views, first_offset)
  local x, y, w, h = self:get_pane_tabs_rect(pane)
  views = views or pane_tab_views(node)
  if not node then return x, y, w, h, false, false end
  local bw = titlebar_scroll_button_width()
  local first = first_offset or node.titlebar_tab_offset or 1
  local show_previous = first > 1
  local show_next = false
  local full_w = w
  for _ = 1, 2 do
    local buttons = (show_previous and 1 or 0) + (show_next and 1 or 0)
    w = math.max(0, full_w - bw * buttons)
    local widths = self:get_titlebar_tab_widths(node, views, w)
    local visible_count = visible_tab_count(widths, first, w)
    show_next = first + visible_count - 1 < #views
  end
  local buttons = (show_previous and 1 or 0) + (show_next and 1 or 0)
  w = math.max(0, full_w - bw * buttons)
  local has_physical_left_button = pane == "right" and show_next or pane ~= "right" and show_previous
  if has_physical_left_button then x = x + bw end
  return x, y, w, h, show_previous, show_next
end

function TitleBar:get_titlebar_tabs_used_rect(pane, node, views)
  views = views or pane_tab_views(node)
  local x, y, w, h, show_previous, show_next = self:get_titlebar_tabs_content_rect(pane, node, views)
  if not node then return x, y, 0, h, false, false end
  local used_width = self:get_titlebar_tabs_used_width(node, views, w)
  if pane == "right" then x = x + w - used_width end
  return x, y, used_width, h, show_previous, show_next
end

function TitleBar:get_pane_tabs_interactive_rect(pane)
  local full_x, full_y, _, full_h = self:get_pane_tabs_rect(pane)
  local node = self:get_tabs_node(pane)
  local views = pane_tab_views(node)
  if not node or #views == 0 then return full_x, full_y, 0, full_h end

  local x, _, used_tabs_width, _, show_previous, show_next =
    self:get_titlebar_tabs_used_rect(pane, node, views)
  local bw = titlebar_scroll_button_width()
  local has_physical_left_button = pane == "right" and show_next or pane ~= "right" and show_previous
  local has_physical_right_button = pane == "right" and show_previous or pane ~= "right" and show_next
  if has_physical_left_button then x = x - bw end
  local interactive_width = used_tabs_width
    + (has_physical_left_button and bw or 0)
    + (has_physical_right_button and bw or 0)
  return x, full_y, interactive_width, full_h
end

function TitleBar:get_titlebar_tabs_used_width(node, views, available_width)
  local widths = self:get_titlebar_tab_widths(node, views, available_width)
  local first = node.titlebar_tab_offset or 1
  local visible_count = visible_tab_count(widths, first, available_width)
  local shown_count = math.max(0, math.min(#views - first + 1, visible_count))
  return sum_widths(widths, first, first + shown_count - 1)
end

function TitleBar:get_titlebar_scroll_button_at(px, py)
  for _, pane in ipairs({ "left", "right" }) do
    local node = self:get_tabs_node(pane)
    local views = pane_tab_views(node)
    local _, full_y, _, full_h = self:get_pane_tabs_rect(pane)
    local x, _, used_tabs_width, _, show_previous, show_next =
      self:get_titlebar_tabs_used_rect(pane, node, views)
    local bw = titlebar_scroll_button_width()
    if py >= full_y and py < full_y + full_h then
      if pane == "right" then
        if show_next and px >= x - bw and px < x then return pane, 2 end
        if show_previous and px >= x + used_tabs_width and px < x + used_tabs_width + bw then return pane, 1 end
      else
        if show_previous and px >= x - bw and px < x then return pane, 1 end
        if show_next and px >= x + used_tabs_width and px < x + used_tabs_width + bw then return pane, 2 end
      end
    end
  end
end

function TitleBar:get_titlebar_tab_rect(pane, node, views, idx)
  local x, y, w, h = self:get_titlebar_tabs_content_rect(pane, node, views)
  local widths = self:get_titlebar_tab_widths(node, views, w)
  local first = node.titlebar_tab_offset or 1
  local before = sum_widths(widths, first, idx - 1)
  local tab_width = widths[idx] or 0
  if pane == "right" then return x + w - before - tab_width, y, tab_width, h end
  return x + before, y, tab_width, h
end

function TitleBar:get_titlebar_tab_at(px, py)
  for _, pane in ipairs({ "left", "right" }) do
    local node = self:get_tabs_node(pane)
    local views = pane_tab_views(node)
    if node and #views > 0 then
      local x, y, w, h = self:get_titlebar_tabs_content_rect(pane, node, views)
      local widths = self:get_titlebar_tab_widths(node, views, w)
      local used_width = self:get_titlebar_tabs_used_width(node, views, w)
      local used_x = pane == "right" and x + w - used_width or x
      if px >= used_x and px < used_x + used_width and py >= y and py < y + h then
        local first = node.titlebar_tab_offset or 1
        local visible_count = visible_tab_count(widths, first, w)
        for idx = first, math.min(#views, first + visible_count - 1) do
          local tab_x, _, tab_width = self:get_titlebar_tab_rect(pane, node, views, idx)
          if px >= tab_x and px < tab_x + tab_width then
            return pane, node, views[idx], idx
          end
        end
      end
    end
  end
end

local draw_caption_glyph

function TitleBar:draw_titlebar_tabs()
  local focused_pane = panes().focused_pane()
  for _, pane in ipairs({ "left", "right" }) do
    local node = self:get_tabs_node(pane)
    local views = pane_tab_views(node)
    if node and #views > 0 then
      local opacity = pane == "right" and not panes().right_visible()
        and HIDDEN_RIGHT_TABS_OPACITY or 1
      local function pane_color(color)
        return color_faded_over_titlebar(color, opacity)
      end
      local _, full_y, _, full_h = self:get_pane_tabs_rect(pane)
      local x, y, w, h, show_previous, show_next = self:get_titlebar_tabs_content_rect(pane, node, views)
      local widths = self:get_titlebar_tab_widths(node, views, w)
      local used_tabs_width = self:get_titlebar_tabs_used_width(node, views, w)
      local used_x = pane == "right" and x + w - used_tabs_width or x
      local ds = style.divider_size
      local bw = titlebar_scroll_button_width()
      local hovered_scroll = self.hovered_tab_scroll_pane == pane and self.hovered_tab_scroll_button
      if pane == "right" then
        if show_next then
          renderer.draw_rect(used_x - bw, full_y, bw, full_h, pane_color(hovered_scroll == 2 and style.titlebar_tab_hover or style.titlebar))
          common.draw_text(style.font, pane_color(style.text), "‹", "center", used_x - bw, full_y, bw, full_h)
        end
        if show_previous then
          renderer.draw_rect(used_x + used_tabs_width, full_y, bw, full_h, pane_color(hovered_scroll == 1 and style.titlebar_tab_hover or style.titlebar))
          common.draw_text(style.font, pane_color(style.text), "›", "center", used_x + used_tabs_width, full_y, bw, full_h)
        end
      else
        if show_previous then
          renderer.draw_rect(used_x - bw, full_y, bw, full_h, pane_color(hovered_scroll == 1 and style.titlebar_tab_hover or style.titlebar))
          common.draw_text(style.font, pane_color(style.text), "‹", "center", used_x - bw, full_y, bw, full_h)
        end
        if show_next then
          renderer.draw_rect(used_x + used_tabs_width, full_y, bw, full_h, pane_color(hovered_scroll == 2 and style.titlebar_tab_hover or style.titlebar))
          common.draw_text(style.font, pane_color(style.text), "›", "center", used_x + used_tabs_width, full_y, bw, full_h)
        end
      end
      core.push_clip_rect(used_x, y, used_tabs_width, h)
      local first = node.titlebar_tab_offset or 1
      local last = math.min(#views, first + visible_tab_count(widths, first, w) - 1)
      for i = first, last do
        local view = views[i]
        local tx, ty, tab_w, tab_h = self:get_titlebar_tab_rect(pane, node, views, i)
        local selected = view == node.active_view
        local hovered = self.hovered_tab_pane == pane and self.hovered_tab_view == view
        if selected then
          renderer.draw_rect(tx, ty, tab_w, tab_h, pane_color(style.background))
        end
        if hovered then
          renderer.draw_rect(tx, ty, tab_w, tab_h, pane_color(style.titlebar_tab_hover))
        end
        if selected and focused_pane == pane then
          renderer.draw_rect(tx, ty + tab_h - ds, tab_w, ds, pane_color(style.caret))
        end
        local separator_h = math.max(0, tab_h - ds)
        renderer.draw_rect(tx, ty, ds, separator_h, pane_color(style.titlebar_tab_separator))
        renderer.draw_rect(tx + tab_w - ds, ty, ds, separator_h, pane_color(style.titlebar_tab_separator))
        local title_color = pane_color((selected or hovered) and style.text or style.dim)
        local title_x = tx + style.padding.x
        local title_w = math.max(0, tab_w - style.padding.x * 2)
        core.push_clip_rect(title_x, ty, title_w, tab_h)
        node:draw_tab_title(view, node:get_tab_title_font(), selected, hovered,
          title_x, ty, title_w, tab_h, title_color)
        core.pop_clip_rect()
      end
      core.pop_clip_rect()
    end
  end
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
        renderer.draw_rect(x, y, w, h, pressed and style.titlebar_close_pressed or style.titlebar_close_hover)
      else
        renderer.draw_rect(x, y, w, h, pressed and style.titlebar_control_pressed or style.titlebar_control_hover)
      end
    end
    local color = (hovered and item.id == "close") and style.titlebar_close_text or (self:has_window_focus() and style.text or style.dim)
    draw_caption_glyph(item, x, y, w, h, color)
  end
end


function TitleBar:on_mouse_pressed(button, x, y, clicks)
  TitleBar.super.on_mouse_pressed(self, button, x, y, clicks)
  if button == "left" then
    self.pressed_item = self.hovered_item
    self.pressed_tab_view = self.hovered_tab_view
    self.pressed_tab_pane = self.hovered_tab_pane
    self.pressed_tab_scroll_button = self.hovered_tab_scroll_button
    self.pressed_tab_scroll_pane = self.hovered_tab_scroll_pane
  end
end

function TitleBar:on_mouse_released(button, x, y)
  TitleBar.super.on_mouse_released(self, button, x, y)
  core.set_active_view(core.last_active_view)
  local item = self.hovered_item
  if button == "left" and item and item == self.pressed_item then
    item.action()
  elseif self.hovered_tab_scroll_button
  and self.hovered_tab_scroll_button == self.pressed_tab_scroll_button
  and self.hovered_tab_scroll_pane == self.pressed_tab_scroll_pane then
    local node = self:get_tabs_node(self.hovered_tab_scroll_pane)
    if node then
      local delta = self.hovered_tab_scroll_button == 1 and -1 or 1
      node.titlebar_tab_offset = common.clamp((node.titlebar_tab_offset or 1) + delta, 1, math.max(1, #pane_tab_views(node)))
      node.manual_tab_scroll = true
    end
  elseif self.hovered_tab_view then
    local pane, node, view = self:get_titlebar_tab_at(x, y)
    if node and view == self.hovered_tab_view and pane == self.hovered_tab_pane then
      if button == "middle" then
        panes().close_view(view)
      elseif button == "left" and view == self.pressed_tab_view and pane == self.pressed_tab_pane then
        node:set_active_view(view)
        panes().show(pane, { view = view, focus = true })
      end
    end
  end
  self.pressed_item = nil
  self.pressed_tab_view = nil
  self.pressed_tab_pane = nil
  self.pressed_tab_scroll_button = nil
  self.pressed_tab_scroll_pane = nil
end


function TitleBar:on_mouse_left()
  TitleBar.super.on_mouse_left(self)
  self.hovered_item = nil
  self.hovered_tab_view = nil
  self.hovered_tab_pane = nil
  self.hovered_tab_scroll_button = nil
  self.hovered_tab_scroll_pane = nil
  self.pressed_item = nil
  self.pressed_tab_view = nil
  self.pressed_tab_pane = nil
  self.pressed_tab_scroll_button = nil
  self.pressed_tab_scroll_pane = nil
end

function TitleBar:on_mouse_wheel(y, x)
  if not self.hovered_tab_view then return end
  local pane = self.hovered_tab_pane
  local node = self:get_tabs_node(pane)
  local views = pane_tab_views(node)
  if #views < 2 then return true end
  local idx = 1
  for i, view in ipairs(views) do if view == node.active_view then idx = i; break end end
  idx = idx + (y > 0 and -1 or 1)
  if idx < 1 then idx = #views end
  if idx > #views then idx = 1 end
  node:set_active_view(views[idx])
  panes().show(pane, { view = views[idx], focus = true })
  return true
end


function TitleBar:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  TitleBar.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  self.hovered_tab_view = nil
  self.hovered_tab_pane = nil
  self.hovered_tab_scroll_pane, self.hovered_tab_scroll_button = self:get_titlebar_scroll_button_at(px, py)
  if self.hovered_tab_scroll_button then return end
  local pane, _, view = self:get_titlebar_tab_at(px, py)
  if pane and view then
    self.hovered_tab_pane = pane
    self.hovered_tab_view = view
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
  self:draw_background(style.titlebar)
  self:draw_window_title()
  self:draw_titlebar_tabs()
  self:draw_window_controls()
  renderer.draw_rect(
    self.position.x,
    self.position.y + self.size.y - style.divider_size,
    self.size.x,
    style.divider_size,
    style.divider
  )
end

return TitleBar
