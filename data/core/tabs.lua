local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Object = require "core.object"
local View = require "core.view"

---Reusable tab bar renderer/controller.
---
---The owner is any view-like object with `position`, `size`, `tab_offset`,
---`tab_shift`, `hovered_tab`, and `hovered_scroll_button` fields. By default
---tabs are read from `owner.views` and the active tab is `owner.active_view`.
---@class core.tabs : core.object
---@overload fun(owner:table, options?:table):core.tabs
local Tabs = Object:extend()

function Tabs:__tostring() return "Tabs" end

---@param owner table
---@param options? table
function Tabs:new(owner, options)
  assert(owner, "tab owner expected")
  self.owner = owner
  self.options = options or {}
  owner.tab_shift = owner.tab_shift or 0
  owner.tab_offset = owner.tab_offset or 1
  owner.hovered_scroll_button = owner.hovered_scroll_button or 0
  owner.move_towards = owner.move_towards or View.move_towards
end

local function tab_min_width()
  return math.max(1, style.tab_min_width or style.tab_width or 1)
end

local function tab_max_width()
  return math.max(tab_min_width(), style.tab_max_width or style.tab_width or tab_min_width())
end

local function tab_gap()
  return 5 * SCALE
end

local function get_scroll_button_width()
  local w = style.font:get_width(">")
  local pad = math.max(7 * SCALE, math.floor(w * 1.25))
  return w + 2 * pad, pad
end

local function default_items(owner)
  return owner.views or {}
end

local function default_active_item(owner)
  return owner.active_view
end

local function default_title(item)
  return item and item.get_name and item:get_name() or ""
end

function Tabs:items()
  local get_items = self.options.get_items or default_items
  return get_items(self.owner, self) or {}
end

function Tabs:item_count()
  return #self:items()
end

function Tabs:item(idx)
  return self:items()[idx]
end

function Tabs:active_item()
  local get_active_item = self.options.get_active_item or default_active_item
  return get_active_item(self.owner, self)
end

function Tabs:get_item_index(item)
  for i, candidate in ipairs(self:items()) do
    if candidate == item then return i end
  end
end

function Tabs:get_item_title(item)
  if self.options.get_title then
    return self.options.get_title(self.owner, item, self) or ""
  end
  return default_title(item) or ""
end

function Tabs:get_position()
  local fn = self.options.get_position
  return fn and fn(self.owner, self) or self.owner.position
end

function Tabs:get_size()
  local fn = self.options.get_size
  return fn and fn(self.owner, self) or self.owner.size
end

local function tab_title_font()
  return style.get_small_font(style.font)
end

function Tabs:get_tab_title_font()
  return tab_title_font()
end

function Tabs:get_tab_title_width(item)
  local text = self:get_item_title(item)
  return tab_title_font():get_width(text) + style.padding.x * 2 + style.divider_size * 2
end

function Tabs:get_tab_width(idx)
  local custom = self.options.get_tab_width
  if custom then
    local width = custom(self.owner, idx, self:item(idx), tab_title_font(), self)
    if width then return common.clamp(width, tab_min_width(), tab_max_width()) end
  end
  return common.clamp(self:get_tab_title_width(self:item(idx)), tab_min_width(), tab_max_width())
end

function Tabs:get_tabs_width(first, last)
  if last < first then return 0 end
  local width = 0
  for i = first, last do
    width = width + self:get_tab_width(i)
  end
  return width + tab_gap() * math.max(0, last - first)
end

function Tabs:should_show()
  if self.options.should_show then
    return self.options.should_show(self.owner, self)
  end
  return self:item_count() > 1
end

---Get the number of tabs currently visible (not scrolled out of view).
---@return integer count Number of visible tabs
function Tabs:get_visible_tabs_number()
  local count = self:item_count()
  local offset = self.owner.tab_offset or 1
  local remaining = count - offset + 1
  if remaining <= 0 then return 0 end

  local available = self:get_size().x
  if offset > 1 or self:get_tabs_width(offset, count) > available then
    available = math.max(1, available - get_scroll_button_width() * 2)
  end

  local used = 0
  local visible = 0
  for i = offset, count do
    local width = self:get_tab_width(i)
    local gap = visible > 0 and tab_gap() or 0
    if visible > 0 and used + gap + width > available then break end
    used = used + gap + width
    visible = visible + 1
  end
  return math.max(1, visible)
end

---Get the index of the tab under a screen point.
---@param px number Screen x coordinate
---@param py number Screen y coordinate
---@return integer? idx Tab index, or nil if not over any tab
function Tabs:get_tab_overlapping_point(px, py)
  if not self:should_show() then return nil end
  local tabs_number = self:get_visible_tabs_number()
  if self:item_count() > tabs_number then
    local tabs_w = math.max(1, self:get_size().x - get_scroll_button_width() * 2)
    if px >= self:get_position().x + tabs_w then return nil end
  end
  local offset = self.owner.tab_offset or 1
  for i = offset, offset + tabs_number - 1 do
    local x, y, w, h = self:get_tab_rect(i)
    if px >= x and py >= y and px < x + w and py < y + h then
      return i
    end
  end
end

function Tabs:can_scroll_tabs(dir)
  if self:item_count() <= 1 then return false end
  if dir == 1 then
    return (self.owner.tab_offset or 1) > 1
  elseif dir == 2 then
    return (self.owner.tab_offset or 1) + self:get_visible_tabs_number() - 1 < self:item_count()
  end
  return false
end

function Tabs:get_scroll_button_index(px, py)
  if self:item_count() == 1 then return end
  for i = 1, 2 do
    if self:can_scroll_tabs(i) then
      local x, y, w, h = self:get_scroll_button_rect(i)
      if px >= x and px < x + w and py >= y and py < y + h then
        return i
      end
    end
  end
end

---Update hover state for tabs and scroll buttons.
---@param px number Screen x coordinate
---@param py number Screen y coordinate
function Tabs:update_hover(px, py)
  self.owner.hovered_scroll_button = 0
  if not self:should_show() then self.owner.hovered_tab = nil return end
  local tab_index = self:get_tab_overlapping_point(px, py)
  self.owner.hovered_tab = tab_index
  if not tab_index and self:item_count() > self:get_visible_tabs_number() then
    self.owner.hovered_scroll_button = self:get_scroll_button_index(px, py) or 0
  end
end

---Calculate tab bar vertical dimensions.
---@return number height Total tab height
---@return number padding Vertical padding
---@return number margin Top margin
function Tabs:get_tab_y_sizes()
  local height = style.font:get_height()
  local padding = style.padding.y
  local margin = style.margin.tab.top
  return height + (padding * 2) + margin, padding, margin
end

function Tabs:get_height()
  local height = self:get_tab_y_sizes()
  return height
end

---Get the rectangle for a scroll button.
---@param index integer Button index (1=left, 2=right)
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Width
---@return number h Height
---@return number pad Padding amount
function Tabs:get_scroll_button_rect(index)
  local w, pad = get_scroll_button_width()
  local h = self:get_tab_y_sizes()
  local position = self:get_position()
  local size = self:get_size()
  local x = position.x + (index == 1 and size.x - w * 2 or size.x - w)
  return x, position.y, w, h, pad
end

---Get the rectangle for a tab.
---@param idx integer Tab index
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Width
---@return number h Height
---@return number margin_y Top margin
function Tabs:get_tab_rect(idx)
  local position = self:get_position()
  local before = self:get_tabs_width(1, idx - 1) - (self.owner.tab_shift or 0)
  local x1 = position.x + before
  local x2 = x1 + self:get_tab_width(idx)
  local h, _, margin_y = self:get_tab_y_sizes()
  return x1, position.y, x2 - x1, h, margin_y
end

local function tab_available_width(tabbar, first)
  local available = tabbar:get_size().x
  if first > 1 or tabbar:get_tabs_width(first, tabbar:item_count()) > available then
    available = math.max(1, available - get_scroll_button_width() * 2)
  end
  return available
end

---Ensure an item tab is visible (not scrolled out of view).
---Defaults to the active item.
---@param index? integer Item index to reveal
function Tabs:scroll_to_visible(index)
  index = index or self:get_item_index(self:active_item())
  if index then
    if self.owner.manual_tab_scroll then
      return
    end
    local old_offset = self.owner.tab_offset or 1
    local tabs_number = self:get_visible_tabs_number()
    if old_offset > index then
      self.owner.tab_offset = index
    elseif old_offset + tabs_number - 1 < index then
      self.owner.tab_offset = index - tabs_number + 1
    end

    -- When the owner grows wider, pull earlier tabs back into view as soon as
    -- they fit. Without this, an offset chosen for a narrow window can stay
    -- stuck at the active tab, leaving the tab bar mostly empty after resizing.
    while (self.owner.tab_offset or 1) > 1 do
      local candidate = (self.owner.tab_offset or 1) - 1
      if self:get_tabs_width(candidate, index) > tab_available_width(self, candidate) then
        break
      end
      self.owner.tab_offset = candidate
    end

    if self.owner.tab_offset ~= old_offset then
      core.log_quiet(
        "%s: adjusted tab offset %d -> %d for active tab %d/%d at width %.0f",
        self.options.log_prefix or "Tabs", old_offset, self.owner.tab_offset, index, self:item_count(), self:get_size().x or 0
      )
    end
  end
end

---Scroll the tab bar left or right.
---@param dir integer Direction: 1=left, 2=right
function Tabs:scroll_tabs(dir)
  if self:can_scroll_tabs(dir) then
    local old_offset = self.owner.tab_offset or 1
    self.owner.tab_offset = old_offset + (dir == 1 and -1 or 1)
    self.owner.manual_tab_scroll = true
    core.log_quiet(
      "%s: paged %s tab offset %d -> %d at width %.0f",
      self.options.log_prefix or "Tabs", dir == 1 and "left" or "right", old_offset, self.owner.tab_offset, self:get_size().x or 0
    )
  end
end

function Tabs:target_tab_shift()
  return self:get_tabs_width(1, (self.owner.tab_offset or 1) - 1)
end

function Tabs:update_animation()
  self.owner:move_towards("tab_shift", self:target_tab_shift(), nil, self.options.transition_group or "tabs")
end

function Tabs:update(px, py)
  self:scroll_to_visible()
  if px and py then
    self:update_hover(px, py)
  end
  self:update_animation()
end

---Draw a tab's title text with ellipsis if needed.
---@param item any Tab item
---@param font renderer.font Font to use
---@param is_active boolean Whether this is the active tab
---@param is_hovered boolean Whether mouse is over this tab
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Width
---@param h number Height
function Tabs:draw_tab_title(item, font, is_active, is_hovered, x, y, w, h)
  local text = self:get_item_title(item)
  local dots_width = font:get_width("…")
  local align = "left"
  if font:get_width(text) > w then
    local text_len = text:ulen()
    for i = 1, text_len do
      local reduced_text = text:usub(1, text_len - i)
      if font:get_width(reduced_text) + dots_width <= w then
        text = reduced_text .. "…"
        break
      end
    end
  end
  local color = style.dim
  if is_active then color = style.text end
  if is_hovered then color = style.text end
  common.draw_text(font, color, text, align, x, y, w, h)
end

---Draw tab borders and background.
---@param item any Tab item
---@param is_active boolean Whether this is the active tab
---@param is_hovered boolean Whether mouse is over this tab
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Width
---@param h number Height
---@param standalone boolean If true, draw standalone tab (during drag)
---@return number x Adjusted x for content area
---@return number y Adjusted y for content area
---@return number w Adjusted width for content area
---@return number h Adjusted height for content area
function Tabs:draw_tab_borders(item, is_active, is_hovered, x, y, w, h, standalone)
  local ds = style.divider_size
  local margin_y = style.margin.tab.top or 0
  local tab_color = style.tab_background or { 0x1c, 0x1e, 0x26, 255 }
  renderer.draw_rect(x, y - margin_y, w, h + margin_y, tab_color)
  return x + ds, y, w - ds*2, h
end

---Draw a complete tab.
---@param item any Tab item
---@param is_active boolean Whether this is the active tab
---@param is_hovered boolean Whether mouse is over this tab
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param w number Width
---@param h number Height
---@param standalone boolean If true, draw standalone tab (during drag)
---@param hooks? table Optional draw hooks (`draw_borders`, `draw_title`)
function Tabs:draw_tab(item, is_active, is_hovered, x, y, w, h, standalone, hooks)
  local _, _, margin_y = self:get_tab_y_sizes()
  local draw_borders = (hooks and hooks.draw_borders) or self.options.draw_borders
  local draw_title = (hooks and hooks.draw_title) or self.options.draw_title
  if draw_borders then
    x, y, w, h = draw_borders(self, item, is_active, is_hovered, x, y + margin_y, w, h - margin_y, standalone)
  else
    x, y, w, h = self:draw_tab_borders(item, is_active, is_hovered, x, y + margin_y, w, h - margin_y, standalone)
  end
  x = x + style.padding.x
  w = w - style.padding.x * 2
  core.push_clip_rect(x, y, w, h)
  if draw_title then
    draw_title(self, item, tab_title_font(), is_active, is_hovered, x, y, w, h)
  else
    self:draw_tab_title(item, tab_title_font(), is_active, is_hovered, x, y, w, h)
  end
  core.pop_clip_rect()
end

---Draw the entire tab bar including all visible tabs and scroll buttons.
---@param hooks? table Optional draw hooks (`draw_tab`, `draw_borders`, `draw_title`)
function Tabs:draw_tabs(hooks)
  local _, y, _, h = self:get_scroll_button_rect(1)
  local position = self:get_position()
  local size = self:get_size()
  local x = position.x
  core.push_clip_rect(x, y, size.x, h)
  renderer.draw_rect(x, y, size.x, h, style.tab_background or { 0x1c, 0x1e, 0x26, 255 })
  local tabs_number = self:get_visible_tabs_number()
  local show_scroll_buttons = self:item_count() > tabs_number
  local tabs_clip_w = show_scroll_buttons and math.max(1, size.x - get_scroll_button_width() * 2) or size.x

  core.push_clip_rect(x, y, tabs_clip_w, h)
  local draw_tab = (hooks and hooks.draw_tab) or self.options.draw_tab
  local offset = self.owner.tab_offset or 1
  for i = offset, offset + tabs_number - 1 do
    local item = self:item(i)
    if not item then break end
    local tx, ty, tw, th = self:get_tab_rect(i)
    local active = item == self:active_item()
    local hovered = i == self.owner.hovered_tab
    if draw_tab then
      draw_tab(self, item, active, hovered, tx, ty, tw, th)
    else
      self:draw_tab(item, active, hovered, tx, ty, tw, th, nil, hooks)
    end
  end
  core.pop_clip_rect()

  if show_scroll_buttons then
    local inactive_color = style.line_number or style.dim
    local chevron_font = style.font
    local xrb, yrb, wrb = self:get_scroll_button_rect(1)
    local left_enabled = self:can_scroll_tabs(1)
    local left_button_style = left_enabled and (self.owner.hovered_scroll_button == 1 and style.text or style.dim) or inactive_color
    common.draw_text(chevron_font, left_button_style, "<", "center", xrb, yrb, wrb, h)

    xrb, yrb, wrb = self:get_scroll_button_rect(2)
    local right_enabled = self:can_scroll_tabs(2)
    local right_button_style = right_enabled and (self.owner.hovered_scroll_button == 2 and style.text or style.dim) or inactive_color
    common.draw_text(chevron_font, right_button_style, ">", "center", xrb, yrb, wrb, h)
  end

  core.pop_clip_rect()
end

---Check if a point is in the tab bar area.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean in_tabs True if point is over the tab bar
function Tabs:is_in_tab_area(x, y)
  if not self:should_show() then return false end
  local _, ty, _, th = self:get_scroll_button_rect(1)
  return y >= ty and y < ty + th
end

---Calculate where a dragged tab would be inserted.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param dragged_owner? table Owner being dragged from
---@param dragged_index? integer Index of tab being dragged
---@return integer tab_index Index where tab would be inserted
---@return number tab_x Overlay x position
---@return number tab_y Overlay y position
---@return number tab_w Overlay width
---@return number tab_h Overlay height
function Tabs:get_drag_overlay_tab_position(x, y, dragged_owner, dragged_index)
  local tab_index = self:get_tab_overlapping_point(x, y)
  if not tab_index then
    local first_tab_x = self:get_tab_rect(1)
    if x < first_tab_x then
      -- mouse before first visible tab
      tab_index = self.owner.tab_offset or 1
    else
      -- mouse after last visible tab
      tab_index = self:get_visible_tabs_number() + ((self.owner.tab_offset or 1) - 1)
    end
  end
  local tab_x, tab_y, tab_w, tab_h, margin_y = self:get_tab_rect(tab_index)
  if x > tab_x + tab_w / 2 and tab_index <= self:item_count() then
    -- use next tab
    tab_x = tab_x + tab_w
    tab_index = tab_index + 1
  end
  if self.owner == dragged_owner and dragged_index and tab_index > dragged_index then
    -- the tab we are moving is counted in tab_index
    tab_index = tab_index - 1
    tab_x = tab_x - tab_w
  end
  return tab_index, tab_x, tab_y + margin_y, tab_w, tab_h - margin_y
end

return Tabs
