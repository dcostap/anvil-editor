local core = require "core"
local style = require "core.style"
local ui = require "core.ui"
local Control = require "core.ui.control"
local LineInput = require "core.line_input"

-- A one-line text field. The editor's line commands edit it, with the user's bindings.
-- Enter, or a focus change, submits the text. `on_submit(text)` returns false, or false and a message, to refuse it.
-- A refused submit keeps the text for Enter and shows the message. A focus change puts back the last accepted text.
-- Escape puts back the last accepted text.
local TextField = Control:extend()

TextField.focusable = true
TextField.takes_text = true
TextField.cursor = "ibeam"

---@param options { text: string?, placeholder: string?, on_submit: (fun(text: string): boolean?, string?)?, on_change: fun(text: string)?, enabled: boolean?, secret: boolean? }
function TextField:new(options)
  TextField.super.new(self, options)
  self.input = LineInput(options.text or "")
  self.accepted = self.input.text
  self.placeholder = options.placeholder
  self.on_submit = options.on_submit
  self.on_change = options.on_change
  self.secret = options.secret == true
  self.scroll = 0
  self.error = nil
end

function TextField:get_text()
  return self.input.text
end

---Replace the text without a submit. It becomes the accepted text.
function TextField:set_text(text)
  self.input:set_text(text or "")
  self.accepted = self.input.text
  self.error = nil
  self.scroll = 0
  core.redraw = true
end

function TextField:select_all()
  self.input:perform("select_all")
  core.redraw = true
end

function TextField:changed()
  self.error = nil
  if self.on_change then self.on_change(self.input.text) end
  core.redraw = true
end

---Offer the text to `on_submit`. Returns true when it was accepted.
function TextField:submit()
  local text = self.input.text
  if text == self.accepted then
    self.error = nil
    return true
  end
  local ok, message = true, nil
  if self.on_submit then ok, message = self.on_submit(text) end
  if ok == false then
    self.error = message
    core.redraw = true
    return false
  end
  self.accepted, self.error = text, nil
  core.redraw = true
  return true
end

function TextField:on_text(text)
  if not self.enabled then return false end
  self.input:insert(text)
  self:changed()
  return true
end

function TextField:perform(name)
  if not self.enabled then return false end
  if self.secret and (name == "copy" or name == "cut") then return true end
  local before_text, before_caret, before_anchor = self.input.text, self.input.caret, self.input.anchor
  if not self.input:perform(name) then return false end
  if self.input.text ~= before_text then
    self:changed()
  elseif self.input.caret ~= before_caret or self.input.anchor ~= before_anchor then
    core.redraw = true
  end
  return true
end

function TextField:activate()
  if not self.enabled then return false end
  self:submit()
  return true
end

function TextField:cancel()
  if self.input.text == self.accepted and not self.error then return false end
  self.input:set_text(self.accepted)
  self.error = nil
  core.redraw = true
  return true
end

function TextField:on_focus()
  self:select_all()
end

function TextField:on_blur()
  if not self:submit() then
    self.input:set_text(self.accepted)
    self.error = nil
  end
  -- The selection shows only with focus. The next focus selects all again.
  self.input:set_caret(#self.input.text)
end

local function text_x(self)
  return self.x + ui.metrics().pad_x - self.scroll
end

function TextField:offset_at(x)
  if self.secret then
    local width = ui.font():get_width("*")
    local count = math.max(0, math.min(utf8.len(self.input.text), math.floor((x - text_x(self)) / width + 0.5)))
    return count == 0 and 0 or (utf8.offset(self.input.text, count + 1) or (#self.input.text + 1)) - 1
  end
  return self.input:offset_at(ui.font(), x - text_x(self))
end

function TextField:on_mouse_pressed(x, y, clicks)
  if not self.enabled then return false end
  if clicks and clicks >= 2 then
    self:select_all()
  else
    self.input:set_caret(self:offset_at(x))
    self.selecting = true
  end
  core.redraw = true
  return true
end

function TextField:on_mouse_moved(x)
  if not (self.selecting and self.pressed) then return false end
  self.input:set_caret(self:offset_at(x), true)
  core.redraw = true
  return true
end

function TextField:on_mouse_released()
  self.selecting = false
  return true
end

local function offset_x(field, font, pos)
  if field.secret then return font:get_width("*") * utf8.len(field.input.text:sub(1, pos)) end
  return font:get_width(field.input.text:sub(1, pos))
end

function TextField:draw(focused)
  local m = ui.metrics()
  local x, y, w, h, r = self.x, self.y, self.w, self.h, m.radius
  local font = ui.font()
  -- A focused field has an accent outline. A refused text has an error outline.
  local outline = self.error and style.error or (focused and style.accent)
  if outline then
    local border = math.max(1, math.floor(1.5 * SCALE + 0.5))
    renderer.draw_rounded_rect(x, y, w, h, r, outline)
    renderer.draw_rounded_rect(x + border, y + border, w - 2 * border, h - 2 * border, r - border, style.card)
  end
  if self.enabled then renderer.draw_rounded_rect(x, y, w, h, r, style.card_field) end
  local input = self.input
  local available = w - 2 * m.pad_x
  local ty = y + math.floor((h - font:get_height()) / 2)
  local caret_w = math.max(1, math.floor(1.5 * SCALE))
  -- The text scrolls as little as it can to keep the caret in view.
  local caret_x = offset_x(self, font, input.caret)
  local scroll = math.min(self.scroll, math.max(0, offset_x(self, font, #input.text) + caret_w - available))
  scroll = math.max(0, math.min(caret_x, math.max(scroll, caret_x + caret_w - available)))
  self.scroll = focused and scroll or 0
  local tx = x + m.pad_x - self.scroll
  core.push_clip_rect(x + m.pad_x, y, available, h)
  local first, last = input:selection()
  if focused and first ~= last then
    local left = offset_x(self, font, first)
    renderer.draw_rect(tx + left, ty, offset_x(self, font, last) - left, font:get_height(), style.selection)
  end
  if input.text == "" and self.placeholder then
    renderer.draw_text(font, self.placeholder, tx, ty, style.dim)
  end
  local shown = input.text
  if self.secret then
    local count = utf8.len(input.text)
    if count ~= self.mask_length then
      self.mask_length, self.mask_text = count, string.rep("*", count)
    end
    shown = self.mask_text
  end
  renderer.draw_text(font, shown, tx, ty, self.enabled and style.text or style.card_text)
  if focused then renderer.draw_rect(tx + caret_x, ty, caret_w, font:get_height(), style.accent) end
  core.pop_clip_rect()
end

return TextField
