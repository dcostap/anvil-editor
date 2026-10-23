local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local View = require "core.view"
local style = require "core.style"

-- The nag bar: a modal confirmation card at the top of the Window. It shows a title, a message and a row of choices,
-- and dims the rest of the Window, including a hosted shell's Sidebar. Dialogs queue and show one at a time.
-- A message is a string, or a table of styled lines:
--   {filetree_styled_nag_message = true, lines = {{{text = "MOVE", font = ..., color = ...}, ...}, ...}}
-- The card floats over the Panes. It does not move them.

-- How fast the card fades in and out, per second.
local SHOW_RATE, HIDE_RATE = 18, 26

local noop = function() end

---@class core.nagview.option
---@field text string Button text
---@field default_yes? boolean The choice for Enter and Y
---@field default_no? boolean The choice for Escape and N

---@class core.nagview.queue_item
---@field title string Dialog title
---@field message string|table Dialog message text, or styled lines
---@field options core.nagview.option[] Available button options
---@field on_selected? fun(option: core.nagview.option): boolean? Return false to keep the dialog open

---@class core.nagview : core.view
---@field queue core.nagview.queue_item[] Queued dialogs waiting to show
---@field visible boolean Whether a dialog is open
---@field progress number How far the card has shown, from 0 to 1
---@field title string? Current dialog title
---@field message (string|table)? Current dialog message
---@field options core.nagview.option[]? Current dialog options
---@field on_selected function? Current dialog selection callback
---@field hovered_item integer? The selected choice: Enter performs it, and a focus ring marks it
---@field pointer_item integer? The choice under the pointer
---@field pressed_item integer? The choice pressed with the left mouse button
local NagView = View:extend()

function NagView:__tostring() return "NagView" end

function NagView:new()
  NagView.super.new(self)
  self.queue = {}
  self.visible = false
  self.progress = 0
end

function NagView:get_title()
  return self.title
end

-- Sizes in pixels at the current scale.
local function metrics()
  local h = style.view_text_font:get_height()
  return {
    -- Space between the Title Bar and the card, and the least space beside and below it.
    top = 12 * SCALE, side = 24 * SCALE,
    pad = 20 * SCALE, radius = 10 * SCALE,
    min_width = 380 * SCALE, text_width = 560 * SCALE,
    title_gap = 6 * SCALE, buttons_gap = 18 * SCALE,
    button_h = math.floor(h + 14 * SCALE + 0.5), button_min = 76 * SCALE,
    button_pad = 14 * SCALE, button_gap = 8 * SCALE, button_radius = 6 * SCALE,
    shadow = 3 * 3 * SCALE,
  }
end

-- The card uses the Sidebar's and Title Bar's proportional font. Styled message parts can set their own font.
local bold_fonts = setmetatable({}, {__mode = "k"})
local function title_font()
  local font = style.view_text_font
  bold_fonts[font] = bold_fonts[font] or font:copy(font:get_size(), {bold = true})
  return bold_fonts[font]
end

local function fade(color, alpha)
  return {color[1], color[2], color[3], (color[4] or 255) * alpha}
end

------------------------------------------------------------------------------------------------------------------
-- Message layout: styled parts, wrapped at spaces. A word wider than the line breaks between characters.

local function line_height(font_height)
  return math.max(common.round(font_height * config.line_height), font_height)
end

local function tokens_of(line)
  local tokens = {}
  for _, part in ipairs(line) do
    local font, color = part.font or style.view_text_font, part.color or style.nagbar_text
    for text, space in tostring(part.text or ""):gmatch("([^%s]*)(%s*)") do
      for _, piece in ipairs {{text, false}, {space, true}} do
        if piece[1] ~= "" then
          tokens[#tokens + 1] = {text = piece[1], font = font, color = color, space = piece[2],
            width = font:get_width(piece[1])}
        end
      end
    end
  end
  return tokens
end

local function split_word(token, max_width)
  if token.width <= max_width then return {token} end
  local chunks, start = {}, 1
  while start <= #token.text do
    local stop = start - 1
    for char in token.text:sub(start):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local next_stop = stop + #char
      if stop >= start and token.font:get_width(token.text:sub(start, next_stop)) > max_width then break end
      stop = next_stop
    end
    local text = token.text:sub(start, stop)
    chunks[#chunks + 1] = {text = text, font = token.font, color = token.color, width = token.font:get_width(text)}
    start = stop + 1
  end
  return chunks
end

-- The message's lines wrapped at `max_width`, with the widest line's width and the total height.
local function layout_message(message, max_width)
  local source = {}
  if type(message) == "table" then
    source = message.lines or {}
  else
    for text in (tostring(message or "") .. "\n"):gmatch("(.-)\r?\n") do source[#source + 1] = {{text = text}} end
  end
  local lines, width, height = {}, 0, 0
  local line
  local function finish()
    while line.parts[#line.parts] and line.parts[#line.parts].space do
      line.width = line.width - table.remove(line.parts).width
    end
    line.height = line_height(line.font_height)
    lines[#lines + 1], width, height = line, math.max(width, line.width), height + line.height
  end
  for _, source_line in ipairs(source) do
    line = {parts = {}, width = 0, font_height = style.view_text_font:get_height()}
    for _, token in ipairs(tokens_of(source_line)) do
      for _, piece in ipairs(token.space and {token} or split_word(token, max_width)) do
        if #line.parts > 0 and line.width + piece.width > max_width then
          finish()
          line = {parts = {}, width = 0, font_height = style.view_text_font:get_height(), wrapped = true}
        end
        -- A wrapped line does not start with the space where it wrapped.
        if not (piece.space and line.wrapped and #line.parts == 0) then
          line.parts[#line.parts + 1] = piece
          line.width = line.width + piece.width
          line.font_height = math.max(line.font_height, piece.font:get_height())
        end
      end
    end
    finish()
  end
  return lines, width, height
end

------------------------------------------------------------------------------------------------------------------
-- Card layout

-- The card's place and content. The card is centred on the Window, below the Title Bar, and grows with its message
-- up to a readable width. Its buttons can make it wider.
function NagView:layout()
  local bx, _, bw, bh = core.root_panel:backdrop_rect()
  local cache = self.layout_cache
  if cache and cache.title == self.title and cache.message == self.message and cache.options == self.options
    and cache.font == style.view_text_font and cache.scale == SCALE and cache.bx == bx and cache.bw == bw
    and cache.top == self.position.y and cache.bh == bh and cache.queued == #self.queue then
    return cache.layout
  end
  local m = metrics()
  local font = style.view_text_font
  local buttons, buttons_w = {}, 0
  for i, option in ipairs(self.options or {}) do
    buttons[i] = {w = math.max(m.button_min, font:get_width(option.text) + 2 * m.button_pad)}
    buttons_w = buttons_w + buttons[i].w + (i > 1 and m.button_gap or 0)
  end
  local queued = #self.queue > 0 and string.format("%d more", #self.queue) or nil
  local header_w = title_font():get_width(self.title or "") + (queued and font:get_width(queued) + m.pad or 0)
  local _, natural_w = layout_message(self.message, math.huge)
  local available_w = math.max(1, bw - 2 * m.side)
  local w = math.min(math.max(math.min(math.max(header_w, natural_w) + 2 * m.pad, m.text_width), m.min_width,
    buttons_w + 2 * m.pad), available_w)
  local lines, _, message_h = layout_message(self.message, math.max(1, w - 2 * m.pad))
  local fixed_h = 2 * m.pad + line_height(title_font():get_height()) + m.title_gap + m.buttons_gap + m.button_h
  local h = math.min(fixed_h + message_h, math.max(fixed_h, bh - self.position.y - m.top - m.side))
  local x, y = math.floor(bx + (bw - w) / 2), math.floor(self.position.y + m.top)
  local layout = {x = x, y = y, w = w, h = h, lines = lines, queued = queued,
    title_y = y + m.pad, message_y = y + m.pad + line_height(title_font():get_height()) + m.title_gap,
    message_h = h - fixed_h, buttons = buttons}
  -- Buttons sit at the card's lower right, in their order.
  local button_x = x + w - m.pad - buttons_w
  for _, button in ipairs(buttons) do
    button.x, button.y, button.h = button_x, y + h - m.pad - m.button_h, m.button_h
    button_x = button_x + button.w + m.button_gap
  end
  self.layout_cache = {title = self.title, message = self.message, options = self.options, font = style.view_text_font,
    scale = SCALE, bx = bx, bw = bw, bh = bh, top = self.position.y, queued = #self.queue,
    layout = layout}
  return layout
end

---Iterate over the choices with their button rectangles.
---@return fun(): integer, core.nagview.option, number, number, number, number
function NagView:each_option()
  return coroutine.wrap(function()
    if not self.options then return end
    for i, button in ipairs(self:layout().buttons) do
      coroutine.yield(i, self.options[i], button.x, button.y, button.w, button.h)
    end
  end)
end

---The choice under a point, or nil.
function NagView:option_at(mx, my)
  for i, _, x, y, w, h in self:each_option() do
    if mx >= x and my >= y and mx < x + w and my < y + h then return i end
  end
end

------------------------------------------------------------------------------------------------------------------
-- Input

---Select a choice: Enter performs it.
---@param i integer?
function NagView:change_hovered(i)
  if i ~= self.hovered_item then
    self.hovered_item = i
    core.redraw = true
  end
end

function NagView:on_mouse_moved(mx, my, ...)
  if not self.visible then return end
  core.set_active_view(self)
  NagView.super.on_mouse_moved(self, mx, my, ...)
  local pointed = self:option_at(mx, my)
  if pointed ~= self.pointer_item then self.pointer_item, core.redraw = pointed, true end
  self.cursor = pointed and "hand" or "arrow"
  core.request_cursor(self.cursor)
  if pointed then self:change_hovered(pointed) end
end

function NagView:on_mouse_left()
  NagView.super.on_mouse_left(self)
  if self.pointer_item then self.pointer_item, core.redraw = nil, true end
end

function NagView:on_mouse_pressed(button, mx, my, clicks)
  if not self.visible then return false end
  if NagView.super.on_mouse_pressed(self, button, mx, my, clicks) then return true end
  self.pressed_item = button == "left" and self:option_at(mx, my) or nil
  if self.pressed_item then self:change_hovered(self.pressed_item) end
  core.redraw = true
  return true
end

---A choice acts when the left button is released over the button it pressed.
function NagView:on_mouse_released(button, mx, my)
  NagView.super.on_mouse_released(self, button, mx, my)
  local pressed = self.pressed_item
  self.pressed_item = nil
  core.redraw = true
  if self.visible and button == "left" and pressed and self:option_at(mx, my) == pressed then
    self:change_hovered(pressed)
    command.perform "core:select_dialog_entry"
  end
  return self.visible or pressed ~= nil
end

---Y and N choose the default yes and no choices.
function NagView:on_text_input(text)
  if not self.visible then return false end
  if text:lower() == "y" then
    command.perform "core:select_dialog_yes"
  elseif text:lower() == "n" then
    command.perform "core:select_dialog_no"
  end
  return true
end

---Handle keys before normal View commands and shortcuts.
function NagView:on_key_pressed(key, event)
  if not self.visible then return false end
  if key == "return" or key == "keypad enter" then
    command.perform "core:select_dialog_entry"
  elseif key == "r" and event and event.alt
      and not event.altgr and not event.ctrl and not event.shift and not event.gui then
    command.perform "core:select_dialog_entry"
  elseif key == "escape" then
    command.perform "core:select_dialog_no"
  elseif key == "left" or key == "up" or key == "tab" and event and event.shift then
    command.perform "core:select_previous_dialog_entry"
  elseif key == "right" or key == "down" or key == "tab" then
    command.perform "core:select_next_dialog_entry"
  end
  return true
end

------------------------------------------------------------------------------------------------------------------
-- Motion and drawing

function NagView:update()
  if not self.visible and self.progress <= 0 then self.last_step = nil; return end
  NagView.super.update(self)
  local shown = self.visible and core.active_view == self and self.title ~= nil
  local target = shown and 1 or 0
  local now = system.get_time()
  local dt = self.last_step and math.min(0.1, now - self.last_step) or 0
  self.last_step = now
  if not config.transitions or config.disabled_transitions.nagbar or core.in_live_resize_frame then
    self.progress = target
  elseif self.progress ~= target then
    local rate = (shown and SHOW_RATE or HIDE_RATE) * (config.animation_rate or 1)
    self.progress = target + (self.progress - target) * math.exp(-rate * dt)
    if math.abs(self.progress - target) < 0.004 then self.progress = target end
    core.redraw = true
  end
  if not shown and self.progress <= 0 then
    self.title, self.message, self.options, self.on_selected = nil, nil, nil, nil
    self.pointer_item, self.pressed_item, self.layout_cache = nil, nil, nil
  end
end

-- Dims the Window below the Title Bar, and the hosted shell's Sidebar.
function NagView:draw_dim()
  local x, _, w, h = core.root_panel:backdrop_rect()
  local color = fade(style.nagbar_dim, self.progress)
  renderer.draw_rect(x, self.position.y, w, h - self.position.y, color)
  core.root_panel:dim_sidebar(color)
end

function NagView:draw_button(i, option, button)
  local m = metrics()
  local primary = option.default_yes
  local x, y, w, h, r = button.x, button.y, button.w, button.h, m.button_radius
  -- A focus ring, just outside the button, marks the choice for Enter.
  if i == self.hovered_item then
    local ring = math.max(1, math.floor(2 * SCALE + 0.5))
    local gap = ring + math.max(1, math.floor(SCALE + 0.5))
    renderer.draw_rounded_rect(x - gap, y - gap, w + 2 * gap, h + 2 * gap, r + gap, style.accent)
    renderer.draw_rounded_rect(x - gap + ring, y - gap + ring, w + 2 * (gap - ring), h + 2 * (gap - ring),
      r + gap - ring, style.nagbar)
  end
  renderer.draw_rounded_rect(x, y, w, h, r, primary and style.accent or style.nagbar_button)
  local pressed = i == self.pressed_item and self.pointer_item == i
  if pressed then
    renderer.draw_rounded_rect(x, y, w, h, r, style.nagbar_button_pressed)
  elseif i == self.pointer_item then
    renderer.draw_rounded_rect(x, y, w, h, r, style.nagbar_button_hover)
  end
  common.draw_text(style.view_text_font, primary and style.nagbar_primary_text or style.text, option.text, "center",
    x, y, w, h)
end

local function draw_nagview(self)
  local p = self.progress
  self:draw_dim()
  local layout = self:layout()
  local m = metrics()
  local x, y, w, h = layout.x, layout.y, layout.w, layout.h
  -- The card settles into place from slightly above, at a slightly smaller size.
  local shift = math.floor((1 - p) * -8 * SCALE + 0.5)
  y = y + shift
  core.root_panel:show_above_sidebar(x - m.shadow, y - m.shadow, w + 2 * m.shadow, h + 2 * m.shadow)
  local transformed = p < 0.999
  if transformed then renderer.push_transform(x + w / 2, y, 0.97 + 0.03 * p, p) end
  for i = 3, 1, -1 do
    local spread = i * 3 * SCALE
    renderer.draw_rounded_rect(x - spread, y - spread + 4 * SCALE, w + 2 * spread, h + 2 * spread,
      m.radius + spread, fade(style.nagbar_shadow, (4 - i) / 6))
  end
  local border = math.max(1, math.floor(SCALE + 0.5))
  renderer.draw_rounded_rect(x, y, w, h, m.radius, style.nagbar_border)
  renderer.draw_rounded_rect(x + border, y + border, w - 2 * border, h - 2 * border, m.radius - border,
    style.nagbar)

  local font, title = style.view_text_font, title_font()
  local title_h = line_height(title:get_height())
  local title_w = w - 2 * m.pad
  if layout.queued then
    local queued_w = font:get_width(layout.queued)
    title_w = title_w - queued_w - m.pad
    renderer.draw_text(font, layout.queued, x + w - m.pad - queued_w,
      layout.title_y + shift + (title_h - font:get_height()) / 2, style.dim)
  end
  core.push_clip_rect(x + m.pad, layout.title_y + shift, math.max(0, title_w), title_h)
  renderer.draw_text(title, self.title, x + m.pad, layout.title_y + shift + (title_h - title:get_height()) / 2,
    style.text)
  core.pop_clip_rect()

  local message_y = layout.message_y + shift
  core.push_clip_rect(x + m.pad, message_y, w - 2 * m.pad, layout.message_h)
  for _, line in ipairs(layout.lines) do
    local lx = x + m.pad
    for _, part in ipairs(line.parts) do
      renderer.draw_text(part.font, part.text, lx, message_y + (line.height - part.font:get_height()) / 2,
        part.color)
      lx = lx + part.width
    end
    message_y = message_y + line.height
  end
  core.pop_clip_rect()

  for i, button in ipairs(layout.buttons) do
    self:draw_button(i, self.options[i], {x = button.x, y = button.y + shift, w = button.w, h = button.h})
  end
  if transformed then renderer.pop_transform() end
end

function NagView:draw()
  if (not self.visible and self.progress <= 0) or not self.title then return end
  core.root_panel:defer_draw(draw_nagview, self)
end

------------------------------------------------------------------------------------------------------------------
-- Queue

---Show the next dialog from the queue, or close the card when the queue is empty.
function NagView:next()
  local opts = table.remove(self.queue, 1)
  if opts then
    self.visible = true
    self.title, self.message, self.options, self.on_selected = opts.title, opts.message, opts.options,
      opts.on_selected
    self.pressed_item = nil
    self.hovered_item = nil
    self:change_hovered(common.find_index(self.options, "default_yes"))
    -- Focus stays on the card while it is open. A focus request waits in core.next_active_view.
    self.force_focus = true
    core.set_active_view(self)
    core.root_panel:push_modal_input(self, { label = "confirmation" })
  else
    self.force_focus = false
    core.root_panel:pop_modal_input(self)
    core.set_active_view(core.next_active_view or core.last_active_view)
    self.visible = false
  end
end

---Change the open dialog in place, for a choice whose facts changed while it was open.
---@param title string
---@param message string|table
---@param options core.nagview.option[]
function NagView:replace(title, message, options)
  self.title, self.message, self.options = title, message, options
  self.pressed_item = nil
  self:change_hovered(common.find_index(options, "default_yes"))
  core.redraw = true
end

---Queue a dialog, and show it when no other dialog is open.
---@param title string Dialog title
---@param message string|table Dialog message, or styled lines
---@param options core.nagview.option[] Button options
---@param on_select? fun(option: core.nagview.option): boolean? Return false to keep the dialog open
function NagView:show(title, message, options, on_select)
  table.insert(self.queue, {
    title = assert(title, "No title"),
    message = assert(message, "No message"),
    options = assert(options, "No options"),
    on_selected = on_select or noop,
  })
  if not self.visible then self:next() end
end

return NagView
