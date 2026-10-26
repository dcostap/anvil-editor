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

---Report a card's shape to a hosted shell, which shows it above the Sidebar.
---The shell copies whole rectangles, so two of them follow the rounded corners.
---The shadow stays out: the shell would show it as a band over the Sidebar.
function card.show_above_sidebar(x, y, w, h, radius)
  local cut = math.ceil(radius * (1 - math.sqrt(0.5)))
  core.root_panel:show_above_sidebar(x + cut, y, w - 2 * cut, h)
  core.root_panel:show_above_sidebar(x, y + cut, w, h - 2 * cut)
end

---Call fill(x, y, w, h) for each rectangle of a rounded area, from the top down.
---Corner rows are one pixel high. They stop at the curve, so a fill that cannot be
---rounded, such as an image, takes the card's shape.
local function each_rounded_band(x, y, w, h, radius, fill)
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  local rows = math.min(math.ceil(radius), math.floor(h / 2))
  local function inset(row)
    local dy = radius - (row + 0.5)
    if dy <= 0 then return 0 end
    return math.max(0, math.ceil(radius - math.sqrt(math.max(0, radius * radius - dy * dy)) - 0.3))
  end
  for row = 0, rows - 1 do
    local cut = inset(row)
    fill(x + cut, y + row, w - 2 * cut, 1)
  end
  if h - 2 * rows > 0 then fill(x, y + rows, w, h - 2 * rows) end
  for row = rows - 1, 0, -1 do
    local cut = inset(row)
    fill(x + cut, y + h - row - 1, w - 2 * cut, 1)
  end
end

---Draw a card with its shadow, border and fill.
---@param x number
---@param y number
---@param w number
---@param h number
---@param radius number Corner radius in pixels
---@param fill? fun(x: number, y: number, w: number, h: number) Draws the inside instead of the card color.
function card.draw(x, y, w, h, radius, fill)
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
  local inner_radius = math.max(0, radius - border)
  if fill then
    each_rounded_band(x + border, y + border, w - 2 * border, h - 2 * border, inner_radius, fill)
  else
    renderer.draw_rounded_rect(x + border, y + border, w - 2 * border, h - 2 * border, inner_radius, style.card)
  end
end

return card
