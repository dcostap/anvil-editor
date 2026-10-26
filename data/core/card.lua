local core = require "core"
local style = require "core.style"

-- A floating card: a rounded panel with a soft shadow and a thin border.
-- Dialogs, prompts and popups that float over the editor share this look.
local card = {}

local SHADOW_LAYERS = 3

---How far the shadow reaches past the card's edges, in pixels.
function card.shadow_extent()
  return SHADOW_LAYERS * 3 * SCALE + 4 * SCALE
end

---The border's width, in pixels.
function card.border_width()
  return math.max(1, math.floor(SCALE + 0.5))
end

---Draw a card with its shadow, border and fill.
---@param x number
---@param y number
---@param w number
---@param h number
---@param radius number Corner radius in pixels
function card.draw(x, y, w, h, radius)
  local shadow = style.card_shadow
  local border = card.border_width()
  local function draw_edge()
    for i = SHADOW_LAYERS, 1, -1 do
      local spread = i * 3 * SCALE
      renderer.draw_rounded_rect(x - spread, y - spread + 4 * SCALE, w + 2 * spread, h + 2 * spread, radius + spread,
        {shadow[1], shadow[2], shadow[3], (shadow[4] or 255) * (SHADOW_LAYERS + 1 - i) / 6})
    end
    renderer.draw_rounded_rect(x, y, w, h, radius, style.card_border)
  end
  -- The fill hides the shadow and the border, except at the edges and the corners.
  -- Draw them only there, so that a large card does not fill its area several times.
  -- The bands meet at whole pixels, so that no shadow row is drawn twice or missed.
  local extent, band = card.shadow_extent(), radius + border
  local x1, y1 = math.floor(x - extent), math.floor(y - extent)
  local x2, y2 = math.ceil(x + w + extent), math.ceil(y + h + extent)
  local left, top = math.ceil(x + band), math.ceil(y + band)
  local right, bottom = math.floor(x + w - band), math.floor(y + h - band)
  if right <= left or bottom <= top then
    draw_edge()
  else
    for _, clip in ipairs {
      { x1, y1, x2 - x1, top - y1 },
      { x1, bottom, x2 - x1, y2 - bottom },
      { x1, top, left - x1, bottom - top },
      { right, top, x2 - right, bottom - top },
    } do
      core.push_clip_rect(clip[1], clip[2], clip[3], clip[4])
      draw_edge()
      core.pop_clip_rect()
    end
  end
  renderer.draw_rounded_rect(x + border, y + border, w - 2 * border, h - 2 * border, math.max(0, radius - border),
    style.card)
end

return card
