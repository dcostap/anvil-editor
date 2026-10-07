-- mod-version:3
local core = require "core"
local command = require "core.command"
local ime = require "core.ime"
local keymap = require "core.keymap"
local style = require "core.style"
local Dialog = require "widget.dialog"
local Button = require "widget.button"
local Label = require "widget.label"
local ListBox = require "widget.listbox"

local checker
local EVENT_LIMIT = 200
local KeyboardInputChecker = Dialog:extend()

local function value_text(value)
  if type(value) == "string" then
    return string.format("%q", value):gsub("\\\n", "\\n"):gsub("\r", "\\r")
  end
  return tostring(value)
end

function KeyboardInputChecker:new()
  KeyboardInputChecker.super.new(self, "Keyboard Input Checker GUI")
  self.type_name = "plugins.keyboard_input_checker"
  self.size.mx, self.size.my = 0, 0
  self.panel.scrollable = false
  self.help = Label(self.panel,
    "OS: " .. PLATFORM .. ". Raw native scancode and SDL key data appear below.\n"
    .. "All received keys stay here, including Escape. Click the dialog's X to close.\n"
    .. "The OS can reserve combinations. Copy includes the latest 200 events.")
  self.events = ListBox(self.panel)
  self.events.font = "code_font"
  self.clear_button = Button(self.panel, "Clear")
  self.copy_button = Button(self.panel, "Copy")
  local view = self
  function self.clear_button:on_click() view:clear() end
  function self.copy_button:on_click() system.set_clipboard(view:get_log_text()) end
end

function KeyboardInputChecker:supports_text_input()
  return true
end

function KeyboardInputChecker:show()
  if self:is_visible() then return end
  self.previous_view = core.active_view
  self.input_root = core.root_panel
  ime.stop()
  keymap.clear_modkeys()
  KeyboardInputChecker.super.show(self)
  self.input_root:push_modal_input(self, { label = "keyboard input checker" })
  core.set_active_view(self)
  core.log_quiet("Keyboard input checker: opened; capture native scancodes, SDL keys, text, and composition")
end

function KeyboardInputChecker:hide()
  if not self:is_visible() then return end
  self.input_root:pop_modal_input(self)
  ime.stop()
  keymap.clear_modkeys()
  KeyboardInputChecker.super.hide(self)
  core.set_active_view(self.previous_view)
  self.previous_view = nil
  core.redraw = true
  core.log_quiet("Keyboard input checker: closed; restored editor input")
end

function KeyboardInputChecker:clear()
  self.events:clear()
  self.events.scroll.x, self.events.scroll.y = 0, 0
  self.events.scroll.to.x, self.events.scroll.to.y = 0, 0
  core.redraw = true
end

function KeyboardInputChecker:get_log_text()
  local lines = {}
  for index = 1, #self.events.rows do
    lines[#lines + 1] = self.events:get_row_text(index)
  end
  return table.concat(lines, "\n")
end

function KeyboardInputChecker:on_raw_keyboard_event(kind, key, event, length)
  local text
  if kind == "textinput" then
    text = kind .. " text=" .. value_text(key)
  elseif kind == "textediting" then
    text = string.format("%s text=%s start=%s length=%s", kind,
      value_text(key), tostring(event), tostring(length))
  else
    local modifiers = {}
    for _, name in ipairs { "ctrl", "shift", "alt", "super", "altgr" } do
      if event and event[name] then modifiers[#modifiers + 1] = name end
    end
    text = kind .. " key=" .. value_text(key)
      .. " held=" .. (#modifiers > 0 and table.concat(modifiers, "+") or "none")
    local fields = {}
    for name in pairs(event or {}) do fields[#fields + 1] = name end
    table.sort(fields)
    for index, name in ipairs(fields) do
      text = text .. (index % 4 == 1 and "\n  " or "  ")
        .. name .. "=" .. value_text(event[name])
    end
  end
  self:append_event(text)
end

function KeyboardInputChecker:on_window_close()
  -- SDL can send this request with Alt+F4, even when its key event is captured.
  self:append_event("windowclose (blocked; click X to close the checker)")
  core.log_quiet("Keyboard input checker: blocked native window close request")
  return true
end

function KeyboardInputChecker:append_event(text)
  if #self.events.rows >= EVENT_LIMIT then self.events:remove_row(1) end
  self.events:add_row({ text })
  self.events.scroll.to.y = math.max(0, self.events:get_scrollable_size() - self.events.size.y)
  self.events.scroll.y = self.events.scroll.to.y
  self.events:set_visible_rows()
  core.redraw = true
end

function KeyboardInputChecker:update_size_position()
  local padding = style.padding
  self:set_size(math.max(1, math.min(1050 * SCALE, core.root_panel.size.x - padding.x * 2)),
    math.max(1, math.min(620 * SCALE, core.root_panel.size.y - padding.y * 2)))
  KeyboardInputChecker.super.update_size_position(self)
  local width = math.max(1, self.panel.size.x - padding.x * 2)
  local help_height = self.help:get_font():get_height() * 3
  self.help:set_position(padding.x, padding.y)
  self.help:set_size(width, help_height)
  self.clear_button:set_position(padding.x,
    self.panel.size.y - self.clear_button.size.y - padding.y)
  self.copy_button:set_position(self.clear_button:get_right() + padding.x,
    self.clear_button:get_position().y)
  self.events:set_position(padding.x, help_height + padding.y * 2)
  self.events:set_size(width,
    math.max(1, self.clear_button:get_position().y - self.events:get_position().y - padding.y))
end

command.add(nil, {
  ["core:keyboard_input_checker_gui"] = command.palette(function()
    if not checker then checker = KeyboardInputChecker() end
    checker:show()
  end, { keywords = { "keyboard input checker GUI", "raw keys", "scancode", "diagnostics" } }),
})
