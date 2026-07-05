local common = require "core.common"
local core = require "core"
local keymap = require "core.keymap"
local style = require "core.style"

local overlay = {}

local state = {
  visible = false,
  path = nil,
  image = nil,
  scaled = nil,
  scale = 1,
  width = 0,
  height = 0,
  scroll = { x = 0, y = 0 },
  dragging = false,
  mouse = { x = 0, y = 0 },
}

overlay.state = state

local function viewport()
  local root = core.root_panel
  local x = root and root.position and root.position.x or 0
  local y = root and root.position and root.position.y or 0
  local w = root and root.size and root.size.x or 0
  local h = root and root.size and root.size.y or 0
  return x, y, w, h
end

local function clamp_scroll()
  local _, _, w, h = viewport()
  state.scroll.x = common.clamp(state.scroll.x or 0, 0, math.max(0, (state.width or 0) - w))
  state.scroll.y = common.clamp(state.scroll.y or 0, 0, math.max(0, (state.height or 0) - h))
end

local function scale_image()
  if not state.image then return end
  local iw, ih = state.image:get_size()
  state.scale = common.clamp(state.scale or 1, 0.05, 16)
  local w = math.max(1, math.floor(iw * state.scale))
  local h = math.max(1, math.floor(ih * state.scale))
  if state.scaled and state.width == w and state.height == h then return end
  state.width, state.height = w, h
  if state.scale == 1 then
    state.scaled = state.image
  else
    state.scaled = state.image:scaled(w, h, "nearest")
  end
  clamp_scroll()
end

local function fit_scale()
  if not state.image then return 1 end
  local _, _, vw, vh = viewport()
  local iw, ih = state.image:get_size()
  local margin = math.max(48 * SCALE, 1)
  local available_w = math.max(1, vw - margin * 2)
  local available_h = math.max(1, vh - margin * 2)
  return math.min(1, available_w / iw, available_h / ih)
end

function overlay.visible()
  return state.visible == true
end

function overlay.close()
  state.visible = false
  state.path = nil
  state.image = nil
  state.scaled = nil
  state.dragging = false
  core.redraw = true
end

function overlay.open(path)
  if type(path) ~= "string" or path == "" then return false end
  local image, err = canvas.load_image(path)
  if not image then
    core.log_quiet("Markdown image overlay failed to load %s: %s", tostring(path), tostring(err))
    return false, err
  end
  state.visible = true
  state.path = path
  state.image = image
  state.scaled = nil
  state.scale = fit_scale()
  state.scroll.x, state.scroll.y = 0, 0
  state.dragging = false
  scale_image()
  core.redraw = true
  return true
end

function overlay.zoom_at(delta, x, y)
  if not state.visible or not state.image then return false end
  local vx, vy, vw, vh = viewport()
  local mx, my = (x or state.mouse.x or (vx + vw / 2)) - vx, (y or state.mouse.y or (vy + vh / 2)) - vy
  local offset_x = state.width < vw and (vw - state.width) / 2 or 0
  local offset_y = state.height < vh and (vh - state.height) / 2 or 0
  local image_x = (mx + state.scroll.x - offset_x) / state.scale
  local image_y = (my + state.scroll.y - offset_y) / state.scale
  if delta > 0 then
    state.scale = state.scale * 1.25
  else
    state.scale = state.scale / 1.25
  end
  scale_image()
  offset_x = state.width < vw and (vw - state.width) / 2 or 0
  offset_y = state.height < vh and (vh - state.height) / 2 or 0
  state.scroll.x = image_x * state.scale - mx + offset_x
  state.scroll.y = image_y * state.scale - my + offset_y
  clamp_scroll()
  core.redraw = true
  return true
end

function overlay.reset_zoom()
  if not state.visible or not state.image then return false end
  state.scale = fit_scale()
  state.scroll.x, state.scroll.y = 0, 0
  scale_image()
  core.redraw = true
  return true
end

function overlay.actual_size()
  if not state.visible or not state.image then return false end
  state.scale = 1
  scale_image()
  core.redraw = true
  return true
end

function overlay.on_mouse_pressed(button, x, y, clicks)
  if not state.visible then return false end
  state.mouse.x, state.mouse.y = x, y
  if button == "left" then
    if clicks and clicks >= 2 then
      overlay.reset_zoom()
    else
      state.dragging = true
    end
  elseif button == "right" or button == "middle" then
    overlay.close()
  end
  return true
end

function overlay.on_mouse_released(button, x, y)
  if not state.visible then return false end
  state.mouse.x, state.mouse.y = x, y
  if button == "left" then state.dragging = false end
  return true
end

function overlay.on_mouse_moved(x, y, dx, dy)
  if not state.visible then return false end
  state.mouse.x, state.mouse.y = x, y
  if state.dragging then
    state.scroll.x = state.scroll.x - (dx or 0)
    state.scroll.y = state.scroll.y - (dy or 0)
    clamp_scroll()
    core.redraw = true
  end
  core.request_cursor(state.dragging and "hand" or "arrow")
  return true
end

function overlay.on_mouse_wheel(delta_y, _delta_x)
  if not state.visible then return false end
  return overlay.zoom_at(delta_y or 0, state.mouse.x, state.mouse.y)
end

function overlay.on_key_pressed(key)
  if not state.visible then return false end
  if key == "escape" then
    overlay.close()
    return true
  elseif key == "+" or key == "=" or key == "kp+" then
    return overlay.zoom_at(1)
  elseif key == "-" or key == "kp-" then
    return overlay.zoom_at(-1)
  elseif key == "0" or key == "kp0" then
    return overlay.reset_zoom()
  elseif key == "1" or key == "kp1" then
    return overlay.actual_size()
  end
  return true
end

function overlay.draw()
  if not state.visible then return end
  local x, y, w, h = viewport()
  renderer.draw_rect(x, y, w, h, { 0, 0, 0, 225 })
  if state.scaled then
    local ix = x + (state.width < w and (w - state.width) / 2 or -state.scroll.x)
    local iy = y + (state.height < h and (h - state.height) / 2 or -state.scroll.y)
    renderer.draw_canvas(state.scaled, ix, iy)
  end
  local label = state.path and common.basename(state.path) or "Image"
  local text = string.format("%s  %.0f%%  (wheel zoom, drag pan, Esc close)", label, (state.scale or 1) * 100)
  local pad = math.max(12 * SCALE, 1)
  local font = style.font
  local th = font:get_height() + pad
  renderer.draw_rect(x, y, w, th + pad, { 0, 0, 0, 160 })
  common.draw_text(font, style.text, text, "left", x + pad, y + pad / 2, math.max(0, w - pad * 2), th)
end

function overlay.install()
  if overlay.__installed then return end
  overlay.__installed = true
  local RootPanel = require "core.rootpanel"

  local old_draw = RootPanel.draw
  function RootPanel:draw(...)
    local result = old_draw(self, ...)
    overlay.draw()
    return result
  end

  local old_pressed = RootPanel.on_mouse_pressed
  function RootPanel:on_mouse_pressed(button, x, y, clicks, ...)
    if state.visible then return overlay.on_mouse_pressed(button, x, y, clicks) end
    return old_pressed(self, button, x, y, clicks, ...)
  end

  local old_released = RootPanel.on_mouse_released
  function RootPanel:on_mouse_released(button, x, y, ...)
    if state.visible then return overlay.on_mouse_released(button, x, y, ...) end
    return old_released(self, button, x, y, ...)
  end

  local old_moved = RootPanel.on_mouse_moved
  function RootPanel:on_mouse_moved(x, y, dx, dy, ...)
    if state.visible then return overlay.on_mouse_moved(x, y, dx, dy) end
    return old_moved(self, x, y, dx, dy, ...)
  end

  local old_wheel = RootPanel.on_mouse_wheel
  function RootPanel:on_mouse_wheel(delta_y, delta_x, ...)
    if state.visible then return overlay.on_mouse_wheel(delta_y, delta_x) end
    return old_wheel(self, delta_y, delta_x, ...)
  end

  local old_key_pressed = keymap.on_key_pressed
  keymap.on_key_pressed = function(key, ...)
    if state.visible and overlay.on_key_pressed(key, ...) then return true end
    return old_key_pressed(key, ...)
  end
end

return overlay
