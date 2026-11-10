local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"

-- The shared look of Dialogs and their controls: fonts, sizes, icons and motion.
-- Controls draw on a card (`style.card`), so they use the card colors.
local ui = {}

---Icons from the Material Design set of the bundled Nerd Font (`style.menu_icon_font`).
ui.icons = {
  add = "\u{F0415}", close = "\u{F0156}", remove = "\u{F09E7}", reveal = "\u{F0DCF}",
  warning = "\u{F05D6}", folder = "\u{F0256}", home = "\u{F10B6}", link = "\u{F0339}", package = "\u{F03D7}",
  check = "\u{F012C}", open_in_new = "\u{F03CC}", minus = "\u{F0374}", chevron_down = "\u{F0140}",
  search = "\u{F0349}", palette = "\u{F03D8}", form = "\u{F060E}", toggle = "\u{F0521}", button = "\u{F12A8}",
  tune = "\u{F062E}", shape = "\u{F0831}", view_list = "\u{F0572}", delete = "\u{F01B4}",
}

---The text font of Dialogs: the proportional font of the Sidebar and the Title Bar.
function ui.font()
  return style.view_text_font
end

function ui.bold_font()
  local font = style.view_text_font
  return style.get_scaled_font(font, font:get_size(), "bold")
end

function ui.icon_font()
  return style.menu_icon_font
end

-- The text roles of Dialogs. Each is the user's Dialog font at a size relative to its own, so Zoom and the
-- user's font choice apply to all of them.
local ROLES = {
  title = { size = 1, variant = "bold" },
  strong = { size = 0, variant = "bold" },
  label = { size = 0 },
  body = { size = 0 },
  description = { size = -1 },
  meta = { size = -2 },
}

---The font of a text role: "title", "strong", "label", "body", "description" or "meta".
function ui.role_font(role)
  local spec = ROLES[role] or ROLES.body
  local font = ui.font()
  if spec.size == 0 and not spec.variant then return font end
  return style.get_scaled_font(font, math.max(8 * SCALE, font:get_size() + spec.size * SCALE), spec.variant)
end

---The color of a text role. Descriptions and meta text are muted, and titles are strong.
function ui.role_color(role)
  if role == "description" or role == "meta" then return style.dialog_text_muted end
  if role == "title" or role == "strong" then return style.dialog_text_strong end
  return style.dialog_text
end

---Sizes in pixels at the current scale.
function ui.metrics()
  local h = ui.font():get_height()
  return {
    control_h = math.floor(h + 14 * SCALE + 0.5),
    radius = math.floor(6 * SCALE + 0.5),
    pad_x = math.floor(12 * SCALE + 0.5),
    gap = math.floor(8 * SCALE + 0.5),
    icon_gap = math.floor(6 * SCALE + 0.5),
    border = math.max(1, math.floor(SCALE + 0.5)),
    ring = math.max(1, math.floor(2 * SCALE + 0.5)),
    -- The sizes of core.ui's own controls and layout.
    control_sm_h = math.floor(h + 10 * SCALE + 0.5),
    control_xs_h = math.floor(ui.role_font("meta"):get_height() + 8 * SCALE + 0.5),
    field_h = math.floor(h + 12 * SCALE + 0.5),
    control_radius = math.floor(8 * SCALE + 0.5),
    small_radius = math.floor(6 * SCALE + 0.5),
    group_radius = math.floor(10 * SCALE + 0.5),
    dialog_radius = math.floor(14 * SCALE + 0.5),
    dialog_pad = math.floor(20 * SCALE + 0.5),
    section_gap = math.floor(16 * SCALE + 0.5),
    row_pad_x = math.floor(16 * SCALE + 0.5),
    row_pad_y = math.floor(12 * SCALE + 0.5),
    text_gap = math.floor(4 * SCALE + 0.5),
  }
end

---The focus ring of core.ui's controls: a 2 px outline just outside (x, y, w, h).
function ui.draw_ring(x, y, w, h, radius, color)
  local ring = ui.metrics().ring
  ui.draw_rounded_outline(x - ring, y - ring, w + 2 * ring, h + 2 * ring, radius + ring, ring,
    color or style.dialog_focus_ring)
end

-- The opacity of a disabled control.
ui.DISABLED_OPACITY = 0.64

---Draw with `opacity`, and scaled by `scale` around the rect's centre, until `ui.pop_look(pushed)`.
---Disabled controls fade, and pressed buttons shrink. Returns whether it pushed a transform.
function ui.push_look(x, y, w, h, scale, opacity)
  if scale >= 0.9995 and opacity >= 0.9995 then return false end
  renderer.push_transform(x + w / 2, y + h / 2, scale, opacity)
  return true
end

function ui.pop_look(pushed)
  if pushed then renderer.pop_transform() end
end

---A copy of `color` with its alpha multiplied by `alpha`.
function ui.fade(color, alpha)
  if alpha >= 1 then return color end
  return { color[1], color[2], color[3], (color[4] or 255) * alpha }
end

---`color` mixed toward `other` by `amount`, from 0 to 1. A frame can pass `result` to reuse one table.
function ui.mix(color, other, amount, result)
  result = result or {}
  for i = 1, 4 do
    local a, b = color[i] or 255, other[i] or 255
    result[i] = a + (b - a) * amount
  end
  return result
end

---Move `value` toward `target` at `rate` per second, from the time in `state[key .. "_time"]`.
---Returns the new value, and asks for another frame until it arrives.
function ui.approach(state, key, target, rate)
  local now = system.get_time()
  local time_key = key .. "_time"
  local value = state[key]
  local dt = state[time_key] and math.min(now - state[time_key], 0.1) or 0
  state[time_key] = now
  if value == nil or not config.transitions or core.in_live_resize_frame then
    value = target
  else
    value = target + (value - target) * math.exp(-rate * (config.animation_rate or 1) * dt)
    if math.abs(value - target) < 0.004 * math.max(1, math.abs(target)) then value = target end
  end
  state[key] = value
  if value ~= target then core.redraw = true end
  return value
end

---A rounded rectangle's outline, `thickness` pixels wide, inside (x, y, w, h). The inside stays clear.
function ui.draw_rounded_outline(x, y, w, h, radius, thickness, color)
  renderer.draw_rounded_rect(x, y, w, h, radius, color, nil, 0, thickness)
end

---A check box with its top left corner at (x, y). `amount` goes from 0, clear, to 1, checked, so the box can fade.
function ui.draw_check_box(x, y, size, amount)
  local m = ui.metrics()
  local r = m.radius * 0.75
  renderer.draw_rounded_rect(x, y, size, size, r, style.card_text)
  renderer.draw_rounded_rect(x + m.border, y + m.border, size - 2 * m.border, size - 2 * m.border,
    math.max(0, r - m.border), style.card)
  if amount <= 0 then return end
  renderer.draw_rounded_rect(x, y, size, size, r, ui.fade(style.accent, amount))
  common.draw_text(ui.icon_font(), ui.fade(style.button_primary_text, amount), ui.icons.check, "center",
    x, y, size, size)
end

---`text` cut at its end with "…" to fit `width`. `from_start` cuts at its start instead, for paths.
function ui.fit_text(font, text, width, from_start)
  if font:get_width(text) <= width then return text end
  local ellipsis = "…"
  local available = width - font:get_width(ellipsis)
  if available <= 0 then return "" end
  local chars = {}
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = char end
  local low, high = 0, #chars
  while low < high do
    local mid = math.ceil((low + high) / 2)
    local part = from_start and table.concat(chars, "", #chars - mid + 1) or table.concat(chars, "", 1, mid)
    if font:get_width(part) <= available then low = mid else high = mid - 1 end
  end
  if from_start then return ellipsis .. table.concat(chars, "", #chars - low + 1) end
  return table.concat(chars, "", 1, low) .. ellipsis
end

return ui
