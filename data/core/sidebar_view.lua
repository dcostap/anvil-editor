local Object = require "core.object"
local style = require "core.style"

-- The shell owns identity and lifecycle. This view sends only Project actions.
-- Layout: a PROJECTS header with Refresh, the loaded Projects with their Terminal Sessions, then RECENT
-- Dormant Projects, collapsed behind "Show more" when the list is long.
local SidebarView = Object:extend()

local RECENT_COLLAPSED = 8

function SidebarView:new(action)
  self.action, self.rows, self.scroll = action, {}, 0
  self.content_h = 0
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

local function metrics()
  local h = style.font:get_height()
  return {
    top = 40 * SCALE,
    pad = 8 * SCALE,
    header = h + 18 * SCALE,
    project = h + 14 * SCALE,
    terminal = h + 8 * SCALE,
    unload = 26 * SCALE,
  }
end

function SidebarView:rebuild_rows()
  local projects, window_id = self.projects or {}, self.window_id
  local m = metrics()
  local rows = {}
  local function add(row, height)
    row.h = height
    rows[#rows + 1] = row
  end
  local selected = 0
  for _, window in ipairs(projects.windows or {}) do
    if window.id == window_id then selected = window.selected_project end
  end
  local function add_project(project)
    add({kind = "project", project = project, selected = window_id and selected ~= 0 and project.id == selected
      or not window_id and project.selected}, m.project)
    for _, terminal in ipairs(project.terminals or {}) do
      add({kind = "terminal", project = project, terminal = terminal}, m.terminal)
    end
    if self.move_project == project.id then
      for _, window in ipairs(projects.windows or {}) do
        if window.id ~= project.window_id then
          add({kind = "move", project = project, move_target = window.id}, m.terminal)
        end
      end
    end
  end
  add({kind = "header", label = "PROJECTS", refresh = true}, m.header)
  local recent = {}
  for _, project in ipairs(projects) do
    if project.state == "dormant" then recent[#recent + 1] = project else add_project(project) end
  end
  if #rows == 1 then add({kind = "empty", label = #recent > 0 and "No open Projects" or "No Projects yet"}, m.project) end
  if #recent > 0 then
    add({kind = "header", label = "RECENT"}, m.header)
    local shown = self.show_all_recent and #recent or math.min(#recent, RECENT_COLLAPSED)
    for i = 1, shown do add_project(recent[i]) end
    if #recent > RECENT_COLLAPSED then
      add({kind = "more", hidden = #recent - shown}, m.terminal)
    end
  end
  local y = 0
  for _, row in ipairs(rows) do
    row.y = y
    y = y + row.h
  end
  self.rows, self.content_h = rows, y
  if self.hover_y then self:update_hover() end
end

function SidebarView:list_top() return metrics().top end
function SidebarView:row_y(index)
  local row = self.rows[index]
  return row and self:list_top() + row.y - self.scroll
end

function SidebarView:row_at(y)
  local content_y = y - self:list_top() + self.scroll
  if y < self:list_top() then return end
  for index, row in ipairs(self.rows) do
    if content_y >= row.y and content_y < row.y + row.h then return row, index end
  end
end

local function refresh_width()
  return style.font:get_width("Refresh") + 16 * SCALE
end

local function in_unload(row, x, width)
  return width and row.kind == "project" and row.project.state ~= "dormant"
    and x >= width - metrics().pad - metrics().unload
end

function SidebarView:on_mouse_pressed(button, x, y, width)
  if button ~= "left" and button ~= "right" then return end
  local row = self:row_at(y)
  if not row then return end
  if row.kind == "header" then
    if button == "left" and row.refresh and (not width or x >= width - refresh_width()) then
      self.action("refresh")
    end
    return
  end
  if row.kind == "more" then
    if button == "left" then
      self.show_all_recent = not self.show_all_recent
      self:rebuild_rows()
    end
    return
  end
  if row.kind == "move" then
    if button == "left" then
      self.action("move", row.project.id, row.move_target)
      self.move_project = nil
      self:rebuild_rows()
    end
    return
  end
  if row.kind ~= "project" then return end
  if button == "right" then
    if row.project.id and row.project.window_id and row.project.window_id ~= 0 then
      self.move_project = self.move_project ~= row.project.id and row.project.id or nil
      self.move_owner = row.project.window_id
      self:rebuild_rows()
    end
    return
  end
  if in_unload(row, x, width) then
    self.action("unload", row.project.row_id)
  else
    self.action("select", row.project.row_id)
  end
end

function SidebarView:update_hover()
  local row = self.hover_y and self:row_at(self.hover_y)
  local hover = row and row.kind ~= "header" and row.kind ~= "empty" and row or nil
  local refresh = row and row.refresh and self.hover_x >= (self.hover_width or 0) - refresh_width()
  local unload = row and in_unload(row, self.hover_x, self.hover_width)
  local changed = hover ~= self.hover or refresh ~= self.hover_refresh or unload ~= self.hover_unload
  self.hover, self.hover_refresh, self.hover_unload = hover, refresh, unload
  return changed
end

-- Returns true when the hover changed and the view needs a redraw.
function SidebarView:on_mouse_moved(x, y, width)
  self.hover_x, self.hover_y, self.hover_width = x, y, width
  return self:update_hover()
end

function SidebarView:on_mouse_left()
  self.hover_x, self.hover_y = nil, nil
  return self:update_hover()
end

function SidebarView:on_mouse_wheel(amount, height)
  local step = metrics().project
  self.scroll = math.max(0, math.min(self.scroll - amount * step,
    math.max(0, self.content_h - height + self:list_top())))
  if self.hover_y then self:update_hover() end
end

local function tint(color, alpha)
  return {color[1], color[2], color[3], alpha}
end

local function name_of(path)
  return path:match("([^/\\]+)[/\\]*$") or path
end

local function project_status(project)
  if project.state == "failed" then return style.error, "failed" end
  if project.state == "dormant" then
    if not project.exists then return style.error, "unavailable" end
    return tint(style.dim, 160)
  end
  if project.close_choice or project.deferred_dialog then return style.warn, "needs answer" end
  if project.state == "starting" then return style.warn, "starting" end
  if project.state == "closing" then return style.warn, "closing" end
  return style.good
end

local function terminal_status(terminal)
  if terminal.state ~= "running" then return tint(style.dim, 120), terminal.state end
  if terminal.bell and terminal.bell ~= 0 then return style.warn end
  if terminal.busy == 1 then return style.accent end
  if terminal.busy == 0 then return style.good end
  return style.dim
end

local function dot(x, cy, radius, color)
  renderer.draw_rounded_rect(x - radius, cy - radius, radius * 2, radius * 2, radius, color)
end

-- Draws text left-aligned in [x, right), clipped by the caller's clip rect.
local function text(label, x, y, color)
  renderer.draw_text(style.font, label, x, y, color)
end

function SidebarView:draw_row(row, y, width)
  local m = metrics()
  local fh = style.font:get_height()
  local ty = y + (row.h - fh) / 2
  local cy = y + row.h / 2
  local left, right = m.pad, width - m.pad
  if row.kind == "header" then
    text(row.label, left + 8 * SCALE, ty + 3 * SCALE, style.dim)
    if row.refresh then
      local rw = refresh_width()
      text("Refresh", width - rw + 4 * SCALE, ty + 3 * SCALE, self.hover_refresh and style.text or style.dim)
    end
    return
  end
  if row.kind == "empty" then
    text(row.label, left + 8 * SCALE, ty, style.dim)
    return
  end
  local radius = 6 * SCALE
  if row.selected then
    renderer.draw_rounded_rect(left, y + 1, right - left, row.h - 2, radius, style.selection)
  elseif self.hover == row then
    renderer.draw_rounded_rect(left, y + 1, right - left, row.h - 2, radius, tint(style.text, 22))
  end
  if row.kind == "more" then
    local label = self.show_all_recent and "Show less" or ("Show " .. row.hidden .. " more")
    text(label, left + 22 * SCALE, ty, self.hover == row and style.text or style.dim)
    return
  end
  if row.kind == "move" then
    text("Move to Window " .. row.move_target, left + 30 * SCALE, ty, style.accent)
    return
  end
  if row.kind == "terminal" then
    local terminal = row.terminal
    local color, note = terminal_status(terminal)
    dot(left + 26 * SCALE, cy, 3 * SCALE, color)
    local x = left + 36 * SCALE
    local meta = note or (terminal.cwd ~= "" and name_of(terminal.cwd)) or ""
    local meta_w = meta ~= "" and style.font:get_width(meta) + 8 * SCALE or 0
    if meta_w > (right - x) / 2 then meta, meta_w = "", 0 end
    renderer.set_clip_rect(x, y, math.max(0, right - x - meta_w - 4 * SCALE), row.h)
    text(terminal.title ~= "" and terminal.title or "Terminal", x, ty,
      terminal.state == "running" and style.text or style.dim)
    renderer.set_clip_rect(0, self:list_top(), width, self.view_h - self:list_top())
    if meta ~= "" then text(meta, right - meta_w, ty, style.dim) end
    return
  end
  local project = row.project
  local color, note = project_status(project)
  dot(left + 12 * SCALE, cy, 4 * SCALE, color)
  local x = left + 24 * SCALE
  local meta = note
  if not meta and project.window_id and project.window_id ~= 0 and self.window_id
    and project.window_id ~= self.window_id then
    meta = "Window " .. project.window_id
  end
  local unload = project.state ~= "dormant" and (self.hover == row)
  local meta_w = meta and style.font:get_width(meta) + 8 * SCALE or 0
  local reserved = unload and m.unload or meta_w
  renderer.set_clip_rect(x, y, math.max(0, right - x - reserved - 4 * SCALE), row.h)
  local dim_name = project.state == "dormant" and not project.exists
  text(name_of(project.path), x, ty, dim_name and style.dim or style.text)
  renderer.set_clip_rect(0, self:list_top(), width, self.view_h - self:list_top())
  if unload then
    local bx = right - m.unload
    if self.hover_unload then
      renderer.draw_rounded_rect(bx + 2 * SCALE, y + 4 * SCALE, m.unload - 4 * SCALE, row.h - 8 * SCALE, 4 * SCALE,
        tint(style.text, 36))
    end
    local glyph = "\u{00D7}"
    text(glyph, bx + (m.unload - style.font:get_width(glyph)) / 2, ty,
      self.hover_unload and style.text or style.dim)
  elseif meta then
    text(meta, right - meta_w, ty, style.dim)
  end
end

function SidebarView:draw(width, height)
  self.view_h = height
  renderer.set_clip_rect(0, 0, width, height)
  -- On a transparent surface the shell blends the panel over the Project's backdrop and wallpaper.
  renderer.draw_rect(0, 0, width, height,
    system.is_surface_transparent() and style.wallpaper_surface(style.background2) or style.background2)
  renderer.draw_rect(width - math.max(1, SCALE), 0, math.max(1, SCALE), height, style.divider)
  local top = self:list_top()
  renderer.set_clip_rect(0, top, width, math.max(0, height - top))
  for index, row in ipairs(self.rows) do
    local y = self:row_y(index)
    if y + row.h > top and y < height then self:draw_row(row, y, width) end
  end
  renderer.set_clip_rect(0, 0, width, height)
end

return SidebarView
