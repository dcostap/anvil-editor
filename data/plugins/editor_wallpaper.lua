-- mod-version:3
-- Experimental editor background image.

local core = require "core"
local style = require "core.style"
local common = require "core.common"
local DocView = require "core.docview"
local CommandView = require "core.commandview"

local bundled_path = DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "editor_wallpaper" .. PATHSEP .. "wallpaper.jpg"
local user_path = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "editor_wallpaper" .. PATHSEP .. "wallpaper.jpg"

local wallpaper = {
  path = system.get_file_info(bundled_path) and bundled_path or user_path,
  opacity = 0.18,
  line_highlight = { 64, 64, 64, 128 },
  scale_mode = "linear",
}

local image, image_err
local scaled, scaled_key

local function load_image()
  if image or image_err then return image end
  image, image_err = canvas.load_image(wallpaper.path)
  if not image then
    core.error("Editor wallpaper failed to load: %s", image_err or wallpaper.path)
  end
  return image
end

local function color_with_alpha(color, alpha)
  return { color[1] or 0, color[2] or 0, color[3] or 0, alpha }
end

local function get_cover_scaled(w, h)
  local img = load_image()
  if not img then return nil end
  w, h = math.max(1, math.floor(w)), math.max(1, math.floor(h))
  local iw, ih = img:get_size()
  if iw <= 0 or ih <= 0 then return nil end

  local scale = math.max(w / iw, h / ih)
  local sw, sh = math.max(1, math.ceil(iw * scale)), math.max(1, math.ceil(ih * scale))
  local key = table.concat({ wallpaper.path, sw, sh }, "\0")
  if not scaled or scaled_key ~= key then
    scaled = img:scaled(sw, sh, wallpaper.scale_mode)
    scaled_key = key
  end
  return scaled, sw, sh
end

local function draw_wallpaper_region(x, y, w, h, opacity)
  renderer.draw_rect(x, y, w, h, style.background)

  local root = core.root_view
  local rw = root and root.size and root.size.x or w
  local rh = root and root.size and root.size.y or h
  local rx = root and root.position and root.position.x or 0
  local ry = root and root.position and root.position.y or 0

  local img, iw, ih = get_cover_scaled(rw, rh)
  if not img then return end
  local ix = rx + (rw - iw) / 2
  local iy = ry + (rh - ih) / 2
  core.push_clip_rect(x, y, w, h)
  renderer.draw_canvas(img, ix, iy)
  renderer.draw_rect(x, y, w, h, color_with_alpha(style.background, math.floor(255 * (1 - (opacity or wallpaper.opacity)))))
  core.pop_clip_rect()
end

local function should_wallpaper_background(view, color)
  return view and view.position and view.size
    and (color == style.background or color == style.background2)
end

if not core.__editor_wallpaper_patched then
  core.__editor_wallpaper_patched = true
  local View = require "core.view"
  local Node = require "core.node"
  local view_draw_background = View.draw_background
  function View:draw_background(color)
    if should_wallpaper_background(self, color) then
      draw_wallpaper_region(self.position.x, self.position.y, self.size.x, self.size.y, wallpaper.opacity)
      return
    end
    return view_draw_background(self, color)
  end

  local docview_draw_line_highlight = DocView.draw_line_highlight
  function DocView:draw_line_highlight(x, y)
    local old_line_highlight = style.line_highlight
    style.line_highlight = wallpaper.line_highlight
    local ok, a, b, c, d, e = pcall(docview_draw_line_highlight, self, x, y)
    style.line_highlight = old_line_highlight
    if not ok then error(a) end
    return a, b, c, d, e
  end

  local node_draw_tab_borders = Node.draw_tab_borders
  function Node:draw_tab_borders(view, is_active, is_hovered, x, y, w, h, standalone)
    local tab_x, tab_y, tab_w, tab_h = x, y, w, h
    local a, b, c, d = node_draw_tab_borders(self, view, is_active, is_hovered, x, y, w, h, standalone)
    if is_hovered then
      renderer.draw_rect(tab_x, tab_y, tab_w, tab_h, { 255, 255, 255, 10 })
    end
    return a, b, c, d
  end

  local node_draw_tabs = Node.draw_tabs
  function Node:draw_tabs(...)
    local _, y, _, h = self:get_scroll_button_rect(1)
    draw_wallpaper_region(self.position.x, y, self.size.x, h, wallpaper.opacity)

    -- Node:draw_tabs() itself immediately draws opaque style.background2 and
    -- active-tab style.background rectangles with renderer.draw_rect(), so
    -- drawing the wallpaper first is not enough. Make the row fill transparent
    -- and give the active tab a translucent light overlay while preserving the
    -- rest of the original tab rendering.
    local old_background2 = style.background2
    local old_background = style.background
    style.background2 = { old_background2[1] or 0, old_background2[2] or 0, old_background2[3] or 0, 0 }
    style.background = { 255, 255, 255, 18 }
    local ok, a, b, c, d, e = pcall(node_draw_tabs, self, ...)
    style.background2 = old_background2
    style.background = old_background
    if not ok then error(a) end
    return a, b, c, d, e
  end
end

wallpaper.draw_region = draw_wallpaper_region

return wallpaper
