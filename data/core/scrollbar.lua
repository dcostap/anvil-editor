local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Object = require "core.object"

---@class core.scrollbar.rect
---@field x number
---@field y number
---@field w number
---@field h number
---@field scrollable number Total scrollable size

---@class core.scrollbar.normal_rect
---@field across number Position perpendicular to scroll direction
---@field along number Position parallel to scroll direction
---@field across_size number Size perpendicular to scroll direction
---@field along_size number Size parallel to scroll direction
---@field scrollable number Total scrollable size

---@class core.scrollbar.hovering
---@field track boolean True if mouse is over track
---@field thumb boolean True if mouse is over thumb

---Configuration options for creating a scrollbar.
---@class core.scrollbar.options
---@field direction? "v"|"h" Vertical or Horizontal (default: "v")
---@field alignment? "s"|"e" Start or End - left/top vs right/bottom (default: "e")
---@field force_status? "expanded"|"contracted"|false Force display state
---@field expanded_size? number Override style.expanded_scrollbar_size
---@field contracted_size? number Override style.scrollbar_size
---@field minimum_thumb_size? number Override style.minimum_thumb_size
---@field contracted_margin? number Override style.contracted_scrollbar_margin
---@field expanded_margin? number Override style.expanded_scrollbar_margin

---Scrollable viewport indicator with draggable thumb.
---Supports both vertical and horizontal orientation with configurable alignment.
---Uses a "normal" coordinate system internally that treats all scrollbars as
---vertical-end-aligned, then transforms to the actual orientation/alignment.
---@class core.scrollbar : core.object
---@overload fun(options: core.scrollbar.options):core.scrollbar
---@field rect core.scrollbar.rect Bounding box of the owning view
---@field normal_rect core.scrollbar.normal_rect Normalized coordinate system rect
---@field percent number Scroll position [0-1]
---@field dragging boolean True when user is dragging the thumb
---@field drag_start_offset number Offset from thumb top when drag started
---@field hovering core.scrollbar.hovering What parts are currently hovered
---@field direction "v"|"h" Vertical or horizontal orientation
---@field alignment "s"|"e" Start or end position (left/top vs right/bottom)
---@field expand_percent number Animation state [0-1] for hover expansion
---@field force_status "expanded"|"contracted"|false? Forced display state
---@field contracted_size number? Override for style.scrollbar_size
---@field expanded_size number? Override for style.expanded_scrollbar_size
---@field minimum_thumb_size number? Override for style.minimum_thumb_size
---@field contracted_margin number? Override for style.contracted_scrollbar_margin
---@field expanded_margin number? Override for style.expanded_scrollbar_margin
local Scrollbar = Object:extend()

local function blend_color(a, b, t)
  if not b or t <= 0 then return a end
  if t >= 1 then return b end
  return {
    (a[1] or 0) + ((b[1] or 0) - (a[1] or 0)) * t,
    (a[2] or 0) + ((b[2] or 0) - (a[2] or 0)) * t,
    (a[3] or 0) + ((b[3] or 0) - (a[3] or 0)) * t,
    (a[4] or 255) + ((b[4] or 255) - (a[4] or 255)) * t,
  }
end

local function lighten_color(color, amount)
  amount = amount or 44
  return {
    common.clamp((color[1] or 0) + amount, 0, 255),
    common.clamp((color[2] or 0) + amount, 0, 255),
    common.clamp((color[3] or 0) + amount, 0, 255),
    color[4] or 255,
  }
end

function Scrollbar:__tostring() return "Scrollbar" end

---Constructor - initializes a scrollbar with specified orientation and style.
---@param options core.scrollbar.options Configuration options
function Scrollbar:new(options)
  ---Position information of the owner
  self.rect = {
    x = 0, y = 0, w = 0, h = 0,
    ---Scrollable size
    scrollable = 0
  }
  self.normal_rect = {
    across = 0,
    along = 0,
    across_size = 0,
    along_size = 0,
    scrollable = 0
  }
  self.percent = 0
  self.dragging = false
  self.drag_start_offset = 0
  self.hovering = { track = false, thumb = false }
  self.direction = options.direction or "v"
  self.alignment = options.alignment or "e"
  self.expand_percent = 0
  self.hover_tint_percent = 0
  self.force_status = options.force_status
  self:set_forced_status(options.force_status)
  self.contracted_size = options.contracted_size
  self.expanded_size = options.expanded_size
  self.minimum_thumb_size = options.minimum_thumb_size
  self.contracted_margin = options.contracted_margin
  self.expanded_margin = options.expanded_margin
end


---Set the forced display status of the scrollbar.
---When forced, the scrollbar won't animate based on hover state.
---@param status "expanded"|"contracted"|false Status to force (false to allow auto-animation)
function Scrollbar:set_forced_status(status)
  self.force_status = status
  if self.force_status == "expanded" then
    self.expand_percent = 1
  end
end


---Transform real coordinates to normalized coordinate system.
---Internal helper for orientation/alignment handling.
---@param x number? Real x coordinate
---@param y number? Real y coordinate
---@param w number? Real width
---@param h number? Real height
---@return number x Normalized x
---@return number y Normalized y
---@return number w Normalized width
---@return number h Normalized height
function Scrollbar:real_to_normal(x, y, w, h)
  x, y, w, h = x or 0, y or 0, w or 0, h or 0
  if self.direction == "v" then
    if self.alignment == "s" then
      x = (self.rect.x + self.rect.w) - x - w
    end
    return x, y, w, h
  else
    if self.alignment == "s" then
      y = (self.rect.y + self.rect.h) - y - h
    end
    return y, x, h, w
  end
end


---Transform normalized coordinates back to real coordinate system.
---Internal helper for orientation/alignment handling.
---@param x number? Normalized x coordinate
---@param y number? Normalized y coordinate
---@param w number? Normalized width
---@param h number? Normalized height
---@return number x Real x
---@return number y Real y
---@return number w Real width
---@return number h Real height
function Scrollbar:normal_to_real(x, y, w, h)
  x, y, w, h = x or 0, y or 0, w or 0, h or 0
  if self.direction == "v" then
    if self.alignment == "s" then
      x = (self.rect.x + self.rect.w) - x - w
    end
    return x, y, w, h
  else
    if self.alignment == "s" then
      x = (self.rect.y + self.rect.h) - x - w
    end
    return y, x, h, w
  end
end


---Get thumb rectangle in normalized coordinates.
---Internal helper - use get_thumb_rect() for real coordinates.
---@return number x Normalized x coordinate
---@return number y Normalized y coordinate
---@return number w Normalized width
---@return number h Normalized height
function Scrollbar:_get_thumb_rect_normal()
  local nr = self.normal_rect
  local sz = nr.scrollable
  if sz == math.huge or sz <= nr.along_size
  then
    return 0, 0, 0, 0
  end
  local scrollbar_size = self.contracted_size or style.scrollbar_size
  local expanded_scrollbar_size = self.expanded_size or style.expanded_scrollbar_size
  local along_size = math.max(self.minimum_thumb_size or style.minimum_thumb_size, nr.along_size * nr.along_size / sz)
  local across_size = scrollbar_size
  across_size = across_size + (expanded_scrollbar_size - scrollbar_size) * self.expand_percent
  local end_padding = self:get_end_padding()
  return
    nr.across + nr.across_size - across_size - end_padding,
    nr.along + self.percent * (nr.along_size - along_size),
    across_size,
    along_size
end


---Get the thumb rectangle (the draggable part of the scrollbar).
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Width in pixels
---@return number h Height in pixels
function Scrollbar:get_thumb_rect()
  return self:normal_to_real(self:_get_thumb_rect_normal())
end


---Get track rectangle in normalized coordinates.
---Internal helper - use get_track_rect() for real coordinates.
---@return number x Normalized x coordinate
---@return number y Normalized y coordinate
---@return number w Normalized width
---@return number h Normalized height
function Scrollbar:_get_track_rect_normal()
  local nr = self.normal_rect
  local sz = nr.scrollable
  if sz <= nr.along_size or sz == math.huge then
    return 0, 0, 0, 0
  end
  local scrollbar_size = self.contracted_size or style.scrollbar_size
  local expanded_scrollbar_size = self.expanded_size or style.expanded_scrollbar_size
  local across_size = scrollbar_size
  across_size = across_size + (expanded_scrollbar_size - scrollbar_size) * self.expand_percent
  local end_padding = self:get_end_padding()
  return
    nr.across + nr.across_size - across_size - end_padding,
    nr.along,
    across_size,
    nr.along_size
end


---Get the track rectangle (the background of the scrollbar).
---@return number x Screen x coordinate
---@return number y Screen y coordinate
---@return number w Width in pixels
---@return number h Height in pixels
function Scrollbar:get_track_rect()
  return self:normal_to_real(self:_get_track_rect_normal())
end


---Check what part of scrollbar overlaps a point in normalized coordinates.
---Internal helper - use overlaps() for real coordinates.
---@param x number Normalized x coordinate
---@param y number Normalized y coordinate
---@return "thumb"|"track"|nil part What was hit, or nil if nothing
function Scrollbar:_overlaps_normal(x, y)
  local nr = self.normal_rect
  local sz = nr.scrollable
  if sz <= nr.along_size or sz == math.huge then return nil end

  -- Keep the interaction band close to the rendered scrollbar.  The thumb is
  -- intentionally easier to grab than the visible rect, but only by a small
  -- amount on the leading/left side; using the fully-expanded width here made
  -- the contracted scrollbar claim too much editor space.
  local tx, _, tw = self:_get_track_rect_normal()
  local leading_pad = style.scrollbar_hitbox_leading_padding
    or math.floor((style.contracted_scrollbar_margin or 0) * 0.5)
  local sx = tx - leading_pad
  local sw = tw + leading_pad
  if x < sx or x > sx + sw or y < nr.along or y > nr.along + nr.along_size then
    return nil
  end

  local _, ty, _, th = self:_get_thumb_rect_normal()
  if y >= ty and y <= ty + th then
    return "thumb"
  end
  return "track"
end


---Check what part of the scrollbar overlaps a screen point.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return "thumb"|"track"|nil part What was hit, or nil if nothing
function Scrollbar:overlaps(x, y)
  if self:_in_resize_edge_guard(x, y) then return nil end
  x, y = self:real_to_normal(x, y)
  return self:_overlaps_normal(x, y)
end


---Handle mouse press in normalized coordinates.
---Internal helper - use on_mouse_pressed() for real coordinates.
---@param button core.view.mousebutton
---@param x number Normalized x coordinate
---@param y number Normalized y coordinate
---@param clicks integer Number of clicks
---@return boolean|number result True if thumb clicked, 0-1 percent if track clicked, falsy otherwise
function Scrollbar:_on_mouse_pressed_normal(button, x, y, clicks)
  local overlaps = self:_overlaps_normal(x, y)
  if overlaps then
    local _, along, _, along_size = self:_get_thumb_rect_normal()
    self.dragging = true
    if overlaps == "thumb" then
      self.drag_start_offset = along - y
      return true
    elseif overlaps == "track" then
      local nr = self.normal_rect
      self.drag_start_offset = - along_size / 2
      return common.clamp((y - nr.along - along_size / 2) / (nr.along_size - along_size), 0, 1)
    end
  end
end


---Handle mouse press events on the scrollbar.
---Sets dragging state if thumb is clicked.
---Does NOT automatically update scroll position - caller must use set_percent().
---@param button core.view.mousebutton Mouse button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param clicks integer Number of clicks
---@return boolean|number? result True if thumb clicked, 0-1 percent if track clicked, falsy otherwise
function Scrollbar:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then return end
  if self:_in_resize_edge_guard(x, y) then return end
  x, y = self:real_to_normal(x, y)
  return self:_on_mouse_pressed_normal(button, x, y, clicks)
end


---Update hover status in normalized coordinates.
---Internal helper called by other mouse methods.
---@param x number Normalized x coordinate
---@param y number Normalized y coordinate
---@return boolean hovering True if hovering track or thumb
function Scrollbar:_update_hover_status_normal(x, y)
  local old_thumb, old_track = self.hovering.thumb, self.hovering.track
  local overlaps = self:_overlaps_normal(x, y)
  self.hovering.thumb = overlaps == "thumb"
  self.hovering.track = self.hovering.thumb or overlaps == "track"
  if old_thumb ~= self.hovering.thumb or old_track ~= self.hovering.track then
    core.redraw = true
  end
  return self.hovering.track or self.hovering.thumb
end


---Handle mouse release in normalized coordinates.
---Internal helper - use on_mouse_released() for real coordinates.
---@param button core.view.mousebutton
---@param x number Normalized x coordinate
---@param y number Normalized y coordinate
---@return boolean hovering True if hovering track or thumb
function Scrollbar:_on_mouse_released_normal(button, x, y)
  self.dragging = false
  return self:_update_hover_status_normal(x, y)
end


---Handle mouse release events on the scrollbar.
---Clears dragging state and updates hover status.
---@param button core.view.mousebutton Mouse button
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean? hovering True if hovering track or thumb
function Scrollbar:on_mouse_released(button, x, y)
  if button ~= "left" then return end
  x, y = self:real_to_normal(x, y)
  return self:_on_mouse_released_normal(button, x, y)
end


---Handle mouse movement in normalized coordinates.
---Internal helper - use on_mouse_moved() for real coordinates.
---@param x number Normalized x coordinate
---@param y number Normalized y coordinate
---@param dx number Normalized delta x
---@param dy number Normalized delta y
---@return boolean|number result True if hovering, 0-1 percent if dragging, falsy otherwise
function Scrollbar:_on_mouse_moved_normal(x, y, dx, dy)
  if self.dragging then
    local nr = self.normal_rect
    local _, _, _, along_size = self:_get_thumb_rect_normal()
    return common.clamp((y - nr.along + self.drag_start_offset) / (nr.along_size - along_size), 0, 1)
  end
  return self:_update_hover_status_normal(x, y)
end


---Handle mouse movement events on the scrollbar.
---Updates hover status and returns drag position if dragging.
---Does NOT automatically update scroll position - caller must use set_percent().
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@param dx number Delta x since last move
---@param dy number Delta y since last move
---@return boolean|number? result True if hovering, 0-1 percent if dragging, falsy otherwise
function Scrollbar:on_mouse_moved(x, y, dx, dy)
  if not self.dragging and self:_in_resize_edge_guard(x, y) then
    if self.hovering.track or self.hovering.thumb then core.redraw = true end
    self.hovering.track, self.hovering.thumb = false, false
    return false
  end
  x, y = self:real_to_normal(x, y)
  dx, dy = self:real_to_normal(dx, dy) -- TODO: do we need this? (is this even correct?)
  return self:_on_mouse_moved_normal(x, y, dx, dy)
end


---Handle mouse leaving the scrollbar area.
---Clears all hover states.
function Scrollbar:on_mouse_left()
  if self.hovering.track or self.hovering.thumb then core.redraw = true end
  self.hovering.track, self.hovering.thumb = false, false
end


---Set the bounding box of the view this scrollbar belongs to.
---Must be called when view size or scrollable area changes.
---@param x number View x position
---@param y number View y position
---@param w number View width
---@param h number View height
---@param scrollable number Total scrollable size (height for vertical, width for horizontal)
function Scrollbar:set_size(x, y, w, h, scrollable)
  self.rect.x, self.rect.y, self.rect.w, self.rect.h = x, y, w, h
  self.rect.scrollable = scrollable

  local nr = self.normal_rect
  nr.across, nr.along, nr.across_size, nr.along_size = self:real_to_normal(x, y, w, h)
  nr.scrollable = scrollable
end


---Set the scrollbar thumb position.
---@param percent number Position from 0-1 (0 = top/left, 1 = bottom/right)
function Scrollbar:set_percent(percent)
  self.percent = percent
end


---Return visual padding between an end-aligned scrollbar and the owner edge.
---@return number padding Padding in pixels
function Scrollbar:get_end_padding()
  if self.direction == "v" and self.alignment == "e" then
    return style.scrollbar_end_padding or 0
  end
  return 0
end


---Return true when a vertical scrollbar should not claim the very outer window
---edge, where native window resizing hit-tests live on Windows.
---@param x number Screen x coordinate
---@param y number Screen y coordinate
---@return boolean in_guard True when point is in the guarded resize edge
function Scrollbar:_in_resize_edge_guard(x, y)
  if self.direction ~= "v" or self.alignment ~= "e" then return false end
  local guard = style.scrollbar_resize_edge_guard or 0
  if guard <= 0 then return false end
  return x >= self.rect.x + self.rect.w - guard
     and x <= self.rect.x + self.rect.w
     and y >= self.rect.y
     and y <= self.rect.y + self.rect.h
end


---Update scrollbar animations (hover expansion).
---Call this every frame to animate the scrollbar width on hover.
function Scrollbar:update()
  -- TODO: move the animation code to its own class
  local hover_dest = (self.hovering.track or self.dragging) and 1 or 0
  local function animation_rate()
    local rate = 0.3
    if core.fps ~= 60 or config.animation_rate ~= 1 then
      local dt = 60 / core.fps
      rate = 1 - common.clamp(1 - rate, 1e-8, 1 - 1e-8)^(config.animation_rate * dt)
    end
    return rate
  end

  local tint_diff = math.abs((self.hover_tint_percent or 0) - hover_dest)
  if not config.transitions or tint_diff < 0.05 or config.disabled_transitions["scroll"] then
    self.hover_tint_percent = hover_dest
  else
    self.hover_tint_percent = common.lerp(self.hover_tint_percent or 0, hover_dest, animation_rate())
  end
  if tint_diff > 1e-8 then core.redraw = true end

  if not self.force_status then
    local dest = hover_dest
    local diff = math.abs(self.expand_percent - dest)
    if not config.transitions or diff < 0.05 or config.disabled_transitions["scroll"] then
      self.expand_percent = dest
    else
      self.expand_percent = common.lerp(self.expand_percent, dest, animation_rate())
    end
    if diff > 1e-8 then
      core.redraw = true
    end
  elseif self.force_status == "expanded" then
    self.expand_percent = 1
  elseif self.force_status == "contracted" then
    self.expand_percent = 0
  end
end


---Draw the scrollbar track (background).
---Only draws when hovered/dragging or expanded.
---Fades in based on expand_percent animation.
function Scrollbar:draw_track()
  if not (self.hovering.track or self.dragging)
     and self.expand_percent == 0 then
    return
  end
  local color = { table.unpack(style.scrollbar_track) }
  color[4] = color[4] * self.expand_percent
  local x, y, w, h = self:get_track_rect()
  renderer.draw_rect(x, y, w, h, color)
end


---Draw the scrollbar thumb (draggable indicator).
---Highlights when hovered or being dragged.
function Scrollbar:draw_thumb()
  local hovering = self.hovering.track or self.hovering.thumb or self.dragging
  -- Make hover feedback visible immediately, even before the next animation
  -- update tick. The animated value then catches up for the smooth transition.
  local t = self.hover_tint_percent or 0
  if hovering then t = math.max(t, self.dragging and 1 or 0.55) end
  local hover_color = style.scrollbar_hover or style.scrollbar2 or lighten_color(style.scrollbar, 44)
  local color = blend_color(style.scrollbar, hover_color, math.min(1, t))
  local x, y, w, h = self:get_thumb_rect()
  renderer.draw_rect(x, y, w, h, color)
end


---Draw the complete scrollbar (track and thumb).
---Call this from the owning view's draw() method.
function Scrollbar:draw()
  self:draw_track()
  self:draw_thumb()
end

return Scrollbar
