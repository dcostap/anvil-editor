local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local Object = require "core.object"


---Status Bar along the bottom of one Pane. It draws the shared Status Bar
---items for the Pane's Current View as chips. Hovering a chip shows its
---tooltip; a chip with an action highlights and runs it on a left click.
---The focused Pane's bar also shows temporary messages and widget tooltips.
---@class core.pane_status_bar : core.view
---@field super core.view
---@field controller core.statusbar Shared Status Bar state
---@field pane table Pane this bar belongs to
---@field status_bar_pane table Same Pane, for the Root Panel's click focus
---@field entries table[] Laid-out chips: { item, x, w, visible_w, styled }
---@field message_entry table|nil Laid-out message chip
---@field hovered table|nil Entry under the pointer
---@field pressed table|nil Entry that received the current left press
---@field left_limit number Right edge of the left chips, relative to the bar
local PaneStatusBar = View:extend()

function PaneStatusBar:__tostring() return "PaneStatusBar" end

local TOOLTIP_DELAY = 0.35
-- After one tooltip shows, moving to a neighbor shows its tooltip at once.
local TOOLTIP_GRACE = 0.6
local ELLIPSIS = "…"

---Font for Pane Status Bar text.
---@return renderer.font
function PaneStatusBar.font()
  return style.get_small_font(style.font)
end

local function metrics()
  return {
    edge = common.round(style.padding.x * 0.5),
    chip = common.round(style.padding.x * 0.45),
    gap = common.round(2 * SCALE),
    inset = common.round(2 * SCALE),
    radius = common.round(4 * SCALE),
  }
end


---Iterate the strings of styled text with their font and color.
local function each_segment(styled, fn)
  local font = PaneStatusBar.font()
  local color = style.text
  for _, part in ipairs(styled) do
    if Object.is(part, renderer.font) then
      font = part
    elseif type(part) == "table" then
      color = part
    elseif part ~= nil then
      fn(font, color, tostring(part))
    end
  end
end

local function styled_width(styled)
  local w = 0
  each_segment(styled, function(font, _, text) w = w + font:get_width(text) end)
  return w
end

---Text in the bars of unfocused Panes draws at this share of its opacity.
local UNFOCUSED_OPACITY = 0.7

local function draw_styled(styled, x, y, h, opacity)
  each_segment(styled, function(font, color, text)
    local ty = common.round(y + (h - font:get_height()) / 2)
    if opacity ~= 1 then
      color = { color[1], color[2], color[3], (color[4] or 255) * opacity }
    end
    x = renderer.draw_text(font, text, common.round(x), ty, color)
  end)
  return x
end

---Drop text from the start of styled text so it fits in `max_w`.
---@return core.statusbar.styledtext
local function elide_start(styled, max_w)
  local total = styled_width(styled)
  if total <= max_w then return styled end
  local font = PaneStatusBar.font()
  local need = total - max_w + font:get_width(ELLIPSIS)
  local dropped = 0
  local out = { font, style.dim, ELLIPSIS }
  each_segment(styled, function(seg_font, color, text)
    if dropped < need then
      local w = seg_font:get_width(text)
      if dropped + w <= need then
        dropped = dropped + w
        return
      end
      while text ~= "" and dropped < need do
        local ch = text:match("^[%z\1-\127\194-\244][\128-\191]*") or text:sub(1, 1)
        dropped = dropped + seg_font:get_width(ch)
        text = text:sub(#ch + 1)
      end
      if text == "" then return end
    end
    table.insert(out, seg_font)
    table.insert(out, color)
    table.insert(out, text)
  end)
  return out
end

local function rendered_message(message)
  return {
    message.icon_color, style.icon_font, message.icon,
    PaneStatusBar.font(), style.text, "  " .. tostring(message.text),
  }
end


---@param controller core.statusbar
---@param pane table
function PaneStatusBar:new(controller, pane)
  PaneStatusBar.super.new(self)
  self.controller = controller
  self.pane = pane
  self.status_bar_pane = pane
  self.entries = {}
  self.message_entry = nil
  self.hovered = nil
  self.pressed = nil
  self.hover_start = 0
  self.tooltip_dismissed = nil
  self.left_limit = 0
end

---The View whose items this bar shows.
---@return core.view|nil
function PaneStatusBar:get_view()
  return self.pane.current_view
end

---Whether this bar belongs to the focused Pane.
---@return boolean
function PaneStatusBar:is_focused()
  local panes = core.panes or require "core.panes"
  return panes.active() == self.pane
end

---Find the laid-out chip of an item.
---@param name string
---@return table|nil entry
function PaneStatusBar:get_entry(name)
  for _, entry in ipairs(self.entries) do
    if entry.item.name == name then return entry end
  end
end

---Evaluate the items for the Pane's View and lay them out as chips.
---Right chips keep their full width; left chips use the space that is left.
---Unfocused Panes show only their left items, which name the file.
function PaneStatusBar:layout()
  local m = metrics()
  local view = self:get_view()
  local focused = self:is_focused()
  local lefts, rights = {}, {}
  self.entries = {}

  for _, item in ipairs(view and self.controller.items or {}) do
    if item.visible and (focused or item.alignment == item.LEFT) and item.predicate(view) then
      local styled, content_w
      if item.on_draw then
        content_w = item.on_draw(view, 0, self.position.y, self.size.y, false, true)
      else
        styled = type(item.get_item) == "function" and item.get_item(item, view) or item.get_item
        content_w = styled and #styled > 0 and styled_width(styled) or 0
      end
      if content_w > 0 then
        local entry = { item = item, styled = styled, w = content_w + m.chip * 2 }
        table.insert(item.alignment == item.RIGHT and rights or lefts, entry)
      end
    end
  end

  -- Optional right items hide together when they would cut the left items short.
  local need = m.edge * 2 + style.padding.x
  for _, entry in ipairs(lefts) do need = need + entry.w + m.gap end
  for _, entry in ipairs(rights) do need = need + entry.w + m.gap end
  if need > self.size.x then
    local kept = {}
    for _, entry in ipairs(rights) do
      if not entry.item.optional then kept[#kept + 1] = entry end
    end
    rights = kept
  end

  local x = self.size.x - m.edge
  for i = #rights, 1, -1 do
    local entry = rights[i]
    x = x - entry.w
    entry.x = x
    entry.visible_w = entry.w
    x = x - m.gap
  end
  local right_start = #rights > 0 and x + m.gap or self.size.x - m.edge
  self.left_limit = math.max(m.edge, right_start - style.padding.x)

  x = m.edge
  for _, entry in ipairs(lefts) do
    if entry.item.shrink then entry.w = math.max(0, math.min(entry.w, self.left_limit - x)) end
    entry.x = x
    entry.visible_w = math.max(0, math.min(entry.w, self.left_limit - x))
    x = x + entry.w + m.gap
  end

  self.message_entry = nil
  local controller = self.controller
  if focused and controller:message_active() then
    local w = styled_width(rendered_message(controller.message)) + m.chip * 2
    self.message_entry = {
      item = controller.message_item, x = m.edge, w = w,
      visible_w = math.max(0, math.min(w, self.left_limit - m.edge)),
    }
  end

  for _, entry in ipairs(lefts) do table.insert(self.entries, entry) end
  for _, entry in ipairs(rights) do table.insert(self.entries, entry) end

  -- Keep hover and press on the same item across layouts.
  local function carry(old)
    if not old then return nil end
    if old.item == controller.message_item then return self.message_entry end
    for _, entry in ipairs(self.entries) do
      if entry.item == old.item then return entry end
    end
  end
  self.hovered = carry(self.hovered)
  self.pressed = carry(self.pressed)
end

---Whether the left chips are replaced by a message or a widget tooltip.
---@return boolean
function PaneStatusBar:left_replaced()
  return self.message_entry ~= nil or (self.controller.tooltip_mode and self:is_focused())
end

---Find the chip under a point.
---@param x number
---@param y number
---@return table|nil entry
function PaneStatusBar:entry_at(x, y)
  if y < self.position.y or y >= self.position.y + self.size.y then return nil end
  local rx = x - self.position.x
  local function hit(entry)
    return entry.visible_w > 0 and rx >= entry.x and rx < entry.x + entry.visible_w
  end
  if self.message_entry and hit(self.message_entry) then return self.message_entry end
  local left_replaced = self:left_replaced()
  for _, entry in ipairs(self.entries) do
    if (entry.item.alignment == entry.item.RIGHT or not left_replaced) and hit(entry) then
      return entry
    end
  end
end

local function clickable(self, entry)
  return entry ~= nil and entry.item:is_clickable(self:get_view())
end

local function set_hovered(self, entry)
  if self.hovered == entry then return end
  self.hovered = entry
  self.hover_start = system.get_time()
  self.tooltip_dismissed = nil
  core.redraw = true
end


---A left press arms the clicked chip. The Root Panel has already focused this Pane.
function PaneStatusBar:on_mouse_pressed(button, x, y, clicks)
  self:layout()
  local entry = self:entry_at(x, y)
  set_hovered(self, entry)
  if button == "left" and clickable(self, entry) then
    self.pressed = entry
    self.tooltip_dismissed = entry
    core.redraw = true
  end
  return true
end

function PaneStatusBar:on_mouse_left()
  PaneStatusBar.super.on_mouse_left(self)
  set_hovered(self, nil)
  self.pressed = nil
  self.cursor = "arrow"
end

function PaneStatusBar:on_mouse_moved(x, y, dx, dy)
  PaneStatusBar.super.on_mouse_moved(self, x, y, dx, dy)
  local entry = self:entry_at(x, y)
  set_hovered(self, entry)
  self.cursor = clickable(self, entry) and "hand" or "arrow"
end

---Run the pressed chip's action when the release lands on the same chip.
function PaneStatusBar:on_mouse_released(button, x, y)
  PaneStatusBar.super.on_mouse_released(self, button, x, y)
  local pressed = self.pressed
  self.pressed = nil
  if button ~= "left" or not pressed then return end
  core.redraw = true
  local view = self:get_view()
  if self:entry_at(x, y) ~= pressed or not clickable(self, pressed) then return end
  local item = pressed.item
  core.log_quiet("Pane Status Bar item clicked: %s pane=%s", item.name, tostring(self.pane.id))
  if item.command then
    command.perform(item.command)
  elseif item.on_click then
    local h = self.size.y
    item.on_click(view, button, x, y, { x = self.position.x + pressed.x, y = self.position.y, w = pressed.w, h = h })
  end
end

function PaneStatusBar:update()
  if self.size.y <= 0 then return end
  local hovered = self.hovered
  if hovered and hovered ~= self.tooltip_dismissed and system.get_time() - self.hover_start < TOOLTIP_DELAY then
    core.redraw = true
  end
  self:layout()
end


local function tooltip_lines(text, hint)
  local lines = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then table.insert(lines, { style.text, line }) end
  end
  if hint then table.insert(lines, { style.dim, hint }) end
  return lines
end

---Draw the hover tooltip of a chip above the bar.
---@param entry table
function PaneStatusBar:draw_tooltip(entry)
  local text, hint = entry.item:get_tooltip(self:get_view())
  local lines = tooltip_lines(text, hint)
  if #lines == 0 then return end
  self.controller.tooltip_shown_at = system.get_time()
  local bar_x, bar_y = self.position.x, self.position.y
  core.root_panel:defer_draw(function()
    local font = PaneStatusBar.font()
    local line_h = font:get_height()
    local pad_x, pad_y = common.round(style.padding.x * 0.6), common.round(style.padding.y * 0.6)
    local w = 0
    for _, line in ipairs(lines) do w = math.max(w, font:get_width(line[2])) end
    w = w + pad_x * 2
    local h = line_h * #lines + pad_y * 2
    local root = core.root_panel
    -- Keep the box and its 1px border a small gap away from the window edges.
    local margin = common.round(4 * SCALE) + 1
    local x = common.clamp(bar_x + entry.x,
      root.position.x + margin, root.position.x + root.size.x - w - margin)
    local y = bar_y - h - common.round(4 * SCALE)
    local radius = common.round(4 * SCALE)
    renderer.draw_rounded_rect(x - 1, y - 1, w + 2, h + 2, radius + 1, style.divider)
    renderer.draw_rounded_rect(x, y, w, h, radius, style.background3)
    local ty = y + pad_y
    for _, line in ipairs(lines) do
      renderer.draw_text(font, line[2], common.round(x + pad_x), common.round(ty), line[1])
      ty = ty + line_h
    end
  end)
end

function PaneStatusBar:draw()
  if self.size.y <= 0 then return end
  local m = metrics()
  local x0, y0, h = self.position.x, self.position.y, self.size.y
  local view = self:get_view()
  local focused = self:is_focused()
  local controller = self.controller
  local opacity = focused and 1 or UNFOCUSED_OPACITY

  core.push_clip_rect(x0, y0, self.size.x, h)
  renderer.draw_rect(x0, y0, self.size.x, h, style.wallpaper_surface(style.background))

  local function draw_chip_background(entry)
    if entry.visible_w <= 0 or not clickable(self, entry) then return end
    local color
    if self.pressed == entry and self.hovered == entry then
      color = style.titlebar_control_pressed
    elseif self.hovered == entry and not self.pressed then
      color = style.titlebar_control_hover
    end
    if color then
      renderer.draw_rounded_rect(x0 + entry.x, y0 + m.inset, entry.visible_w, h - m.inset * 2, m.radius, color)
    end
  end

  local function draw_entry(entry)
    draw_chip_background(entry)
    local cx = x0 + entry.x + m.chip
    local item = entry.item
    if item.on_draw then
      core.push_clip_rect(x0 + entry.x, y0, entry.visible_w, h)
      item.on_draw(view, cx, y0, h, self.hovered == entry)
      core.pop_clip_rect()
    else
      local styled = entry.styled
      if item.shrink then styled = elide_start(styled, entry.w - m.chip * 2) end
      draw_styled(styled, cx, y0, h, opacity)
    end
  end

  core.push_clip_rect(x0, y0, self.left_limit, h)
  if self.message_entry and controller.message then
    local entry = self.message_entry
    draw_chip_background(entry)
    local styled = elide_start(rendered_message(controller.message), entry.visible_w - m.chip * 2)
    draw_styled(styled, x0 + entry.x + m.chip, y0 + controller:message_pulse_offset(), h, opacity)
  elseif focused and controller.tooltip_mode then
    draw_styled(elide_start(controller.tooltip, self.left_limit - m.edge - m.chip), x0 + m.edge + m.chip, y0, h, opacity)
  else
    for _, entry in ipairs(self.entries) do
      if entry.item.alignment == entry.item.LEFT then draw_entry(entry) end
    end
  end
  core.pop_clip_rect()

  for _, entry in ipairs(self.entries) do
    if entry.item.alignment == entry.item.RIGHT then draw_entry(entry) end
  end

  renderer.draw_rect(x0, y0, self.size.x, style.divider_size or 1, style.divider)
  core.pop_clip_rect()

  local hovered = self.hovered
  if hovered and hovered ~= self.tooltip_dismissed then
    local now = system.get_time()
    if now - self.hover_start >= TOOLTIP_DELAY or now - controller.tooltip_shown_at < TOOLTIP_GRACE then
      self:draw_tooltip(hovered)
    end
  end
end

return PaneStatusBar
