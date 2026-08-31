local style = require "core.style"
local ImageView = require "core.imageview"
local View = require "core.view"

local ImageComparisonView = View:extend()

function ImageComparisonView:__tostring()
  return "ImageComparisonView"
end

function ImageComparisonView:new(opts)
  ImageComparisonView.super.new(self)
  opts = opts or {}
  self.left_title = opts.left_title or "Before"
  self.right_title = opts.right_title or "After"
  self.left_view = opts.left_path and ImageView(opts.left_path) or nil
  self.right_view = opts.right_path and ImageView(opts.right_path) or nil
  self.mouse = { x = 0, y = 0 }
end

function ImageComparisonView:layout()
  local gap = math.max(SCALE, style.padding.x)
  local side_width = math.max(0, math.floor((self.size.x - gap) / 2))
  local header_height = style.prose_font:get_height() + style.padding.y
  local image_y = self.position.y + header_height
  local image_height = math.max(0, self.size.y - header_height)
  if self.left_view then
    self.left_view.position.x, self.left_view.position.y = self.position.x, image_y
    self.left_view.size.x, self.left_view.size.y = side_width, image_height
  end
  if self.right_view then
    self.right_view.position.x = self.position.x + side_width + gap
    self.right_view.position.y = image_y
    self.right_view.size.x, self.right_view.size.y = side_width, image_height
  end
  self.divider_x = self.position.x + side_width
  self.header_height = header_height
  self.side_width = side_width
end

function ImageComparisonView:side_at(x, y)
  if y < self.position.y or y >= self.position.y + self.size.y then return nil end
  if x >= self.position.x and x < self.divider_x then return self.left_view, "left" end
  if x > self.divider_x and x < self.position.x + self.size.x then return self.right_view, "right" end
end

function ImageComparisonView:sync_from(source)
  local target = source == self.left_view and self.right_view or self.left_view
  if not (source and target) then return end
  target.zoom_mode = source.zoom_mode
  target.zoom_scale = source.zoom_scale
  target:scale_image()
  target.scroll.x, target.scroll.y = source.scroll.x, source.scroll.y
  target.scroll.to.x, target.scroll.to.y = source.scroll.to.x, source.scroll.to.y
end

function ImageComparisonView:update()
  self:layout()
  if self.left_view then self.left_view:update() end
  if self.right_view then self.right_view:update() end
  ImageComparisonView.super.update(self)
end

local function draw_side_title(title, x, y, width, height)
  renderer.draw_rect(x, y, width, height, style.background2)
  renderer.draw_text(
    style.prose_font, title, x + style.padding.x,
    y + (height - style.prose_font:get_height()) / 2, style.text
  )
end

local function draw_missing_side(text, x, y, width, height)
  local font = style.prose_font
  renderer.draw_text(
    font, text, x + (width - font:get_width(text)) / 2,
    y + (height - font:get_height()) / 2, style.dim
  )
end

function ImageComparisonView:draw()
  self:layout()
  self:draw_background(style.background)
  local right_x = self.divider_x + math.max(SCALE, style.padding.x)
  draw_side_title(self.left_title, self.position.x, self.position.y, self.side_width, self.header_height)
  draw_side_title(self.right_title, right_x, self.position.y, self.side_width, self.header_height)
  renderer.draw_rect(self.divider_x, self.position.y, SCALE, self.size.y, style.divider)
  if self.left_view and self.left_view.image then
    self.left_view:draw()
  else
    draw_missing_side(
      self.left_view and (self.left_view.errmsg or "Could not load image") or "File did not exist",
      self.position.x, self.position.y + self.header_height,
      self.side_width, self.size.y - self.header_height
    )
  end
  if self.right_view and self.right_view.image then
    self.right_view:draw()
  else
    draw_missing_side(
      self.right_view and (self.right_view.errmsg or "Could not load image") or "File does not exist",
      right_x, self.position.y + self.header_height,
      self.side_width, self.size.y - self.header_height
    )
  end
end

function ImageComparisonView:on_mouse_wheel(y)
  local view = self:side_at(self.mouse.x, self.mouse.y)
  view = view or self.left_view or self.right_view
  if not view then return false end
  view.mouse.x, view.mouse.y = self.mouse.x, self.mouse.y
  local handled = view:on_mouse_wheel(y)
  if handled then self:sync_from(view) end
  return handled
end

function ImageComparisonView:on_mouse_pressed(button, x, y, clicks)
  self.mouse.x, self.mouse.y = x, y
  local view = self:side_at(x, y)
  if not view then return false end
  self.drag_view = view
  return view:on_mouse_pressed(button, x, y, clicks)
end

function ImageComparisonView:on_mouse_moved(x, y, dx, dy)
  self.mouse.x, self.mouse.y = x, y
  local view = self.drag_view or self:side_at(x, y)
  if not view then return false end
  local handled = view:on_mouse_moved(x, y, dx, dy)
  if self.drag_view then self:sync_from(view) end
  return handled
end

function ImageComparisonView:on_mouse_released(button, x, y)
  local view = self.drag_view or self:side_at(x, y)
  self.drag_view = nil
  if not view then return false end
  view:on_mouse_released(button, x, y)
  self:sync_from(view)
  return true
end

function ImageComparisonView:on_mouse_left()
  self.drag_view = nil
  if self.left_view then self.left_view.mouse_pressed = false end
  if self.right_view then self.right_view.mouse_pressed = false end
  return ImageComparisonView.super.on_mouse_left(self)
end

return ImageComparisonView
