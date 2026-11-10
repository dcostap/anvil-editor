local style = require "core.style"

-- The surfaces of Dialogs and their controls: a shadow, a 1 px rim and a fill. `style.dialog_surfaces` defines
-- them. Each part is a gradient from its color to its `_bottom` color.
local surface = {}

---The surface called `name`.
function surface.get(name)
  return style.dialog_surfaces[name]
end

---Draw a surface in (x, y, w, h). `rim` replaces its rim with one color, for a focus or error outline.
---@param s table|string A surface, or its name.
function surface.draw(s, x, y, w, h, radius, rim)
  if type(s) == "string" then s = style.dialog_surfaces[s] end
  if s.shadow then
    renderer.draw_rounded_rect(x, y + (s.shadow_y or 0) * SCALE, w, h, radius, s.shadow, s.shadow,
      (s.shadow_blur or 0) * SCALE)
  end
  local top, bottom = rim or s.rim, rim or s.rim_bottom or s.rim
  if top then
    renderer.draw_rounded_rect(x, y, w, h, radius, top, bottom)
    -- The fill covers the rim's inside, so a rim needs an opaque fill.
    local border = math.max(1, math.floor(SCALE + 0.5))
    x, y, w, h, radius = x + border, y + border, w - 2 * border, h - 2 * border, math.max(0, radius - border)
  end
  if s.fill then renderer.draw_rounded_rect(x, y, w, h, radius, s.fill, s.fill_bottom or s.fill) end
end

---Draw `base`, then `over` on it at `amount` opacity, such as a well that fades to its hover look.
function surface.draw_faded(base, over, amount, x, y, w, h, radius, rim)
  surface.draw(base, x, y, w, h, radius, rim)
  if amount <= 0 then return end
  local pushed = amount < 0.9995
  if pushed then renderer.push_transform(x + w / 2, y + h / 2, 1, amount) end
  surface.draw(over, x, y, w, h, radius, rim)
  if pushed then renderer.pop_transform() end
end

return surface
