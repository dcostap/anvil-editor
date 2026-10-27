local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local card = require "core.card"

-- The parts that the find cards of text files and Terminals share: the query field,
-- the option toggles inside its right end, and their hover and tooltip.
-- Each card keeps a hover record in its own state, so two cards do not share a tooltip.
local find_card = {}

local TOOLTIP_DELAY = 0.35

local function inside(x, y, rect)
  return rect ~= nil and x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h
end
find_card.inside = inside

---Place option toggles from right to left inside the right end of a field.
---Each option is `{ key, label, tooltip, command }`.
---@return table[] toggles, number left The toggles and the x where the first one starts.
function find_card.place_toggles(options, field, font)
  local toggle_h = field.h - 8 * SCALE
  local right = field.x + field.w - 4 * SCALE
  local toggles = {}
  for i = #options, 1, -1 do
    local option = options[i]
    local toggle_w = math.max(toggle_h, font:get_width(option.label) + 8 * SCALE)
    right = right - toggle_w
    table.insert(toggles, 1, {
      option = option, key = option.key, label = option.label,
      x = right, y = field.y + 4 * SCALE, w = toggle_w, h = toggle_h,
    })
    right = right - 2 * SCALE
  end
  return toggles, right
end

function find_card.toggle_at(toggles, x, y)
  for _, toggle in ipairs(toggles) do
    if inside(x, y, toggle) then return toggle end
  end
end

---Record the toggle under the pointer. A new toggle restarts the tooltip delay.
function find_card.set_hover(state, toggle)
  local key = toggle and toggle.key
  if (state.hover and state.hover.key) == key then return end
  state.hover = key and { key = key, since = system.get_time() } or nil
  core.redraw = true
end

function find_card.is_hovered(state, key)
  return state.hover ~= nil and state.hover.key == key
end

---Redraw until the hovered toggle's tooltip appears.
function find_card.update(state)
  local hover = state.hover
  if hover and not hover.shown then
    hover.shown = system.get_time() - hover.since >= TOOLTIP_DELAY
    core.redraw = true
  end
end

---The tooltip of the hovered toggle, once the pointer has rested on it: its name, then its shortcut.
function find_card.tooltip(state, toggles)
  local hover = state.hover
  if not (hover and hover.shown) then return end
  for _, toggle in ipairs(toggles) do
    if toggle.key == hover.key then
      local option = toggle.option
      return option.tooltip, option.command and keymap.get_binding(option.command), toggle
    end
  end
end

function find_card.draw_field(field, input, placeholder, focused)
  local r = 6 * SCALE
  if focused then
    local ring = math.max(1, math.floor(SCALE + 0.5))
    renderer.draw_rounded_rect(field.x, field.y, field.w, field.h, r, style.accent)
    renderer.draw_rounded_rect(field.x + ring, field.y + ring, field.w - 2 * ring, field.h - 2 * ring,
      r - ring, style.card)
  end
  renderer.draw_rounded_rect(field.x, field.y, field.w, field.h, r, style.card_field)
  local x, y, w, h = input.position.x, input.position.y, input.size.x, input.size.y
  core.push_clip_rect(x, y, w, h)
  input:draw()
  if input:get_text() == "" then
    local text_x = input:get_line_screen_position(1, 1)
    common.draw_text(input:get_font(), style.dim, placeholder, "left", text_x, y, w, h)
  end
  core.pop_clip_rect()
end

-- An enabled toggle has an accent tint. Hover makes the tint stronger, or adds the selection tint.
function find_card.draw_toggle(toggle, font, on, hovered)
  local color = style.dim
  if on then
    local accent = style.accent
    renderer.draw_rounded_rect(toggle.x, toggle.y, toggle.w, toggle.h, 4 * SCALE,
      { accent[1], accent[2], accent[3], hovered and 96 or 64 })
    color = style.accent
  elseif hovered then
    renderer.draw_rounded_rect(toggle.x, toggle.y, toggle.w, toggle.h, 4 * SCALE, style.card_selection)
    color = style.text
  end
  common.draw_text(font, color, toggle.label, "center", toggle.x, toggle.y, toggle.w, toggle.h)
end

---Draw the hovered toggle's tooltip below the card, kept inside `bounds`.
function find_card.draw_tooltip(state, toggles, card_rect, bounds)
  local text, binding, toggle = find_card.tooltip(state, toggles)
  if not text then return end
  local font = style.font
  local pad_x, pad_y = style.padding.x, style.padding.y / 2
  local binding_text = binding and "  " .. binding
  local w = font:get_width(text) + (binding_text and font:get_width(binding_text) or 0) + pad_x * 2
  local h = font:get_height() + pad_y * 2
  local margin = 4 * SCALE
  local x = common.clamp(toggle.x + toggle.w / 2 - w / 2, bounds.x + margin, bounds.x + bounds.w - margin - w)
  local y = card_rect.y + card_rect.h + margin
  x = math.floor(x)
  card.draw(x, y, w, h, 6 * SCALE)
  local tx = common.draw_text(font, style.text, text, "left", x + pad_x, y, 0, h)
  if binding_text then common.draw_text(font, style.dim, binding_text, "left", tx, y, 0, h) end
end

return find_card
