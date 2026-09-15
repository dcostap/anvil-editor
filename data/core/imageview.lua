local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"
local view_icons = require "core.view_icons"
local image_formats = require "core.image_formats"

---@alias core.imageview.zoommode "fit" | "fixed"

---Shared image display and interaction for Views and previews.
---@class core.imageview : core.view
---@field path string?
---@field image canvas?
---@field zoom_mode core.imageview.zoommode
---@field zoom_scale number
---@field width number
---@field height number
---@field errmsg string?
local ImageView = View:extend()
ImageView.view_icon = view_icons.register("image", view_icons.file("view.png"))

local ZOOM_STEP = 1.25
local MAX_ZOOM = 8
local ZOOM_DURATION = 0.2
local MAX_TEXTURE_SIZE = 8192

function ImageView:__tostring() return "ImageView" end

function ImageView:new(path, zoom_mode, zoom_scale)
  ImageView.super.new(self)
  self.prev_size = { x = 0, y = 0 }
  self.zoom_mode = zoom_mode or "fit"
  self.zoom_scale = zoom_scale or 1
  self.mouse = {}
  self.width, self.height = 0, 0
  if path then self:load(path) end
end

function ImageView:get_state()
  local move = self.zoom_transition
  local scale = move and move.scale or self.zoom_scale
  local sx = move and math.max(0, -move.x) or self.scroll.x
  local sy = move and math.max(0, -move.y) or self.scroll.y
  return {
    path = self.path, zoom_mode = self.zoom_mode, zoom_scale = scale,
    scroll = { x = sx, y = sy, to = { x = sx, y = sy } },
  }
end

function ImageView.from_state(state)
  if not (state.path and system.get_file_info(state.path)) then return nil end
  local view = ImageView(state.path, state.zoom_mode, state.zoom_scale)
  if not view.image then return nil end
  if state.scroll then
    view.scroll.x, view.scroll.y = state.scroll.x, state.scroll.y
    view.scroll.to.x, view.scroll.to.y = state.scroll.x, state.scroll.y
  end
  return view
end

---Use an already loaded image, including Markdown's cached images.
function ImageView:set_image(image, label, path)
  self.image, self.label, self.path = image, label, path
  self.errmsg, self.display_image, self.svg_size = nil, image, nil
  if image then
    -- Keep source dimensions for zoom. Reduce oversized display textures only once.
    local w, h = image:get_size()
    local scale = math.min(1, MAX_TEXTURE_SIZE / w, MAX_TEXTURE_SIZE / h)
    if scale < 1 then
      self.display_image = image:scaled(math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale)), "linear")
      core.log_quiet("Image View reduced display texture: %s (%dx%d)", label or path or "Image", w, h)
    end
  end
  self.zoom_transition, self.mouse_pressed = nil, false
  self.prev_size = { x = 0, y = 0 }
  self.width, self.height = 0, 0
  self.scroll.x, self.scroll.y = 0, 0
  self.scroll.to.x, self.scroll.to.y = 0, 0
  self:update()
end

function ImageView:load(path)
  local image, err = canvas.load_image(path)
  self:set_image(image, nil, path)
  self.errmsg = err
  if not image then
    core.log_quiet("Image View failed to load %s: %s", tostring(path), tostring(err))
    return false, err
  end
  core.log_quiet("Image View loaded: %s", path)
  return true
end

function ImageView:get_name()
  return self.label or (self.path and common.basename(self.path)) or "Image Viewer"
end

function ImageView:get_fit_scale()
  if not self.image or self.size.x <= 0 or self.size.y <= 0 then return 1 end
  local w, h = self.image:get_size()
  return math.min(1, self.size.x / w, self.size.y / h)
end

---Return the displayed image rectangle in screen coordinates.
function ImageView:get_image_rect()
  return self.position.x + math.max(0, (self.size.x - self.width) / 2) - self.scroll.x,
    self.position.y + math.max(0, (self.size.y - self.height) / 2) - self.scroll.y,
    self.width, self.height
end

function ImageView:contains_image(x, y)
  local ix, iy, w, h = self:get_image_rect()
  return self.image and x >= math.max(ix, self.position.x) and y >= math.max(iy, self.position.y)
    and x < math.min(ix + w, self.position.x + self.size.x)
    and y < math.min(iy + h, self.position.y + self.size.y)
end

local function constrain(offset, extent, viewport)
  if extent <= viewport then return (viewport - extent) / 2 end
  return common.clamp(offset, viewport - extent, 0)
end

function ImageView:apply_transform(scale, x, y)
  local iw, ih = self.image:get_size()
  self.zoom_scale = scale
  self.width, self.height = iw * scale, ih * scale
  x = constrain(x, self.width, self.size.x)
  y = constrain(y, self.height, self.size.y)
  self.scroll.x, self.scroll.y = math.max(0, -x), math.max(0, -y)
  self.scroll.to.x, self.scroll.to.y = self.scroll.x, self.scroll.y
end

---Animate one transform, so image position and size use the same progress.
function ImageView:set_zoom(scale, x, y, mode)
  if not self.image or self.size.x <= 0 or self.size.y <= 0 then return false end
  self:update()
  scale = common.clamp(scale, self:get_fit_scale(), MAX_ZOOM)
  x, y = x or self.position.x + self.size.x / 2, y or self.position.y + self.size.y / 2
  local ix, iy = self:get_image_rect()
  local image_x, image_y = (x - ix) / self.zoom_scale, (y - iy) / self.zoom_scale
  local iw, ih = self.image:get_size()
  local tx = constrain(x - self.position.x - image_x * scale, iw * scale, self.size.x)
  local ty = constrain(y - self.position.y - image_y * scale, ih * scale, self.size.y)
  self.zoom_mode = mode or "fixed"
  self.mouse_pressed = false
  self.zoom_transition = nil
  if config.transitions and math.abs(scale - self.zoom_scale) > 1e-8 then
    self.zoom_transition = {
      started = system.get_time(),
      from_scale = self.zoom_scale, from_x = ix - self.position.x, from_y = iy - self.position.y,
      scale = scale, x = tx, y = ty,
    }
  else
    self:apply_transform(scale, tx, ty)
  end
  core.redraw = true
  return true
end

function ImageView:zoom_by(delta, x, y)
  if delta == 0 then return false end
  local scale = self.zoom_transition and self.zoom_transition.scale or self.zoom_scale
  local target = common.clamp(scale * ZOOM_STEP ^ common.clamp(delta, -32, 32), self:get_fit_scale(), MAX_ZOOM)
  if target == scale then return true end
  return self:set_zoom(target, x, y, target == self:get_fit_scale() and "fit" or "fixed")
end

function ImageView:zoom_in() return self:zoom_by(1) end
function ImageView:zoom_out() return self:zoom_by(-1) end
function ImageView:zoom_reset() return self:set_zoom(1) end
function ImageView:zoom_fit() return self:set_zoom(self:get_fit_scale(), nil, nil, "fit") end

function ImageView:toggle_zoom(x, y)
  local scale = self.zoom_transition and self.zoom_transition.scale or self.zoom_scale
  if math.abs(scale - 1) < 1e-8 then return self:zoom_fit() end
  return self:set_zoom(1, x, y)
end

function ImageView:get_controls()
  if not self.image then return {} end
  local font = style.font
  local height = font:get_height() + style.padding.y
  local gap = math.max(1, SCALE)
  local items = {
    { label = "−", action = "zoom_out" },
    { label = string.format("%.0f%%", self.zoom_scale * 100) },
    { label = "+", action = "zoom_in" },
    { label = "Fit", action = "zoom_fit", selected = self.zoom_mode == "fit" },
    { label = "100%", action = "zoom_reset" },
  }
  local width = 0
  for _, item in ipairs(items) do
    item.w = math.max(height, font:get_width(item.action and item.label or "0000%") + style.padding.x * 2)
    width = width + item.w + gap
  end
  width = width - gap
  if self.size.x < width or self.size.y < height * 3 then return {} end
  local x = self.position.x + (self.size.x - width) / 2
  local y = self.position.y + self.size.y - height - style.padding.y
  for _, item in ipairs(items) do
    item.x, item.y, item.h = x, y, height
    x = x + item.w + gap
  end
  return items
end

function ImageView:control_at(x, y)
  for _, item in ipairs(self:get_controls()) do
    if x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + item.h then
      return item
    end
  end
end

function ImageView:update_cursor()
  local control = self.mouse.x and self:control_at(self.mouse.x, self.mouse.y)
  local hovered = control and control.action
  if self.hovered_control ~= hovered then core.redraw = true end
  self.hovered_control = hovered
  self.cursor = (self.mouse_pressed or control and control.action) and "hand"
    or (self.mouse.x and self:contains_image(self.mouse.x, self.mouse.y)) and "crosshair" or "arrow"
end

function ImageView:on_mouse_pressed(button, x, y, clicks)
  self.mouse.x, self.mouse.y = x, y
  if button ~= "left" or not self.image then return false end
  self:update()
  local control = self:control_at(x, y)
  if control then
    if control.action then self[control.action](self) end
  elseif clicks == 2 then
    self:toggle_zoom(x, y)
  elseif self:contains_image(x, y) then
    self.zoom_transition = nil
    self.mouse_pressed = self.width > self.size.x or self.height > self.size.y
  end
  self:update_cursor()
  return true
end

function ImageView:on_mouse_released(button, x, y)
  self.mouse.x, self.mouse.y = x, y
  if button ~= "left" then return false end
  self.mouse_pressed = false
  self:update_cursor()
  return true
end

function ImageView:on_mouse_moved(x, y, dx, dy)
  self.mouse.x, self.mouse.y = x, y
  if self.mouse_pressed then
    local ix, iy = self:get_image_rect()
    self:apply_transform(self.zoom_scale, ix - self.position.x + dx, iy - self.position.y + dy)
    core.redraw = true
  end
  self:update_cursor()
  return self.mouse_pressed
end

function ImageView:on_mouse_left()
  self.mouse_pressed = false
  self.mouse = {}
  self.cursor = "arrow"
  self.hovered_control = nil
  core.redraw = true
end

function ImageView:on_mouse_wheel(delta)
  for _, pressed in pairs(keymap.modkeys) do
    if pressed then return false end
  end
  if not self.image then return false end
  return self:zoom_by(delta, self.mouse.x, self.mouse.y)
end

-- SVG detail changes only after zoom settles. Raster images keep their source texture.
function ImageView:refresh_svg()
  if not self.path or not self.path:lower():match("%.svg$") then return end
  local iw, ih = self.image:get_size()
  local scale = math.min(self.zoom_scale, 4096 / iw, 4096 / ih)
  local w, h = math.max(1, math.ceil(iw * scale)), math.max(1, math.ceil(ih * scale))
  if scale <= 1 or self.svg_size == w .. ":" .. h then return end
  self.svg_size = w .. ":" .. h
  local image, err = canvas.load_svg_image(self.path, w, h)
  if image then
    self.display_image = image
  else
    core.log_quiet("Image View could not render SVG detail: %s: %s", self.path, tostring(err))
  end
end

function ImageView:update()
  if not self.image or self.size.x <= 0 or self.size.y <= 0 then return end
  if self.prev_size.x ~= self.size.x or self.prev_size.y ~= self.size.y then
    local old = self.prev_size
    local scale = self.zoom_mode == "fit" and self:get_fit_scale()
      or common.clamp(self.zoom_scale, self:get_fit_scale(), MAX_ZOOM)
    local x, y = -self.scroll.x, -self.scroll.y
    if old.x > 0 and old.y > 0 then
      local cx = (old.x / 2 - math.max(0, (old.x - self.width) / 2) + self.scroll.x) / self.zoom_scale
      local cy = (old.y / 2 - math.max(0, (old.y - self.height) / 2) + self.scroll.y) / self.zoom_scale
      x, y = self.size.x / 2 - cx * scale, self.size.y / 2 - cy * scale
    end
    self.zoom_transition = nil
    self:apply_transform(scale, x, y)
    self.prev_size = { x = self.size.x, y = self.size.y }
    core.redraw = true
  end
  local move = self.zoom_transition
  if move then
    local progress = config.transitions and common.clamp((system.get_time() - move.started) / ZOOM_DURATION, 0, 1) or 1
    local t = 1 - (1 - progress) ^ 3
    self:apply_transform(common.lerp(move.from_scale, move.scale, t),
      common.lerp(move.from_x, move.x, t), common.lerp(move.from_y, move.y, t))
    if progress == 1 then self.zoom_transition = nil end
    core.redraw = true
  end
  if not self.zoom_transition and not self.mouse_pressed then self:refresh_svg() end
  self:update_cursor()
end

function ImageView:draw_image()
  if not self.image or self.width <= 0 or self.height <= 0 then return end
  local x, y, w, h = self:get_image_rect()
  if config.images_background_mode == "solid" then
    renderer.draw_rect(x, y, w, h, config.images_background_color)
  elseif config.images_background_mode == "grid" then
    -- Draw only visible squares. No image-sized background allocation is needed.
    core.push_clip_rect(x, y, w, h)
    local size = math.max(1, math.floor(12 * SCALE))
    local x1, y1 = math.max(x, self.position.x), math.max(y, self.position.y)
    local x2 = math.min(x + w, self.position.x + self.size.x)
    local y2 = math.min(y + h, self.position.y + self.size.y)
    renderer.draw_rect(x1, y1, x2 - x1, y2 - y1, style.image_grid_bright)
    for row = math.floor((y1 - y) / size), math.ceil((y2 - y) / size) - 1 do
      for col = math.floor((x1 - x) / size), math.ceil((x2 - x) / size) - 1 do
        if (row + col) % 2 == 0 then
          renderer.draw_rect(x + col * size, y + row * size, size, size, style.image_grid_dark)
        end
      end
    end
    core.pop_clip_rect()
  end
  renderer.draw_canvas_scaled(self.display_image, x, y, math.max(1, w), math.max(1, h))
end

function ImageView:draw_controls()
  for _, item in ipairs(self:get_controls()) do
    local hovered = self.mouse.x and self.mouse.x >= item.x and self.mouse.x < item.x + item.w
      and self.mouse.y >= item.y and self.mouse.y < item.y + item.h
    renderer.draw_rounded_rect(item.x, item.y, item.w, item.h, 4 * SCALE,
      hovered and item.action and style.line_highlight or style.background2)
    common.draw_text(style.font, item.selected and style.accent or style.text, item.label,
      "center", item.x, item.y, item.w, item.h)
  end
end

function ImageView:draw()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  self:draw_background(style.background)
  if self.image then
    self:draw_image()
    self:draw_controls()
  else
    common.draw_text(style.font, style.dim, self.errmsg or "Could not load image", "center",
      self.position.x, self.position.y, self.size.x, self.size.y)
  end
  core.pop_clip_rect()
end

function ImageView.is_supported(path)
  return image_formats.is_supported(path)
end

return ImageView
