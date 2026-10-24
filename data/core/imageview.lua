local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local card = require "core.card"
local View = require "core.view"
local view_icons = require "core.view_icons"
local image_formats = require "core.image_formats"
local image_animation = require "core.image_animation"

---@alias core.imageview.zoommode "fit" | "fixed"

---Shared image display and interaction for Views, previews and the Image Overlay.
---
---The image has one transform: a scale and its top-left corner relative to the View.
---The content box is the View less its insets. Fit and pan limits use the content box,
---but the image can draw beyond it, for example below floating controls.
---@class core.imageview : core.view
---@field path string?
---@field image canvas?
---@field zoom_mode core.imageview.zoommode
---@field zoom_scale number
---@field image_x number
---@field image_y number
---@field width number
---@field height number
---@field insets { left: number, top: number, right: number, bottom: number }
---@field errmsg string?
---@field open_animation (fun(): userdata?, string?)?
local ImageView = View:extend()
ImageView.view_icon = view_icons.register("image", view_icons.file("view.png"))

local ZOOM_STEP = 1.25
-- Zoom limit relative to source pixels. Small images can also zoom until they fill the content box several times.
local MAX_ZOOM = 8
local MAX_FILL_ZOOM = 4
local ZOOM_DURATION = 0.2
local MAX_TEXTURE_SIZE = 8192
-- A released drag keeps its speed and slows down, like a touch scroll.
local GLIDE_FRICTION = 7
local GLIDE_SAMPLE_WINDOW = 0.1
local EPSILON = 1e-6

function ImageView:__tostring() return "ImageView" end

function ImageView:new(path, zoom_mode, zoom_scale)
  ImageView.super.new(self)
  self.zoom_mode = zoom_mode or "fit"
  self.zoom_scale = zoom_scale or 1
  self.image_x, self.image_y = 0, 0
  self.insets = { left = 0, top = 0, right = 0, bottom = 0 }
  self.mouse = {}
  self.width, self.height = 0, 0
  self.layout_key = nil
  if path then self:load(path) end
end

local function glide_speed(glide)
  return math.sqrt(glide.vx * glide.vx + glide.vy * glide.vy)
end

---The transform that the View shows after its current transition.
function ImageView:get_target()
  local move = self.transition
  if move then return move.to.scale, move.to.x, move.to.y end
  return self.zoom_scale, self.image_x, self.image_y
end

function ImageView:get_state()
  local scale, x, y = self:get_target()
  local sx, sy = math.max(0, -x), math.max(0, -y)
  return {
    path = self.path, zoom_mode = self.zoom_mode, zoom_scale = scale,
    scroll = { x = sx, y = sy, to = { x = sx, y = sy } },
  }
end

function ImageView.from_state(state)
  if not (state.path and system.get_file_info(state.path)) then return nil end
  local view = ImageView(state.path, state.zoom_mode, state.zoom_scale)
  if not view.image then return nil end
  if state.scroll then view.image_x, view.image_y = -state.scroll.x, -state.scroll.y end
  return view
end

---Use an already loaded image, including Markdown's cached images.
---`open_animation` returns a canvas animation for an animated image.
function ImageView:set_image(image, label, path, open_animation)
  self.image, self.label, self.path = image, label, path
  self.open_animation = open_animation
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
  self.transition, self.panning, self.glide = nil, nil, nil
  self.layout_key = nil
  self.width, self.height = 0, 0
  self.image_x, self.image_y = 0, 0
  self:update()
end

function ImageView:load(path)
  local image, err = canvas.load_image(path)
  self:set_image(image, nil, path, image and ImageView.file_animation_opener(path))
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

---Set the space that floating controls cover. Fit and pan limits stay inside the rest of the View.
function ImageView:set_insets(left, top, right, bottom)
  local insets = self.insets
  insets.left, insets.top, insets.right, insets.bottom = left, top, right, bottom
end

---Return the content box relative to the View position.
function ImageView:get_box()
  local i = self.insets
  return i.left, i.top, math.max(1, self.size.x - i.left - i.right), math.max(1, self.size.y - i.top - i.bottom)
end

---Return the scale that shows the whole image, at most its source size.
function ImageView:get_fit_scale()
  if not self.image or self.size.x <= 0 or self.size.y <= 0 then return 1 end
  local w, h = self.image:get_size()
  local _, _, bw, bh = self:get_box()
  return math.min(1, bw / w, bh / h)
end

---Return the scale that makes the image as large as the content box.
function ImageView:get_fill_scale()
  if not self.image or self.size.x <= 0 or self.size.y <= 0 then return 1 end
  local w, h = self.image:get_size()
  local _, _, bw, bh = self:get_box()
  return math.min(bw / w, bh / h)
end

function ImageView:get_max_scale()
  return math.max(MAX_ZOOM, MAX_FILL_ZOOM * self:get_fill_scale())
end

---Return the displayed image rectangle in screen coordinates.
function ImageView:get_image_rect()
  return self.position.x + self.image_x, self.position.y + self.image_y, self.width, self.height
end

function ImageView:contains_image(x, y)
  local ix, iy, w, h = self:get_image_rect()
  return self.image ~= nil and x >= math.max(ix, self.position.x) and y >= math.max(iy, self.position.y)
    and x < math.min(ix + w, self.position.x + self.size.x)
    and y < math.min(iy + h, self.position.y + self.size.y)
end

---True when the image is larger than the content box, so a drag can move it.
function ImageView:can_pan()
  if not self.image then return false end
  local scale = self:get_target()
  local w, h = self.image:get_size()
  local _, _, bw, bh = self:get_box()
  return w * scale > bw + 0.5 or h * scale > bh + 0.5
end

-- A smaller image stays centered in the box. A larger image cannot leave a gap at a box edge.
local function constrain(offset, extent, start, length)
  if extent <= length then return start + (length - extent) / 2 end
  return common.clamp(offset, start + length - extent, start)
end

function ImageView:constrain(scale, x, y)
  local iw, ih = self.image:get_size()
  local bx, by, bw, bh = self:get_box()
  return constrain(x, iw * scale, bx, bw), constrain(y, ih * scale, by, bh)
end

---Show one transform now. `free` skips the pan limits, for transition frames.
function ImageView:apply_transform(scale, x, y, free)
  local iw, ih = self.image:get_size()
  self.zoom_scale = scale
  self.width, self.height = iw * scale, ih * scale
  if not free then x, y = self:constrain(scale, x, y) end
  self.image_x, self.image_y = x, y
end

---Move to a transform. The scale changes at a constant rate, and each axis moves with it,
---so the one point that both transforms show at the same place stays still.
function ImageView:animate_to(scale, x, y)
  self.glide = nil
  local from = { scale = self.zoom_scale, x = self.image_x, y = self.image_y }
  local changed = math.abs(scale - from.scale) > EPSILON
    or math.abs(x - from.x) > 0.01 or math.abs(y - from.y) > 0.01
  self.transition = nil
  if changed and config.transitions then
    self.transition = {
      started = system.get_time(), duration = ZOOM_DURATION,
      from = from, to = { scale = scale, x = x, y = y },
    }
  else
    self:apply_transform(scale, x, y)
  end
  core.redraw = true
  return true
end

local function interpolate(from, to, t)
  -- Keep the endpoint exact. A scale just below 1 can trigger the actual-size stop again.
  if t == 1 then return to.scale, to.x, to.y end
  if math.abs(to.scale - from.scale) < EPSILON then
    return to.scale, common.lerp(from.x, to.x, t), common.lerp(from.y, to.y, t)
  end
  local scale = from.scale * (to.scale / from.scale) ^ t
  local k = (scale - from.scale) / (to.scale - from.scale)
  return scale, from.x + (to.x - from.x) * k, from.y + (to.y - from.y) * k
end

---End a transition or glide where it is now.
function ImageView:stop_motion()
  if self.transition then
    self.transition = nil
    self:apply_transform(self.zoom_scale, self.image_x, self.image_y)
  end
  self.glide = nil
end

---Zoom to `scale`, and keep the image point under the screen point `x`, `y` in place.
---Without a point, the zoom keeps the center of the content box in place.
function ImageView:set_zoom(scale, x, y, mode)
  if not self.image or self.size.x <= 0 or self.size.y <= 0 then return false end
  self:update()
  local fit = self:get_fit_scale()
  scale = common.clamp(scale, fit, self:get_max_scale())
  local bx, by, bw, bh = self:get_box()
  x = x and x - self.position.x or bx + bw / 2
  y = y and y - self.position.y or by + bh / 2
  local px, py = (x - self.image_x) / self.zoom_scale, (y - self.image_y) / self.zoom_scale
  local tx, ty = self:constrain(scale, x - px * scale, y - py * scale)
  self.zoom_mode = mode or (math.abs(scale - fit) < EPSILON and "fit" or "fixed")
  self.panning = nil
  core.log_quiet("Image View zoom: %s from=%.6f to=%.6f fit=%.6f mode=%s",
    self:get_name(), self.zoom_scale, scale, fit, self.zoom_mode)
  return self:animate_to(scale, tx, ty)
end

function ImageView:zoom_by(delta, x, y)
  if delta == 0 or not self.image then return false end
  local scale = self:get_target()
  local target = common.clamp(scale * ZOOM_STEP ^ common.clamp(delta, -32, 32),
    self:get_fit_scale(), self:get_max_scale())
  -- A zoom that passes source size stops there once.
  if (scale - 1) * (target - 1) < 0 then target = 1 end
  if math.abs(target - scale) < EPSILON then return true end
  return self:set_zoom(target, x, y)
end

function ImageView:zoom_in() return self:zoom_by(1) end
function ImageView:zoom_out() return self:zoom_by(-1) end
function ImageView:zoom_reset() return self:set_zoom(1) end
function ImageView:zoom_fit() return self:set_zoom(self:get_fit_scale(), nil, nil, "fit") end

---Switch between fit and a closer zoom at the pointer.
---A large image goes to source size. An image that fits at source size grows to fill the content box.
function ImageView:toggle_zoom(x, y)
  local scale = self:get_target()
  local fit = self:get_fit_scale()
  if math.abs(scale - fit) > EPSILON then return self:zoom_fit() end
  local target = fit < 1 - EPSILON and 1 or math.min(self:get_max_scale(), self:get_fill_scale())
  if target <= fit + EPSILON then return false end
  return self:set_zoom(target, x, y)
end

---Pan by a screen distance. Positive values show more of the right and bottom of the image.
function ImageView:pan_by(dx, dy)
  if not self:can_pan() then return false end
  local scale, x, y = self:get_target()
  self:stop_motion()
  return self:animate_to(scale, self:constrain(scale, x - dx, y - dy))
end

function ImageView:get_controls()
  if not self.image then return {} end
  local font = style.font
  local height = font:get_height() + style.padding.y
  local pad = math.floor(style.padding.y / 2)
  local items = {
    { label = "−", action = "zoom_out", tooltip = "Zoom out" },
    { label = string.format("%.0f%%", self.zoom_scale * 100), readout = true },
    { label = "+", action = "zoom_in", tooltip = "Zoom in" },
    { label = "Fit", action = "zoom_fit", tooltip = "Fit to window", selected = self.zoom_mode == "fit" },
    { label = "1:1", action = "zoom_reset", tooltip = "Actual size",
      selected = self.zoom_mode ~= "fit" and math.abs(self.zoom_scale - 1) < EPSILON },
  }
  local width = pad * 2
  for _, item in ipairs(items) do
    item.w = math.max(height, font:get_width(item.readout and "0000%" or item.label) + style.padding.x)
    width = width + item.w
  end
  local total_height = height + pad * 2
  if self.size.x < width + style.padding.x * 2 or self.size.y < total_height * 3 then return {} end
  local x = math.floor(self.position.x + (self.size.x - width) / 2)
  local y = math.floor(self.position.y + self.size.y - total_height - style.padding.y)
  items.rect = { x = x, y = y, w = width, h = total_height }
  x = x + pad
  for _, item in ipairs(items) do
    item.x, item.y, item.h = x, y + pad, height
    x = x + item.w
  end
  return items
end

---True when the point is on the control bar, including its padding and zoom readout.
function ImageView:controls_contain(x, y)
  local rect = self:get_controls().rect
  return rect ~= nil and x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h
end

function ImageView:control_at(x, y)
  for _, item in ipairs(self:get_controls()) do
    if item.action and x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + item.h then
      return item
    end
  end
end

function ImageView:update_cursor()
  local control = self.mouse.x and self:control_at(self.mouse.x, self.mouse.y)
  local hovered = control and control.action
  if self.hovered_control ~= hovered then core.redraw = true end
  self.hovered_control = hovered
  local cursor = self.panning and "move" or control and "hand"
    or (self.mouse.x and self:can_pan() and self:contains_image(self.mouse.x, self.mouse.y)) and "grab"
    or "arrow"
  if self.cursor ~= cursor then core.redraw = true end
  self.cursor = cursor
end

function ImageView:on_mouse_pressed(button, x, y, clicks)
  self.mouse.x, self.mouse.y = x, y
  if button ~= "left" or not self.image then return false end
  self:update()
  local control = self:control_at(x, y)
  if control then
    self[control.action](self)
  elseif clicks == 2 then
    self:toggle_zoom(x, y)
  elseif self:contains_image(x, y) and self:can_pan() then
    self:stop_motion()
    self.panning = { samples = {} }
  end
  self:update_cursor()
  core.request_cursor(self.cursor)
  return true
end

-- Measure the drag speed over its last moments. A pause before the release stops the glide.
local function release_glide(panning, now)
  local vx, vy, first
  for _, sample in ipairs(panning.samples) do
    if now - sample.time <= GLIDE_SAMPLE_WINDOW then
      first = first or sample.time
      vx, vy = (vx or 0) + sample.dx, (vy or 0) + sample.dy
    end
  end
  if not first then return nil end
  local duration = math.max(now - first, 1 / 120)
  local glide = { vx = vx / duration, vy = vy / duration, time = now }
  if glide_speed(glide) < 200 * SCALE then return nil end
  return glide
end

function ImageView:on_mouse_released(button, x, y)
  self.mouse.x, self.mouse.y = x, y
  if button ~= "left" then return false end
  local panning = self.panning
  self.panning = nil
  if panning and config.transitions then
    self.glide = release_glide(panning, system.get_time())
    if self.glide then core.redraw = true end
  end
  self:update_cursor()
  core.request_cursor(self.cursor)
  return true
end

function ImageView:on_mouse_moved(x, y, dx, dy)
  self.mouse.x, self.mouse.y = x, y
  local panning = self.panning
  if panning then
    self:apply_transform(self.zoom_scale, self.image_x + dx, self.image_y + dy)
    local samples = panning.samples
    samples[#samples + 1] = { time = system.get_time(), dx = dx, dy = dy }
    if #samples > 16 then table.remove(samples, 1) end
    core.redraw = true
  end
  self:update_cursor()
  return panning ~= nil
end

function ImageView:on_mouse_left()
  self.panning = nil
  self.mouse = {}
  self.cursor = "arrow"
  self.hovered_control = nil
  core.redraw = true
end

---The wheel zooms at the pointer, with or without modifier keys.
function ImageView:on_mouse_wheel(delta)
  if not self.image or not delta or delta == 0 then return false end
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

-- After a resize, keep the image point at the box center in the center, or fit again in fit mode.
function ImageView:update_layout()
  local bx, by, bw, bh = self:get_box()
  local key = string.format("%g:%g:%g:%g", bx, by, bw, bh)
  if self.layout_key == key then return end
  local old = self.layout_box
  self.layout_key, self.layout_box = key, { x = bx, y = by, w = bw, h = bh }
  local fit = self:get_fit_scale()
  local scale = self.zoom_mode == "fit" and fit or common.clamp(self.zoom_scale, fit, self:get_max_scale())
  local x, y = self.image_x, self.image_y
  if old and self.width > 0 then
    local px = (old.x + old.w / 2 - self.image_x) / self.zoom_scale
    local py = (old.y + old.h / 2 - self.image_y) / self.zoom_scale
    x, y = bx + bw / 2 - px * scale, by + bh / 2 - py * scale
  end
  self.transition, self.glide = nil, nil
  self:apply_transform(scale, x, y)
  core.redraw = true
end

function ImageView:update_motion()
  local move = self.transition
  if move then
    local progress = common.clamp((system.get_time() - move.started) / move.duration, 0, 1)
    if not config.transitions then progress = 1 end
    local t = 1 - (1 - progress) ^ 3
    local scale, x, y = interpolate(move.from, move.to, t)
    self:apply_transform(scale, x, y, progress < 1)
    if progress == 1 then self.transition = nil end
    core.redraw = true
  end
  local glide = self.glide
  if glide then
    local now = system.get_time()
    local dt = math.min(0.05, now - glide.time)
    glide.time = now
    local x, y = self.image_x + glide.vx * dt, self.image_y + glide.vy * dt
    self:apply_transform(self.zoom_scale, x, y)
    -- An edge stops its axis.
    if math.abs(self.image_x - x) > 0.01 then glide.vx = 0 end
    if math.abs(self.image_y - y) > 0.01 then glide.vy = 0 end
    local decay = math.exp(-GLIDE_FRICTION * dt)
    glide.vx, glide.vy = glide.vx * decay, glide.vy * decay
    if glide_speed(glide) < 20 * SCALE then self.glide = nil end
    core.redraw = true
  end
end

function ImageView:update()
  if not self.image or self.size.x <= 0 or self.size.y <= 0 then return end
  self:update_layout()
  self:update_motion()
  if not self.transition and not self.panning and not self.glide then self:refresh_svg() end
  self:update_cursor()
end

function ImageView:draw_image(opacity)
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
  local iw, ih = self.image:get_size()
  local frame = self.open_animation and image_animation.frame(self, {
    version = self.image, open = self.open_animation, width = iw, height = ih,
  })
  renderer.draw_canvas_scaled(frame or self.display_image, x, y, math.max(1, w), math.max(1, h), opacity)
end

function ImageView:draw_controls()
  local items = self:get_controls()
  local rect = items.rect
  if not rect then return end
  card.draw(rect.x, rect.y, rect.w, rect.h, rect.h / 2)
  for _, item in ipairs(items) do
    if item.action and item.action == self.hovered_control then
      renderer.draw_rounded_rect(item.x, item.y, item.w, item.h, item.h / 2, style.card_selection)
    end
    local color = item.selected and style.accent or item.readout and style.dim or style.text
    common.draw_text(style.font, color, item.label, "center", item.x, item.y, item.w, item.h)
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

---Return a canvas animation opener for an animated image file, or nil.
---@param path string
---@return (fun(): userdata?, string?)?
function ImageView.file_animation_opener(path)
  local animation_type = image_animation.detect_file_type(path)
  if not animation_type then return nil end
  return function() return canvas.open_animation(path, animation_type) end
end

function ImageView.is_supported(path)
  return image_formats.is_supported(path)
end

return ImageView
