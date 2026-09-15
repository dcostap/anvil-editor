local common = require "core.common"
local core = require "core"
local style = require "core.style"
local ImageView = require "core.imageview"

local overlay = {}
local view
local modal_handlers

local function viewport()
  local root = core.root_panel
  return root.position.x, root.position.y, root.size.x, root.size.y
end

function overlay.visible() return view ~= nil end
function overlay.get_view() return view end

function overlay.close()
  if not view then return end
  core.root_panel:pop_modal_input(overlay)
  view:on_mouse_left()
  view = nil
  core.log_quiet("Image overlay closed")
  core.redraw = true
end

function overlay.update()
  if not view then return end
  local x, y, w, h = viewport()
  local pad = style.padding.x * 2
  local header = style.font:get_height() + style.padding.y * 2
  view.position.x, view.position.y = x + pad, y + header
  view.size.x, view.size.y = math.max(0, w - pad * 2), math.max(0, h - header - style.padding.y)
  view:update()
end

function overlay.open_image(image, label, path)
  if not image then return false, "image is required" end
  view = ImageView()
  view:set_image(image, label, path)
  overlay.update()
  core.root_panel:push_modal_input(overlay, {
    label = "markdown-image", handlers = modal_handlers,
  })
  core.log_quiet("Image overlay opened: %s", label or path or "Image")
  core.redraw = true
  return true
end

function overlay.open(path)
  if type(path) ~= "string" or path == "" then return false end
  local image, err = canvas.load_image(path)
  if not image then
    core.log_quiet("Image overlay failed to load %s: %s", path, tostring(err))
    return false, err
  end
  return overlay.open_image(image, common.basename(path), path)
end

function overlay.zoom_at(delta, x, y)
  return view and view:zoom_by(delta, x, y) or false
end

function overlay.reset_zoom() return view and view:zoom_fit() or false end
function overlay.actual_size() return view and view:zoom_reset() or false end

function overlay.on_mouse_pressed(button, x, y, clicks)
  if not view then return false end
  if button == "right" or button == "middle" then
    overlay.close()
  elseif button == "left" and not view:contains_image(x, y) and not view:control_at(x, y) then
    overlay.close()
  else
    view:on_mouse_pressed(button, x, y, clicks)
  end
  return true
end

function overlay.on_mouse_released(button, x, y)
  if not view then return false end
  view:on_mouse_released(button, x, y)
  return true
end

function overlay.on_mouse_moved(x, y, dx, dy)
  if not view then return false end
  view:on_mouse_moved(x, y, dx, dy)
  core.request_cursor(view.cursor)
  return true
end

function overlay.on_mouse_left()
  if view then view:on_mouse_left() end
  return true
end

function overlay.on_mouse_wheel(delta_y, delta_x)
  if not view then return false end
  view:on_mouse_wheel(delta_y, delta_x)
  return true
end

function overlay.on_key_pressed(key)
  if not view then return false end
  if key == "escape" then
    overlay.close()
  elseif key == "+" or key == "=" or key == "kp+" then
    view:zoom_in()
  elseif key == "-" or key == "kp-" then
    view:zoom_out()
  elseif key == "0" or key == "kp0" then
    view:zoom_fit()
  elseif key == "1" or key == "kp1" then
    view:zoom_reset()
  end
  return true
end

modal_handlers = {
  key_pressed = overlay.on_key_pressed,
  mouse_pressed = overlay.on_mouse_pressed,
  mouse_released = overlay.on_mouse_released,
  mouse_moved = overlay.on_mouse_moved,
  mouse_left = overlay.on_mouse_left,
  mouse_wheel = overlay.on_mouse_wheel,
}

function overlay.draw()
  if not view then return end
  local x, y, w, h = viewport()
  renderer.draw_rect(x, y, w, h, style.image_overlay_background)
  core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
  view:draw_image()
  view:draw_controls()
  core.pop_clip_rect()
  local iw, ih = view.image:get_size()
  local text = string.format("%s  ·  %d × %d  ·  Wheel to zoom, drag to pan, double-click for 100%%, Esc to close",
    view:get_name(), iw, ih)
  common.draw_text(style.font, style.text, text, "left", x + style.padding.x * 2, y,
    math.max(0, w - style.padding.x * 4), view.position.y - y)
end

function overlay.install()
  if overlay.__installed then return end
  overlay.__installed = true
  local RootPanel = require "core.rootpanel"
  local old_update = RootPanel.update
  function RootPanel:update(...)
    local result = old_update(self, ...)
    overlay.update()
    return result
  end
  local old_draw = RootPanel.draw
  function RootPanel:draw(...)
    local result = old_draw(self, ...)
    overlay.draw()
    return result
  end
end

return overlay
