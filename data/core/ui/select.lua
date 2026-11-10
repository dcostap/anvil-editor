local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Object = require "core.object"
local style = require "core.style"
local popup = require "core.popup"
local ui = require "core.ui"
local surface = require "core.ui.surface"
local layout = require "core.ui.layout"
local Control = require "core.ui.control"

-- A button that shows the chosen option and opens a list of the options, for one choice of many, such as a
-- database. Use Segmented for 2 to 4 short choices.
-- A click, Enter, a line move or a typed letter opens the list. In the list, the pointer, the editor's line
-- moves and typed letters move the highlight. A click or Enter chooses the highlighted option, and Escape
-- closes the list. Each option is `{ value = ..., label = "...", enabled = true }`.
-- `on_change(value)` returns false to refuse the change. `placeholder` shows while no option is chosen.
-- The open list is the control's `overlay`: the Dialog draws it above the card, and gives it the pointer.
local Select = Control:extend()

Select.focusable = true
Select.takes_text = true
Select.cursor = "hand"

local px = layout.px
local MAX_ROWS = 8
-- Typed letters within this time make one search, such as "de" for "Development".
local TYPE_SECONDS = 1

-- The open list.
local Menu = Object:extend()

function Menu:new(select)
  self.select = select
  self.x, self.y, self.w, self.h = 0, 0, 0, 0
  self.scroll = 0
end

local function row_height() return ui.metrics().control_sm_h end
local function menu_pad() return px(4) end

function Menu:contains(x, y)
  return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h
end

local function view_height(self)
  return self.h - 2 * menu_pad()
end

local function max_scroll(self)
  return math.max(0, #self.select.options * row_height() - view_height(self))
end

---The index of the row at a point, or nil.
function Menu:index_at(x, y)
  local top = self.y + menu_pad()
  if not self:contains(x, y) or y < top or y >= top + view_height(self) then return end
  local index = math.floor((y - top + self.scroll) / row_height()) + 1
  if index >= 1 and index <= #self.select.options then return index end
end

local function enabled(option)
  return option.enabled ~= false
end

function Menu:on_mouse_moved(x, y)
  local index = self:index_at(x, y)
  if index and enabled(self.select.options[index]) and index ~= self.select.highlight then
    self.select.highlight = index
    core.redraw = true
  end
  return true
end

function Menu:on_mouse_pressed(x, y)
  self.pressed_index = self:index_at(x, y)
  return true
end

-- A release on the row of the press chooses it.
function Menu:on_mouse_released(x, y)
  local index = self:index_at(x, y)
  local select = self.select
  if index and index == self.pressed_index and enabled(select.options[index]) then
    select:choose(select.options[index].value)
    select:close_list()
  end
  self.pressed_index = nil
  return true
end

function Menu:on_mouse_wheel(dy)
  self.scroll = common.clamp(self.scroll - dy * config.mouse_wheel_scroll, 0, max_scroll(self))
  core.redraw = true
  return true
end

function Menu:draw()
  local select = self.select
  local m = ui.metrics()
  local x, y, w, h = self.x, self.y, self.w, self.h
  -- The list grows in from its trigger.
  local amount = ui.approach(self, "amount", 1, 30)
  local pushed = ui.push_look(x, y, w, h, 0.96 + 0.04 * amount, amount)
  surface.draw("popover", x, y, w, h, px(12))
  local pad, row_h = menu_pad(), row_height()
  core.push_clip_rect(x, y + pad, w, h - 2 * pad)
  local font, check_font = ui.font(), ui.small_icon_font()
  local check_w = check_font:get_width(ui.icons.check)
  for i, option in ipairs(select.options) do
    local ry = y + pad + (i - 1) * row_h - self.scroll
    if ry + row_h > y and ry < y + h then
      local rx, rw = x + pad, w - 2 * pad
      local lit = i == select.highlight
      if lit then surface.draw("ghost_hover", rx, ry, rw, row_h, px(7)) end
      local color = lit and style.dialog_text_strong or style.dialog_text
      if not enabled(option) then color = ui.tint(color, 0.5) end
      local label_w = rw - 3 * px(8) - check_w
      common.draw_text(font, color, ui.fit_text(font, option.label, label_w), "left", rx + px(8), ry, 0, row_h)
      if option.value == select.value then
        common.draw_text(check_font, color, ui.icons.check, "right", rx, ry, rw - px(8), row_h)
      end
    end
  end
  core.pop_clip_rect()
  local max = max_scroll(self)
  if max > 0 then
    local view_h = view_height(self)
    local thumb_h = math.max(px(16), view_h * view_h / (view_h + max))
    local thumb_y = y + pad + (view_h - thumb_h) * (self.scroll / max)
    renderer.draw_rounded_rect(x + w - px(5), thumb_y, px(3), thumb_h, px(1.5), ui.tint(style.dialog_text_dim, 0.6))
  end
  ui.pop_look(pushed)
end

------------------------------------------------------------------------------------------------------------------

---@param options { options: table[], value: any, placeholder: string?, on_change: (fun(value: any): boolean?)?, enabled: boolean? }
function Select:new(options)
  Select.super.new(self, options)
  self.options = options.options or {}
  self.value = options.value
  self.placeholder = options.placeholder or "Choose…"
  self.on_change = options.on_change
  self.menu = Menu(self)
  self.text_color = {}
end

---Replace the options and the chosen value. An open list closes.
function Select:set_options(options, value)
  self.options, self.value = options, value
  self:close_list()
end

function Select:set_value(value)
  self.value = value
end

local function index_of(self, value)
  for i, option in ipairs(self.options) do
    if option.value == value then return i end
  end
end

---The label of the chosen option, or nil.
function Select:label()
  local index = index_of(self, self.value)
  return index and self.options[index].label
end

function Select:measure()
  local m, font = ui.metrics(), ui.font()
  local widest = font:get_width(self.placeholder)
  for _, option in ipairs(self.options) do widest = math.max(widest, font:get_width(option.label)) end
  local chevron = ui.small_icon_font():get_width(ui.icons.chevron_down)
  return math.max(math.ceil(widest + 2 * m.pad_x + m.icon_gap + chevron), px(120)), m.control_h
end

---Choose a value. Returns true when it changed.
function Select:choose(value)
  local index = index_of(self, value)
  if not (self.enabled and index and enabled(self.options[index])) or value == self.value then return false end
  if self.on_change and self.on_change(value) == false then return false end
  self.value = value
  core.log_quiet("Select chose: %s", tostring(value))
  return true
end

local function first_enabled(self, from, delta)
  local index = from
  for _ = 1, #self.options do
    index = index + delta
    if index < 1 or index > #self.options then return end
    if enabled(self.options[index]) then return index end
  end
end

---Open the list, with the chosen option highlighted.
function Select:open_list()
  if self.overlay or not self.enabled or #self.options == 0 then return false end
  self.highlight = index_of(self, self.value) or first_enabled(self, 0, 1)
  self.menu.amount, self.menu.scroll, self.menu.pressed_index = 0, 0, nil
  self.reveal = true
  self.overlay = self.menu
  core.redraw = true
  return true
end

function Select:close_list()
  if not self.overlay then return false end
  self.overlay = nil
  core.redraw = true
  return true
end

local function move(self, delta)
  local index = first_enabled(self, self.highlight or (delta > 0 and 0 or #self.options + 1), delta)
  if index then
    self.highlight, self.reveal = index, true
    core.redraw = true
  end
end

function Select:perform(name)
  if not self.enabled then return false end
  local delta = (name == "move_to_previous_line" and -1) or (name == "move_to_next_line" and 1)
    or (name == "move_to_start_of_doc" and -math.huge) or (name == "move_to_end_of_doc" and math.huge)
  if not delta then return false end
  if not self.overlay then
    self:open_list()
  elseif delta == -math.huge then
    self.highlight = nil
    move(self, 1)
  elseif delta == math.huge then
    self.highlight = nil
    move(self, -1)
  else
    move(self, delta)
  end
  return true
end

-- Typed letters highlight the next option whose label starts with them.
function Select:on_text(text)
  if not self.enabled then return false end
  self:open_list()
  if not text:match("%S") then return true end
  local now = system.get_time()
  local typed = (self.typed_time and now - self.typed_time < TYPE_SECONDS and self.typed or "") .. text:lower()
  self.typed, self.typed_time = typed, now
  -- One letter, or the same letter again, moves on to the next option with that letter. Other text searches
  -- from the highlighted option, so it stays while its label still matches.
  local repeated = typed:match("^(.)%1*$")
  local prefix = repeated or typed
  local start = repeated and (self.highlight or 0) or (self.highlight or 1) - 1
  local count = #self.options
  for step = 1, count do
    local index = (start + step - 1) % count + 1
    local option = self.options[index]
    if enabled(option) and option.label:lower():sub(1, #prefix) == prefix then
      self.highlight, self.reveal = index, true
      core.redraw = true
      break
    end
  end
  return true
end

---Enter: choose the highlighted option, or open the list.
function Select:activate()
  if not self.enabled then return false end
  if not self.overlay then return self:open_list() end
  local option = self.highlight and self.options[self.highlight]
  if option then self:choose(option.value) end
  self:close_list()
  return true
end

---Escape: close the list. A closed list has nothing to cancel.
function Select:cancel()
  return self:close_list()
end

function Select:on_mouse_pressed()
  if not self.enabled then return false end
  if not self:close_list() then self:open_list() end
  return true
end

function Select:on_blur()
  self:close_list()
end

-- Place the list below the trigger, or above it when more space is there. It stays inside the Root Panel.
local function place_menu(self)
  local menu = self.menu
  local root = core.root_panel
  local bx, by, bw, bh = popup.bounds(root)
  local top = by + (core.title_bar and core.title_bar.size.y or 0)
  local margin, gap, pad, row_h = px(8), px(4), menu_pad(), row_height()
  local font, check_w = ui.font(), ui.small_icon_font():get_width(ui.icons.check)
  local widest = 0
  for _, option in ipairs(self.options) do widest = math.max(widest, font:get_width(option.label)) end
  local w = math.max(self.w, math.ceil(widest + check_w + 3 * px(8) + 2 * pad))
  local full_h = math.min(#self.options, MAX_ROWS) * row_h + 2 * pad
  local below = by + bh - margin - (self.y + self.h + gap)
  local above = self.y - gap - (top + margin)
  local h, y
  if full_h <= below or below >= above then
    h = math.max(row_h + 2 * pad, math.min(full_h, below))
    y = self.y + self.h + gap
  else
    h = math.max(row_h + 2 * pad, math.min(full_h, above))
    y = self.y - gap - h
  end
  menu.x, menu.y, menu.w = popup.place(root, self.x, y, w, h, nil, margin)
  menu.h = h
  if self.reveal and self.highlight then
    local row_top = (self.highlight - 1) * row_h
    if row_top < menu.scroll then
      menu.scroll = row_top
    elseif row_top + row_h > menu.scroll + view_height(menu) then
      menu.scroll = row_top + row_h - view_height(menu)
    end
  end
  self.reveal = false
  menu.scroll = common.clamp(menu.scroll, 0, max_scroll(menu))
end

function Select:place(x, y, w, h)
  Select.super.place(self, x, y, w, h)
  if self.overlay then place_menu(self) end
end

function Select:draw(focused)
  local m = ui.metrics()
  local x, y, w, h, r = self.x, self.y, self.w, self.h, m.control_radius
  local pushed = ui.push_look(x, y, w, h, 1, self.enabled and 1 or ui.DISABLED_OPACITY)
  if focused then ui.draw_ring(x, y, w, h, r) end
  surface.draw("raised", x, y, w, h, r)
  local hover = ui.approach(self, "hover_amount", self.enabled and (self.hovered or self.overlay) and 1 or 0, 30)
  if hover > 0 then
    local faded = ui.push_look(x, y, w, h, 1, hover)
    surface.draw("raised_hover", x, y, w, h, r)
    ui.pop_look(faded)
  end
  local label = self:label()
  local color = label and ui.mix(style.dialog_text, style.dialog_text_strong, hover, self.text_color)
    or style.dialog_placeholder
  local chevron_font = ui.small_icon_font()
  local chevron_w = chevron_font:get_width(ui.icons.chevron_down)
  local font = ui.font()
  local text_w = w - 2 * m.pad_x - m.icon_gap - chevron_w
  common.draw_text(font, color, ui.fit_text(font, label or self.placeholder, text_w), "left", x + m.pad_x, y, 0, h)
  common.draw_text(chevron_font, style.dialog_text_muted, ui.icons.chevron_down, "right", x, y, w - m.pad_x, h)
  ui.pop_look(pushed)
end

return Select
