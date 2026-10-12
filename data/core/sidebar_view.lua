local Object = require "core.object"
local style = require "core.style"

-- The shell owns identity and lifecycle. This view sends only Project actions.
local SidebarView = Object:extend()
function SidebarView:new(action)
  self.action, self.rows, self.scroll = action, {}, 0
end
function SidebarView:set_model(projects, window_id)
  -- Revisions arrive for unrelated changes, such as Terminal state. Keep open Move choices while still valid.
  local move_project = nil
  for _, project in ipairs(projects) do
    if project.id == self.move_project and project.window_id == self.move_owner and project.state ~= "dormant" then
      move_project = project.id
    end
  end
  self.projects, self.window_id, self.move_project = projects, window_id, move_project
  self:rebuild_rows()
end
function SidebarView:rebuild_rows()
  local projects, window_id = self.projects, self.window_id
  self.rows = {}
  local selected = 0
  for _, window in ipairs(projects.windows or {}) do
    if window.id == window_id then selected = window.selected_project end
  end
  for _, project in ipairs(projects) do
    self.rows[#self.rows + 1] = {project = project, selected = window_id and selected ~= 0 and project.id == selected
      or not window_id and project.selected}
    for _, terminal in ipairs(project.terminals or {}) do
      self.rows[#self.rows + 1] = {project = project, terminal = terminal}
    end
    if self.move_project == project.id then
      for _, window in ipairs(projects.windows or {}) do
        if window.id ~= project.window_id then
          self.rows[#self.rows + 1] = {project = project, move_target = window.id}
        end
      end
    end
  end
end
function SidebarView:row_height() return style.font:get_height() * 3 end
function SidebarView:list_top() return 40 * SCALE + style.font:get_height() + 16 * SCALE end
function SidebarView:row_y(index) return self:list_top() + (index - 1) * self:row_height() - self.scroll + 1 end
function SidebarView:on_mouse_pressed(button, x, y, width)
  if button ~= "left" and button ~= "right" then return end
  if y >= 40 * SCALE and y < self:list_top() then
    if button == "left" then self.action("refresh") end
    return
  end
  local index = math.floor((y - self:list_top() + self.scroll) / self:row_height()) + 1
  local row = y >= self:list_top() and self.rows[index]
  if not row or row.terminal then return end
  if button == "right" then
    if row.project.id and row.project.window_id and row.project.window_id ~= 0 then
      self.move_project = self.move_project ~= row.project.id and row.project.id or nil
      self.move_owner = row.project.window_id
      self:rebuild_rows()
    end
    return
  end
  if row.move_target then
    self.action("move", row.project.id, row.move_target)
    self.move_project = nil
    self:rebuild_rows()
    return
  end
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
  -- On a transparent surface the shell blends the panel over the Project's backdrop and wallpaper.
  renderer.draw_rect(0, 0, width, height,
    system.is_surface_transparent() and style.wallpaper_surface(style.background2) or style.background2)
  local h = style.font:get_height()
  for index, row in ipairs(self.rows) do
    local y = self:row_y(index)
    if y + self:row_height() > self:list_top() and y < height then
      local project, terminal = row.project, row.terminal
      if not terminal and not row.move_target and row.selected then
        renderer.draw_rect(0, y, width, self:row_height(), style.selection)
      end
      local title = terminal and terminal.title or project.path:match("([^/\\]+)[/\\]*$") or project.path
      local state = terminal and terminal.state or project.state
      if row.move_target then title, state = "Move to Window " .. row.move_target, "Select this target to move the Project" end
      if terminal then
        state = state .. (terminal.busy == 1 and " / busy" or terminal.busy == 0 and " / idle" or " / unknown")
      else
        if project.window_id and project.window_id ~= 0 then state = state .. " / Window " .. project.window_id end
        if project.close_choice then state = state .. " / Close choice" end
        if project.deferred_dialog then state = state .. " / dialog" end
        if not project.exists and project.state == "dormant" then state = state .. " / unavailable" end
      end
      local x = terminal and 20 * SCALE or 8 * SCALE
      local unload_width = not terminal and not row.move_target and project.state ~= "dormant"
        and style.font:get_width("Unload") + 16 * SCALE or 0
      renderer.set_clip_rect(0, math.max(self:list_top(), y), width - unload_width, self:row_height())
      renderer.draw_text(style.font, title, x, y, style.text)
      renderer.draw_text(style.font, state, x, y + h, style.dim)
      if not terminal and not row.move_target and project.window_id and project.window_id ~= 0 then
        renderer.draw_text(style.font, "Right-click for Move", x, y + 2 * h, style.dim)
      end
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
