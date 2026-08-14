local core = require "core"
local command = require "core.command"
local Object = require "core.object"
local style = require "core.style"

local PaneCommandBar = Object:extend()

local function panes()
  return core.panes or require "core.panes"
end

local function contains(rect, x, y)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end

function PaneCommandBar:new(pane)
  self.pane = assert(pane)
  self.position = { x = 0, y = 0 }
  self.size = { x = 0, y = 0 }
  self.hovered_action = nil
  self.actions = {}
end

function PaneCommandBar:get_height()
  return math.floor(style.font:get_height() + style.padding.y * 2)
end

local function view_actions(view)
  local actions = view and view.get_pane_actions and view:get_pane_actions()
  if type(actions) ~= "table" then return {} end
  return actions
end

function PaneCommandBar:update_actions()
  local result = {}
  for _, action in ipairs(view_actions(self.pane.current_view)) do
    if type(action) == "table" and action.label then result[#result + 1] = action end
  end
  result[#result + 1] = {
    id = "close-pane",
    label = "×",
    action = function() panes().close(self.pane) end,
  }

  local right = self.position.x + self.size.x
  for i = #result, 1, -1 do
    local action = result[i]
    local width = math.max(24 * SCALE, style.font:get_width(action.label) + style.padding.x * 2)
    right = right - width
    action.x, action.y, action.w, action.h = right, self.position.y, width, self.size.y
  end
  self.actions = result
end

function PaneCommandBar:update_rect(rect)
  local height = math.min(self:get_height(), math.max(0, rect.h))
  self.position.x, self.position.y = rect.x, rect.y
  self.size.x, self.size.y = rect.w, height
  self:update_actions()
  local view = self.pane.current_view
  if view then
    view.position.x = rect.x
    view.position.y = rect.y + height
    view.size.x = rect.w
    view.size.y = math.max(0, rect.h - height)
  end
end

function PaneCommandBar:get_model()
  local number = panes().number(self.pane) or "?"
  local view = self.pane.current_view
  local name = view and view.get_name and view:get_name() or "View"
  return {
    pane = self.pane,
    title = string.format("%s %s", number, name),
    actions = self.actions,
  }
end

function PaneCommandBar:action_at(x, y)
  for i, action in ipairs(self.actions) do
    if contains(action, x, y) then return action, i end
  end
end

function PaneCommandBar:on_mouse_moved(x, y)
  local _, index = self:action_at(x, y)
  if index ~= self.hovered_action then
    self.hovered_action = index
    core.redraw = true
  end
  return index ~= nil
end

function PaneCommandBar:on_mouse_left()
  self.hovered_action = nil
  core.redraw = true
end

function PaneCommandBar:on_mouse_pressed(button, x, y)
  if button ~= "left" then return false end
  local action = self:action_at(x, y)
  if not action then
    panes().focus(self.pane)
    return true
  end
  panes().focus(self.pane)
  if action.action then
    action.action(self.pane.current_view, self.pane)
  elseif action.command then
    command.perform(action.command, self.pane.current_view, self.pane)
  end
  return true
end

function PaneCommandBar:draw()
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y,
    style.pane_command_bar)
  local model = self:get_model()
  local y = self.position.y + math.floor((self.size.y - style.font:get_height()) / 2)
  renderer.draw_text(style.font, model.title, self.position.x + style.padding.x, y,
    panes().active() == self.pane and style.pane_command_bar_text or style.pane_command_bar_dim)
  for i, action in ipairs(self.actions) do
    if self.hovered_action == i then
      renderer.draw_rect(action.x, action.y, action.w, action.h, style.pane_command_bar_hover)
    end
    local x = action.x + math.floor((action.w - style.font:get_width(action.label)) / 2)
    renderer.draw_text(style.font, action.label, x, y, style.pane_command_bar_text)
  end
end

return PaneCommandBar
