local Object = require "core.object"
local style = require "core.style"

-- The shell owns identity and lifecycle. This view sends only Project actions.
local SidebarView = Object:extend()
function SidebarView:new(action)
  self.action, self.rows, self.scroll = action, {}, 0
end
function SidebarView:set_model(projects)
  self.rows = {}
  for _, project in ipairs(projects) do
    self.rows[#self.rows + 1] = {project = project}
    for _, terminal in ipairs(project.terminals or {}) do
      self.rows[#self.rows + 1] = {project = project, terminal = terminal}
    end
  end
end
function SidebarView:row_height() return style.font:get_height() * 3 end
function SidebarView:row_y(index) return 40 * SCALE + (index - 1) * self:row_height() - self.scroll + 1 end
function SidebarView:on_mouse_pressed(button, x, y)
  local index = math.floor((y - 40 * SCALE + self.scroll) / self:row_height()) + 1
  local row = y >= 40 * SCALE and self.rows[index]
  if not row or row.terminal then return end
  if button == "left" then self.action("select", row.project.row_id)
  elseif button == "right" and row.project.state ~= "dormant" then self.action("unload", row.project.row_id) end
end
function SidebarView:on_mouse_wheel(amount, height)
  self.scroll = math.max(0, math.min(self.scroll - amount * self:row_height(),
    math.max(0, #self.rows * self:row_height() - height + 40 * SCALE)))
end
function SidebarView:draw(width, height)
  renderer.set_clip_rect(0, 0, width, height)
  renderer.draw_rect(0, 0, width, height, style.background2)
  local h = style.font:get_height()
  for index, row in ipairs(self.rows) do
    local y = self:row_y(index)
    if y + self:row_height() > 40 * SCALE and y < height then
      local project, terminal = row.project, row.terminal
      if not terminal and project.selected then
        renderer.draw_rect(0, y, width, self:row_height(), style.selection)
      end
      local title = terminal and terminal.title or project.path:match("([^/\\]+)[/\\]*$") or project.path
      local state = terminal and terminal.state or project.state
      if terminal then
        state = state .. (terminal.busy == 1 and " / busy" or terminal.busy == 0 and " / idle" or " / unknown")
      else
        if project.close_choice then state = state .. " / Close choice" end
        if project.deferred_dialog then state = state .. " / dialog" end
        if not project.exists and project.state == "dormant" then state = state .. " / unavailable" end
      end
      local x = terminal and 20 * SCALE or 8 * SCALE
      renderer.draw_text(style.font, title, x, y, style.text)
      renderer.draw_text(style.font, state, x, y + h, style.dim)
      if terminal and terminal.cwd ~= "" then
        renderer.draw_text(style.font, terminal.cwd, x, y + 2 * h, style.dim)
      end
    end
  end
  renderer.set_clip_rect(0, 0, width, height)
end
return SidebarView
