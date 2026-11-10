local core = require "core"
local style = require "core.style"
local ui = require "core.ui"
local layout = require "core.ui.layout"
local Dialog = require("core.ui.dialog").Dialog
local Button = require "core.ui.button"
local updater = require "plugins.updater"
local releases = require "plugins.updater.release"

local UpdateDialog = Dialog:extend()

function UpdateDialog:new()
  UpdateDialog.super.new(self, { title = "Anvil Updates", width = 560 })
  self.check_button = Button({ label = "Check Again", on_click = function() updater.check() end })
  self.notes_button = Button({ label = "Release Notes", icon = ui.icons.open_in_new,
    on_click = function() system.open_in_system(updater.release and updater.release.page or releases.page) end })
  self.update_button = Button({ label = "Update and Restart", kind = "primary",
    on_click = function() updater.install() end })
  self.message_text = layout.Text {}
  self.body = layout.Column { self.message_text }
  self.footer = layout.Row {
    self.check_button, layout.Spacer { grow = 1 }, self.notes_button, self.update_button,
  }
  self:on_update()
end

function UpdateDialog:on_update()
  self.message = updater.message
  self.message_text:set_text(self.message)
  self.message_text.color = updater.state == "error" and style.dialog_danger or nil
  self.check_button.enabled = not updater.busy() and updater.supported()
  self.update_button.enabled = updater.state == "available" and updater.supported()
  self.update_button.visible = updater.release ~= nil
  self.notes_button.visible = updater.release ~= nil
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
