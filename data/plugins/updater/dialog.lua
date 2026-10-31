local core = require "core"
local common = require "core.common"
local style = require "core.style"
local ui = require "core.ui"
local Dialog = require("core.ui.dialog").Dialog
local Button = require "core.ui.button"
local updater = require "plugins.updater"
local releases = require "plugins.updater.release"

local UpdateDialog = Dialog:extend()

function UpdateDialog:new()
  UpdateDialog.super.new(self, { title = "Anvil Updates", width = 560 })
  self.check_button = self:add(Button({ label = "Check Again", on_click = function() updater.check() end }))
  self.notes_button = self:add(Button({ label = "Release Notes", icon = ui.icons.open_in_new,
    on_click = function() system.open_in_system(updater.release and updater.release.page or releases.page) end }))
  self.update_button = self:add(Button({ label = "Update and Restart", kind = "primary",
    on_click = function() updater.install() end }))
  self:on_update()
end

function UpdateDialog:on_update()
  self.message = updater.message
  self.check_button.enabled = not updater.busy() and updater.supported()
  self.update_button.enabled = updater.state == "available" and updater.supported()
  self.update_button.visible = updater.release ~= nil
  self.notes_button.visible = updater.release ~= nil
end

function UpdateDialog:layout_content(x, y, w, max_h)
  local m = ui.metrics()
  local font = ui.font()
  -- Wrap only when the status, font or width changes, not during each draw.
  if self.wrap_message ~= self.message or self.wrap_w ~= w or self.wrap_font ~= font then
    self.wrap_message, self.wrap_w, self.wrap_font = self.message, w, font
    self.lines = {}
    local line = ""
    for word in self.message:gmatch("%S+") do
      local next_line = line == "" and word or line .. " " .. word
      if line ~= "" and font:get_width(next_line) > w then
        self.lines[#self.lines + 1] = line
        line = word
      else line = next_line end
    end
    self.lines[#self.lines + 1] = line
  end
  self.content_x, self.content_y, self.content_w = x, y, w
  local cy = y + #self.lines * font:get_height() + math.floor(24 * SCALE)
  local right = x + w
  self.check_button:set_rect(x, cy, self.check_button:measure(), m.control_h)
  if self.update_button.visible then
    local width = self.update_button:measure()
    self.update_button:set_rect(right - width, cy, width, m.control_h)
    right = right - width - m.gap
    width = self.notes_button:measure()
    self.notes_button:set_rect(right - width, cy, width, m.control_h)
  end
  return cy + m.control_h - y
end

function UpdateDialog:draw_content()
  local font = ui.font()
  for i, line in ipairs(self.lines) do
    common.draw_text(font, updater.state == "error" and style.error or style.text,
      ui.fit_text(font, line, self.content_w), "left", self.content_x,
      self.content_y + (i - 1) * font:get_height(), self.content_w, font:get_height())
  end
  UpdateDialog.super.draw_content(self)
end

local M = { Dialog = UpdateDialog }
function M.open()
  local current = require("core.ui.dialog").current()
  local instance = current and current:is(UpdateDialog) and current or UpdateDialog()
  instance:on_update()
  instance:open(instance.update_button.enabled and instance.update_button or instance.check_button)
  core.redraw = true
  return instance
end
return M
