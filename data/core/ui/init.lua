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
  check = "\u{F012C}", open_in_new = "\u{F03CC}",
}

---The text font of Dialogs: the proportional font of the Sidebar and the Title Bar.
function ui.font()
  return style.view_text_font
end

local bold_fonts = setmetatable({}, { __mode = "k" })

function ui.bold_font()
  local font = style.view_text_font
  bold_fonts[font] = bold_fonts[font] or font:copy(font:get_size(), { bold = true })
  return bold_fonts[font]
end

function ui.icon_font()
  return style.menu_icon_font
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
  }
end

---A copy of `color` with its alpha multiplied by `alpha`.
function ui.fade(color, alpha)
  if alpha >= 1 then return color end
  return { color[1], color[2], color[3], (color[4] or 255) * alpha }
end

---`color` mixed toward `other` by `amount`, from 0 to 1.
function ui.mix(color, other, amount)
  local result = {}
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

---A focus ring just outside a rounded rectangle. The gap between them shows the card.
function ui.draw_focus_ring(x, y, w, h, radius)
  local m = ui.metrics()
  local gap = m.ring + m.border
  renderer.draw_rounded_rect(x - gap, y - gap, w + 2 * gap, h + 2 * gap, radius + gap, style.accent)
  renderer.draw_rounded_rect(x - gap + m.ring, y - gap + m.ring, w + 2 * (gap - m.ring), h + 2 * (gap - m.ring),
    radius + gap - m.ring, style.card)
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
