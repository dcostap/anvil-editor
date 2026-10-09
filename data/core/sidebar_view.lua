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
function SidebarView:list_top() return 40 * SCALE + style.font:get_height() + 16 * SCALE end
function SidebarView:row_y(index) return self:list_top() + (index - 1) * self:row_height() - self.scroll + 1 end
function SidebarView:on_mouse_pressed(button, x, y, width)
  if button ~= "left" then return end
  if y >= 40 * SCALE and y < self:list_top() then
    self.action("refresh")
    return
  end
  local index = math.floor((y - self:list_top() + self.scroll) / self:row_height()) + 1
  local row = y >= self:list_top() and self.rows[index]
  if not row or row.terminal then return end
  local unload_width = style.font:get_width("Unload") + 16 * SCALE
  if width and x >= width - unload_width and row.project.state ~= "dormant" then
    self.action("unload", row.project.row_id)
  else
    self.action("select", row.project.row_id)
  end
end
function SidebarView:on_mouse_wheel(amount, height)
  self.scroll = math.max(0, math.min(self.scroll - amount * self:row_height(),
    math.max(0, #self.rows * self:row_height() - height + self:list_top())))
end
function SidebarView:draw(width, height)
  renderer.set_clip_rect(0, 0, width, height)
  renderer.draw_rect(0, 0, width, height, style.background2)
  local h = style.font:get_height()
  for index, row in ipairs(self.rows) do
    local y = self:row_y(index)
    if y + self:row_height() > self:list_top() and y < height then
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
      local unload_width = not terminal and project.state ~= "dormant"
        and style.font:get_width("Unload") + 16 * SCALE or 0
      renderer.set_clip_rect(0, math.max(self:list_top(), y), width - unload_width, self:row_height())
      renderer.draw_text(style.font, title, x, y, style.text)
      renderer.draw_text(style.font, state, x, y + h, style.dim)
      if terminal and terminal.cwd ~= "" then
        renderer.draw_text(style.font, terminal.cwd, x, y + 2 * h, style.dim)
      end
      renderer.set_clip_rect(0, self:list_top(), width, math.max(0, height - self:list_top()))
      if unload_width > 0 then
        renderer.draw_rect(width - unload_width, y, unload_width, self:row_height(), style.background3)
        renderer.draw_text(style.font, "Unload", width - unload_width + 8 * SCALE, y + h, style.text)
      end
    end
  end
  renderer.set_clip_rect(0, 0, width, height)
  renderer.draw_rect(0, 40 * SCALE, width, self:list_top() - 40 * SCALE, style.background3)
  renderer.draw_text(style.font, "Refresh", 8 * SCALE, 48 * SCALE, style.text)
end
return SidebarView
