local Object = require "core.object"
local style = require "core.style"

-- The shell owns identity and lifecycle. This view sends only Project and Terminal Session actions.
-- Layout: the main list holds loaded Projects and Projects used in the last week. Older Projects sit in
-- collapsible age groups aligned to the bottom, which take at most part of the height and scroll on their own.
-- Inside a Project, older Terminal Sessions fold into collapsible groups the same way.
-- Rows keep the shell's order. Age only chooses a row's group, so rows never swap places under the pointer.
local SidebarView = Object:extend()

local DAY = 24 * 60 * 60
local WEEK, MONTH = 7 * DAY, 30 * DAY
-- The groups below the main list. Each starts collapsed unless saved otherwise.
local GROUPS = {
  {bucket = "month", label = "Last month", terminal_label = "Older than a week", collapsed = false},
  {bucket = "older", label = "Older", terminal_label = "Older than a month", collapsed = true},
}
-- The groups take at most this part of the height below the list top.
local GROUPS_HEIGHT = 0.4

---@param action fun(name: string, ...)
---@param collapsed table<string, boolean>? Saved collapse state, shared by every Sidebar surface.
function SidebarView:new(action, collapsed)
  self.action, self.rows, self.scroll, self.bottom_scroll = action, {}, 0, 0
  self.collapsed = collapsed or {}
  self.width, self.view_h = 240, 600
  self.main_h, self.bottom_h = 0, 0
end

function SidebarView:set_size(width, height)
  if self.width == width and self.view_h == height then return end
  self.width, self.view_h = width, height
  self:rebuild_rows()
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
    gap = 16 * SCALE,
    group = h + 12 * SCALE,
    project = h + 14 * SCALE,
    terminal = h + 8 * SCALE,
    unload = 26 * SCALE,
    indent = 14 * SCALE,
  }
end

-- "month" for 7 to 30 days, "older" beyond that or when unknown, nil when recent.
local function age_bucket(activity, now)
  if not activity or activity <= 0 then return "older" end
  local age = now - activity
  if age < WEEK then return nil end
  return age < MONTH and "month" or "older"
end

local function project_activity(project)
  local activity = project.activity or 0
  for _, terminal in ipairs(project.terminals or {}) do
    activity = math.max(activity, terminal.activity or 0)
  end
  return activity
end

function SidebarView:is_collapsed(key, default)
  local saved = self.collapsed[key]
  if saved == nil then return default end
  return saved
end

function SidebarView:toggle(key, default)
  local collapsed = not self:is_collapsed(key, default)
  self.collapsed[key] = collapsed
  self.action("collapsed", key, collapsed)
  self:rebuild_rows()
end

function SidebarView:rebuild_rows()
  local projects, window_id = self.projects or {}, self.window_id
  local m = metrics()
  local now = os.time()
  self.built_minute = math.floor(now / 60)
  local rows = {}
  local area
  local function add(row, height)
    row.h, row.area = height, area
    rows[#rows + 1] = row
  end
  local selected = 0
  for _, window in ipairs(projects.windows or {}) do
    if window.id == window_id then selected = window.selected_project end
  end
  local function add_terminal(project, terminal, depth, focused)
    add({kind = "terminal", project = project, terminal = terminal, depth = depth,
      selected = focused == terminal.id}, m.terminal)
  end
  local function add_project(project)
    local is_selected = window_id and selected ~= 0 and project.id == selected or not window_id and project.selected
    -- The Selected Project's focused Terminal Session takes the highlight. It always shows, even when old.
    local focused
    if is_selected and project.focused_terminal and project.focused_terminal ~= "" then
      for _, terminal in ipairs(project.terminals or {}) do
        if terminal.id == project.focused_terminal then focused = terminal.id end
      end
    end
    add({kind = "project", project = project, selected = is_selected and not focused}, m.project)
    if self.move_project == project.id then
      for _, window in ipairs(projects.windows or {}) do
        if window.id ~= project.window_id then
          add({kind = "move", project = project, move_target = window.id}, m.terminal)
        end
      end
    end
    -- Recent and ringing Terminal Sessions show directly, and so do those from hosts that do not report
    -- activity. Older ones fold into groups.
    local older = {}
    for _, terminal in ipairs(project.terminals or {}) do
      local bucket = (terminal.activity or 0) > 0 and age_bucket(terminal.activity, now)
      if bucket and not (terminal.bell and terminal.bell ~= 0) and terminal.id ~= focused then
        older[bucket] = older[bucket] or {}
        table.insert(older[bucket], terminal)
      else
        add_terminal(project, terminal, 1, focused)
      end
    end
    for _, group in ipairs(GROUPS) do
      local terminals = older[group.bucket]
      if terminals then
        local key = "terminals:" .. group.bucket .. ":" .. project.path
        local collapsed = self:is_collapsed(key, true)
        add({kind = "terminal_group", project = project, bucket = group.bucket, label = group.terminal_label,
          count = #terminals, key = key, collapsed = collapsed}, m.terminal)
        if not collapsed then
          for _, terminal in ipairs(terminals) do add_terminal(project, terminal, 2, focused) end
        end
      end
    end
  end
  area = "main"
  local grouped = {}
  for _, project in ipairs(projects) do
    local bucket = project.state == "dormant" and age_bucket(project_activity(project), now)
    if bucket then
      grouped[bucket] = grouped[bucket] or {}
      table.insert(grouped[bucket], project)
    else
      add_project(project)
    end
  end
  if #rows == 0 then
    add({kind = "empty", label = #projects > 0 and "No recent Projects" or "No Projects yet"}, m.project)
  end
  area = "bottom"
  for _, group in ipairs(GROUPS) do
    local members = grouped[group.bucket]
    if members then
      local key = "group:" .. group.bucket
      local collapsed = self:is_collapsed(key, group.collapsed)
      add({kind = "group", bucket = group.bucket, label = group.label, count = #members, key = key,
        collapsed = collapsed}, m.group)
      if not collapsed then
        for _, project in ipairs(members) do add_project(project) end
      end
    end
  end
  local main_y, bottom_y = 0, 0
  for _, row in ipairs(rows) do
    if row.area == "main" then
      row.y, main_y = main_y, main_y + row.h
    else
      row.y, bottom_y = bottom_y, bottom_y + row.h
    end
  end
  self.rows, self.main_h, self.bottom_h = rows, main_y, bottom_y
  self:clamp_scroll()
  if self.hover_y then self:update_hover() end
end

-- The groups' height on screen, and the top of the area that shows them.
function SidebarView:bottom_area()
  if self.bottom_h == 0 then return self.view_h, 0 end
  local m = metrics()
  local available = math.max(0, self.view_h - m.top)
  local height = math.min(self.bottom_h + m.pad, math.floor(available * GROUPS_HEIGHT))
  return self.view_h - height, height
end

function SidebarView:main_bottom()
  local bottom_top, bottom_height = self:bottom_area()
  return bottom_height > 0 and bottom_top - metrics().gap or self.view_h
end

function SidebarView:clamp_scroll()
  local m = metrics()
  local _, bottom_height = self:bottom_area()
  self.scroll = math.max(0, math.min(self.scroll, self.main_h - (self:main_bottom() - m.top)))
  self.bottom_scroll = math.max(0, math.min(self.bottom_scroll, self.bottom_h + m.pad - bottom_height))
end

function SidebarView:list_top() return metrics().top end

function SidebarView:row_y(index)
  local row = self.rows[index]
  if not row then return end
  if row.area == "bottom" then return self:bottom_area() + row.y - self.bottom_scroll end
  return self:list_top() + row.y - self.scroll
end

function SidebarView:row_at(y)
  local bottom_top = self:bottom_area()
  local area
  if y >= bottom_top then area = "bottom"
  elseif y >= self:list_top() and y < self:main_bottom() then area = "main"
  else return end
  for index, row in ipairs(self.rows) do
    if row.area == area then
      local row_y = self:row_y(index)
      if y >= row_y and y < row_y + row.h then return row, index end
    end
  end
end

local function in_unload(row, x, width)
  return width and row.kind == "project" and row.project.state ~= "dormant"
    and x >= width - metrics().pad - metrics().unload
end

function SidebarView:on_mouse_pressed(button, x, y, width)
  if button ~= "left" and button ~= "right" then return end
  local row = self:row_at(y)
  if not row then return end
  if row.kind == "group" or row.kind == "terminal_group" then
    if button == "left" then self:toggle(row.key, row.collapsed) end
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
  if row.kind == "terminal" then
    if button == "left" then self.action("select_terminal", row.project.row_id, row.terminal.id) end
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
  local hover = row and row.kind ~= "empty" and row or nil
  local unload = row and in_unload(row, self.hover_x, self.hover_width)
  local changed = hover ~= self.hover or unload ~= self.hover_unload
  self.hover, self.hover_unload = hover, unload
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

-- Scrolls the area under the pointer.
function SidebarView:on_mouse_wheel(amount, height, y)
  if height then self.view_h = height end
  local step = metrics().project
  if y and y >= self:bottom_area() then
    self.bottom_scroll = self.bottom_scroll - amount * step
  else
    self.scroll = self.scroll - amount * step
  end
  self:clamp_scroll()
  if self.hover_y then self:update_hover() end
end

-- Whether a minute passed since the last layout, so ages and groups need an update.
function SidebarView:refresh_ages()
  if math.floor(os.time() / 60) == self.built_minute then return false end
  self:rebuild_rows()
  return true
end

local function tint(color, alpha)
  return {color[1], color[2], color[3], alpha}
end

local function name_of(path)
  return path:match("([^/\\]+)[/\\]*$") or path
end

-- A short age such as "5m", "3h", "2d", "3w" or "4mo".
local function age_text(activity, now)
  if not activity or activity <= 0 then return nil end
  local age = math.max(0, now - activity)
  if age < 60 then return "now" end
  if age < 60 * 60 then return math.floor(age / 60) .. "m" end
  if age < DAY then return math.floor(age / (60 * 60)) .. "h" end
  if age < WEEK then return math.floor(age / DAY) .. "d" end
  if age < MONTH then return math.floor(age / WEEK) .. "w" end
  if age < 365 * DAY then return math.floor(age / MONTH) .. "mo" end
  return math.floor(age / (365 * DAY)) .. "y"
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

-- A small triangle pointing right, or down when open.
local function chevron(x, cy, open, color)
  local size = math.max(3, math.floor(4 * SCALE))
  local unit = math.max(1, math.floor(SCALE))
  for i = 0, size - 1 do
    local length = (size - i) * 2 - 1
    if open then
      renderer.draw_rect(x + i * unit, cy - size * unit / 2 + i * unit, length * unit, unit, color)
    else
      renderer.draw_rect(x + i * unit, cy - (length * unit) / 2, unit, length * unit, color)
    end
  end
end

-- Draws text left-aligned in [x, right), clipped by the caller's clip rect.
local function text(label, x, y, color)
  renderer.draw_text(style.font, label, x, y, color)
end

-- Shortens a label with an ellipsis until it fits in `width`.
local function fit(label, width)
  if style.font:get_width(label) <= width then return label end
  local ellipsis = "\u{2026}"
  while label ~= "" and style.font:get_width(label .. ellipsis) > width do
    label = label:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
  end
  return label .. ellipsis
end

-- Draws a label shortened before a right-aligned note, then the note.
function SidebarView:label_with_note(label, color, note, x, y, row, right)
  local ty = y + (row.h - style.font:get_height()) / 2
  local note_w = note and style.font:get_width(note) + 8 * SCALE or 0
  if note_w > (right - x) / 2 then note, note_w = nil, 0 end
  text(fit(label, math.max(0, right - x - note_w)), x, ty, color)
  if note then text(note, right - note_w + 8 * SCALE, ty, style.dim) end
end

function SidebarView:draw_row(row, y, width, now)
  local m = metrics()
  local cy = y + row.h / 2
  local left, right = m.pad, width - m.pad
  if row.kind == "empty" then
    self:label_with_note(row.label, style.dim, nil, left + 8 * SCALE, y, row, right)
    return
  end
  local radius = 6 * SCALE
  if row.selected then
    renderer.draw_rounded_rect(left, y + 1, right - left, row.h - 2, radius, style.selection)
  elseif self.hover == row then
    renderer.draw_rounded_rect(left, y + 1, right - left, row.h - 2, radius, tint(style.text, 22))
  end
  if row.kind == "group" then
    chevron(left + 8 * SCALE, cy, not row.collapsed, style.dim)
    self:label_with_note(row.label, self.hover == row and style.text or style.dim, tostring(row.count),
      left + 22 * SCALE, y, row, right)
    return
  end
  if row.kind == "terminal_group" then
    local x = left + 22 * SCALE + m.indent
    chevron(x - 12 * SCALE, cy, not row.collapsed, style.dim)
    self:label_with_note(row.label, self.hover == row and style.text or style.dim, tostring(row.count),
      x, y, row, right)
    return
  end
  if row.kind == "move" then
    text("Move to Window " .. row.move_target, left + 30 * SCALE, y + (row.h - style.font:get_height()) / 2,
      style.accent)
    return
  end
  if row.kind == "terminal" then
    local terminal = row.terminal
    local color, note = terminal_status(terminal)
    local x = left + 22 * SCALE + row.depth * m.indent
    dot(x - 8 * SCALE, cy, 3 * SCALE, color)
    self:label_with_note(terminal.title ~= "" and terminal.title or "Terminal",
      terminal.state == "running" and style.text or style.dim, note or age_text(terminal.activity, now),
      x, y, row, right)
    return
  end
  local project = row.project
  local color, note = project_status(project)
  dot(left + 12 * SCALE, cy, 4 * SCALE, color)
  local x = left + 24 * SCALE
  if not note and project.window_id and project.window_id ~= 0 and self.window_id
    and project.window_id ~= self.window_id then
    note = "Window " .. project.window_id
  end
  if not note and project.state == "dormant" then note = age_text(project_activity(project), now) end
  local unload = project.state ~= "dormant" and self.hover == row
  local dim_name = project.state == "dormant" and not project.exists
  self:label_with_note(name_of(project.path), dim_name and style.dim or style.text,
    not unload and note or nil, x, y, row, unload and right - m.unload or right)
  if unload then
    local bx = right - m.unload
    local ty = y + (row.h - style.font:get_height()) / 2
    if self.hover_unload then
      renderer.draw_rounded_rect(bx + 2 * SCALE, y + 4 * SCALE, m.unload - 4 * SCALE, row.h - 8 * SCALE, 4 * SCALE,
        tint(style.text, 36))
    end
    local glyph = "\u{00D7}"
    text(glyph, bx + (m.unload - style.font:get_width(glyph)) / 2, ty,
      self.hover_unload and style.text or style.dim)
  end
end

function SidebarView:draw(width, height)
  if width ~= self.width or height ~= self.view_h then self:set_size(width, height) end
  local now = os.time()
  renderer.set_clip_rect(0, 0, width, height)
  -- On a transparent surface the shell blends the panel over the Project's backdrop and wallpaper.
  renderer.draw_rect(0, 0, width, height,
    system.is_surface_transparent() and style.wallpaper_surface(style.background2) or style.background2)
  renderer.draw_rect(width - math.max(1, SCALE), 0, math.max(1, SCALE), height, style.divider)
  local top, main_bottom = self:list_top(), self:main_bottom()
  local bottom_top, bottom_height = self:bottom_area()
  if bottom_height > 0 then
    local m = metrics()
    renderer.draw_rect(m.pad + 8 * SCALE, bottom_top - math.floor(m.gap / 2), width - 2 * m.pad - 16 * SCALE,
      math.max(1, math.floor(SCALE)), style.divider)
  end
  for _, area in ipairs({{"main", top, main_bottom}, {"bottom", bottom_top, height}}) do
    renderer.set_clip_rect(0, area[2], width, math.max(0, area[3] - area[2]))
    for index, row in ipairs(self.rows) do
      if row.area == area[1] then
        local y = self:row_y(index)
        if y + row.h > area[2] and y < area[3] then self:draw_row(row, y, width, now) end
      end
    end
  end
  renderer.set_clip_rect(0, 0, width, height)
end

return SidebarView
