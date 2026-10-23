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
  for i = SHADOW_LAYERS, 1, -1 do
    local spread = i * 3 * SCALE
    renderer.draw_rounded_rect(x - spread, y - spread + 4 * SCALE, w + 2 * spread, h + 2 * spread, radius + spread,
      {shadow[1], shadow[2], shadow[3], (shadow[4] or 255) * (SHADOW_LAYERS + 1 - i) / 6})
  end
  local border = card.border_width()
  renderer.draw_rounded_rect(x, y, w, h, radius, style.card_border)
  renderer.draw_rounded_rect(x + border, y + border, w - 2 * border, h - 2 * border, math.max(0, radius - border),
    style.card)
end

return card
