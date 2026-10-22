local Object = require "core.object"
local style = require "core.style"
local tab = require "core.tab"

-- The shell owns identity and lifecycle. This view sends only Project, Pane and Terminal Session actions. A
-- right-click on a Project asks the shell for its native actions menu: Move, Unload and the rest.
-- The menu opens at the button's release. A menu opened at the press takes the release into its own loop, and the
-- shell then reports a stray left press that selects the Project.
-- Layout: the main list holds loaded Projects with their Tabs, one for each Pane, and the Terminal Sessions that
-- no Pane shows. Unloaded Projects sit in collapsible age groups aligned to the bottom, which take at most part of
-- the height and scroll on their own. Their rows count their running Terminal Sessions.
-- Each area that overflows shows a scrollbar; its thumb drags and its track pages.
-- Inside a Project, older Terminal Sessions fold into collapsible groups the same way.
-- Rows keep the shell's order. Age only chooses a row's group, so rows never swap places under the pointer.
local SidebarView = Object:extend()
local TOOLTIP_DELAY = 0.4

local DAY = 24 * 60 * 60
local WEEK, MONTH = 7 * DAY, 30 * DAY
-- The groups. Each starts open or collapsed as given here unless saved otherwise. Unloaded Projects use every
-- group; a loaded Project's older Terminal Sessions use the groups with a terminal label.
local GROUPS = {
  {bucket = "week", label = "Last week", collapsed = false},
  {bucket = "month", label = "Last month", terminal_label = "Older than a week", collapsed = false},
  {bucket = "older", label = "Older", terminal_label = "Older than a month", collapsed = false},
}
-- The groups take at most this part of the height below the list top, and at most this many Project rows.
local GROUPS_HEIGHT = 0.5
local GROUPS_ROWS = 16

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
  self.projects, self.window_id = projects, window_id
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
    -- An agent's Tab adds a line for what the agent does.
    agent = 2 * h + 10 * SCALE,
    indent = 14 * SCALE,
  }
end

-- "week" for up to 7 days, "month" for 7 to 30 days, "older" beyond that or when unknown.
local function age_bucket(activity, now)
  if not activity or activity <= 0 then return "older" end
  local age = now - activity
  if age < WEEK then return "week" end
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
  -- An agent's result counts as seen once its Tab was the Window's active Tab.
  self.seen = self.seen or {}
  local function add_tab(row, agent)
    row.agent = agent
    if agent and (agent.state == "done" or agent.state == "error") then
      local session = row.tab.terminal.session
      if row.selected then self.seen[session] = agent.since end
      row.seen = self.seen[session] == agent.since
    end
    add(row, agent and m.agent or m.terminal)
  end
  local function add_terminal(project, terminal, depth)
    local item = tab.describe_session(terminal)
    add_tab({kind = "terminal", project = project, terminal = terminal, depth = depth, tab = item}, item.agent)
  end
  local function add_loaded(project)
    local is_selected = window_id and selected ~= 0 and project.id == selected or not window_id and project.selected
    local panes = project.panes or {}
    -- The Selected Project's active Tab takes the highlight.
    local active = is_selected and panes[panes.active or 0] and panes.active
    add({kind = "project", project = project, selected = is_selected and not active}, m.project)
    local shown, sizes, records = {}, {}, {}
    for _, item in ipairs(panes) do sizes[item.group or 0] = (sizes[item.group or 0] or 0) + 1 end
    for _, terminal in ipairs(project.terminals or {}) do records[terminal.id] = terminal end
    for index, item in ipairs(panes) do
      -- A Terminal Tab takes its agent's status from the Terminal Session record.
      local record = item.terminal and records[item.terminal.session]
      local agent = record and record.state == "running" and tab.agent(record)
      if agent then
        local copy = {agent = agent}
        for key, value in pairs(item) do copy[key] = value end
        item = copy
      end
      if item.terminal and item.terminal.session then shown[item.terminal.session] = true end
      local group = item.group or 0
      -- A Pane Group with several Panes joins its Tabs with a line.
      local bracket = sizes[group] > 1 and {first = (panes[index - 1] or {}).group ~= group,
        last = (panes[index + 1] or {}).group ~= group, visible = group == panes.visible} or nil
      add_tab({kind = "tab", project = project, tab = item, selected = index == active, bracket = bracket},
        item.agent)
    end
    -- Terminal Sessions that no Pane shows. Recent and ringing ones show directly, and so do those from hosts that
    -- do not report activity. Older ones fold into groups.
    local older = {}
    for _, terminal in ipairs(project.terminals or {}) do
      local bucket = (terminal.activity or 0) > 0 and age_bucket(terminal.activity, now)
      if shown[terminal.id] then
        -- Its Tab shows it.
      elseif bucket and bucket ~= "week" and not ((terminal.bell or 0) > 0) then
        older[bucket] = older[bucket] or {}
        table.insert(older[bucket], terminal)
      else
        add_terminal(project, terminal, 1)
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
          for _, terminal in ipairs(terminals) do add_terminal(project, terminal, 2) end
        end
      end
    end
  end
  area = "main"
  local grouped = {}
  for _, project in ipairs(projects) do
    if project.state == "dormant" then
      local bucket = age_bucket(project_activity(project), now)
      grouped[bucket] = grouped[bucket] or {}
      table.insert(grouped[bucket], project)
    else
      add_loaded(project)
    end
  end
  if #rows == 0 then
    add({kind = "empty", label = #projects > 0 and "No loaded Projects" or "No Projects yet"}, m.project)
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
        for _, project in ipairs(members) do add({kind = "project", project = project}, m.project) end
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
  local height = math.min(self.bottom_h + m.pad, math.floor(available * GROUPS_HEIGHT), GROUPS_ROWS * m.project + m.pad)
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

-- Each scrolling area with its visible span, content height and scroll field.
function SidebarView:scroll_areas()
  local m = metrics()
  local bottom_top, bottom_height = self:bottom_area()
  return {
    {field = "scroll", top = m.top, height = self:main_bottom() - m.top, content = self.main_h},
    {field = "bottom_scroll", top = bottom_top, height = bottom_height, content = self.bottom_h + m.pad},
  }
end

-- The area's scrollbar thumb top and height, or nil when the area does not overflow.
local function thumb(area, scroll)
  if area.height <= 0 or area.content <= area.height then return end
  local h = math.max(math.floor(24 * SCALE), area.height * area.height / area.content)
  return area.top + (area.height - h) * scroll / (area.content - area.height), h
end

-- The area whose scrollbar is at the point.
function SidebarView:scrollbar_at(x, y)
  if x < self.width - 12 * SCALE then return end
  for _, area in ipairs(self:scroll_areas()) do
    if y >= area.top and y < area.top + area.height and thumb(area, self[area.field]) then return area end
  end
end

function SidebarView:drag_scrollbar(y)
  local drag = self.scroll_drag
  local area
  for _, candidate in ipairs(self:scroll_areas()) do
    if candidate.field == drag.field then area = candidate end
  end
  local _, h = thumb(area, self[area.field])
  if not h then return end
  local range = area.height - h
  self[area.field] = range > 0 and (y - drag.offset - area.top) / range * (area.content - area.height) or 0
  self:clamp_scroll()
end

function SidebarView:on_mouse_pressed(button, x, y)
  if button ~= "left" and button ~= "right" and button ~= "middle" then return end
  local area = button == "left" and self:scrollbar_at(x, y)
  if area then
    -- A press on the track centres the thumb there, then drags it.
    local top, h = thumb(area, self[area.field])
    local offset = (y >= top and y < top + h) and y - top or h / 2
    self.scroll_drag = {field = area.field, offset = offset}
    self:drag_scrollbar(y)
    return
  end
  local row = self:row_at(y)
  if not row then return end
  if row.kind == "group" or row.kind == "terminal_group" then
    if button == "left" then self:toggle(row.key, row.collapsed) end
    return
  end
  if row.kind == "terminal" then
    if button == "left" then self.action("select_terminal", row.project.row_id, row.terminal.id) end
    return
  end
  if row.kind == "tab" then
    if button == "left" then
      self.action("pane", row.project.row_id, row.tab.id, "focus")
    elseif button == "middle" then
      self.click_row = {button = button, row_id = row.project.row_id, pane = row.tab.id}
    end
    return
  end
  if row.kind ~= "project" then return end
  if button == "right" or button == "middle" then
    -- The release acts, so the menu's loop never takes the press's own release.
    self.click_row = {button = button, row_id = row.project.row_id}
  else
    self.action("select", row.project.row_id)
  end
end

function SidebarView:on_mouse_released(button, x, y)
  if button == "left" then self.scroll_drag = nil; return end
  local pressed = self.click_row
  self.click_row = nil
  if not pressed or pressed.button ~= button then return end
  local row = self:row_at(y)
  if pressed.pane then
    if row and row.kind == "tab" and row.tab.id == pressed.pane and row.project.row_id == pressed.row_id then
      self.action("pane", pressed.row_id, pressed.pane, "close")
    end
    return
  end
  if not (row and row.kind == "project" and row.project.row_id == pressed.row_id) then return end
  if button == "right" then
    self.action("menu", pressed.row_id, x, y)
  else
    self.action("unload", pressed.row_id)
  end
end

function SidebarView:update_hover()
  local row = self.hover_y and self:row_at(self.hover_y)
  local hover = row and row.kind ~= "empty" and row or nil
  local scrollbar = self.hover_x and self:scrollbar_at(self.hover_x, self.hover_y)
  if scrollbar then hover = nil end
  scrollbar = scrollbar and scrollbar.field
  local changed = hover ~= self.hover or scrollbar ~= self.scrollbar_hover
  self.hover, self.scrollbar_hover = hover, scrollbar
  local tooltip = self:get_tooltip()
  if tooltip ~= self.tooltip_text then
    self.tooltip_text, self.tooltip_started = tooltip, system.get_time()
    changed = true
  end
  return changed
end

-- The original Terminal title remains available even when its display label is shorter.
function SidebarView:get_tooltip()
  if self.scroll_drag then return nil end
  local item = self.hover and self.hover.tab
  return item and item.terminal and item.name or nil
end

-- Returns true when the hover or a dragged scrollbar changed and the view needs a redraw.
function SidebarView:on_mouse_moved(x, y)
  self.hover_x, self.hover_y = x, y
  if self.scroll_drag then
    self:drag_scrollbar(y)
    self:update_hover()
    return true
  end
  return self:update_hover()
end

function SidebarView:on_mouse_left()
  self.hover_x, self.hover_y = nil, nil
  self.scroll_drag, self.click_row = nil, nil
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

-- Seconds until the next spinner frame, elapsed-time update, or hover tooltip.
function SidebarView:animation_delay(clock)
  local delay = self.spinning and tab.spinner_delay(clock) or nil
  if self.ticking then delay = math.min(delay or 1, 1 - clock % 1) end
  if self.tooltip_text then
    local remaining = TOOLTIP_DELAY - (clock - self.tooltip_started)
    if remaining > 0 then delay = math.min(delay or remaining, remaining) end
  end
  return delay
end

-- The running Terminal Sessions of an unloaded Project, such as "3 terminals, 1 busy, 1 needs you", or nil when
-- none run. An agent that waits at its prompt is not busy. Shorter forms follow for a narrow Sidebar.
local function terminal_hint(project)
  local running, busy, blocked = 0, 0, 0
  for _, terminal in ipairs(project.terminals or {}) do
    if terminal.state == "running" then
      running = running + 1
      local agent = tab.agent(terminal)
      if agent and agent.state == "blocked" then
        blocked = blocked + 1
      elseif agent and (agent.state == "working" or agent.step) or not agent and terminal.busy == 1 then
        busy = busy + 1
      end
    end
  end
  if running == 0 then return nil end
  local count = running .. (running == 1 and " terminal" or " terminals")
  local needs = blocked > 0 and ", " .. blocked .. " needs you" or ""
  return count .. (busy > 0 and ", " .. busy .. " busy" or "") .. needs, count .. needs, count
end

-- Draws a label shortened before a right-aligned note, then the note. The note keeps the same inset from the
-- row highlight's right edge as the row's content keeps from its left edge. The first hint that fits follows the
-- label in the dim colour.
function SidebarView:label_with_note(label, color, note, x, y, row, right, hints)
  local ty = y + (row.h - style.font:get_height()) / 2
  right = right - 8 * SCALE
  local note_w = note and style.font:get_width(note) + 8 * SCALE or 0
  if note_w > (right - x) / 2 then note, note_w = nil, 0 end
  local available = math.max(0, right - x - note_w)
  label = tab.fit(style.font, label, available)
  text(label, x, ty, color)
  local hint_x = x + style.font:get_width(label) + 8 * SCALE
  for _, hint in ipairs(hints or {}) do
    if hint_x + style.font:get_width(hint) <= x + available then
      text(hint, hint_x, ty, style.dim)
      break
    end
  end
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
  if row.kind == "tab" or row.kind == "terminal" then
    if row.bracket then
      -- The visible Pane Group's line stands out, as its Title Bar underline does.
      local inset = 4 * SCALE
      local top = y + (row.bracket.first and inset or 0)
      local bottom = y + row.h - (row.bracket.last and inset or 0)
      local line = math.max(2, math.floor(2 * SCALE))
      renderer.draw_rect(left + 12 * SCALE - line / 2, top, line, bottom - top,
        row.bracket.visible and style.titlebar_group_indicator or style.divider)
    end
    local x = left + 24 * SCALE + ((row.depth or 1) - 1) * m.indent
    local spinning, name_x = tab.draw(row.tab, x, y, right - 8 * SCALE - x, m.terminal,
      {name_color = style.text, now = now, clock = self.clock})
    if spinning then self.spinning = true end
    if row.agent and tab.draw_agent(row.agent, name_x, y + m.terminal - 6 * SCALE, right - 8 * SCALE - name_x,
        m.terminal, {now = now, seen = row.seen}) then
      self.ticking = true
    end
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
  local hints
  if project.state == "dormant" then
    note = note or tab.age_text(project_activity(project), now)
    hints = {terminal_hint(project)}
  end
  local dim_name = project.state == "dormant" and not project.exists
  self:label_with_note(name_of(project.path), dim_name and style.dim or style.text, note, x, y, row, right, hints)
end

function SidebarView:draw_tooltip(width, height)
  local label = self.tooltip_text
  if not label or self.clock - self.tooltip_started < TOOLTIP_DELAY then return end
  local font, padding, margin = style.font, style.padding.x, 4 * SCALE
  local available = width - 2 * (padding + margin)
  if available <= 0 then return end
  local starts = font:text_layout(label):wrap(available, "word")
  local lines, text_width = {}, 0
  for index, first in ipairs(starts) do
    local line = label:sub(first + 1, starts[index + 1] or #label)
    lines[#lines + 1] = line
    text_width = math.max(text_width, font:get_width(line))
  end
  local w, h = text_width + padding * 2, #lines * font:get_height() + padding * 2
  local x = margin
  local y = math.max(margin, math.min(self.hover_y + font:get_height(), height - h - margin))
  renderer.draw_rounded_rect(x - 1, y - 1, w + 2, h + 2, margin + 1, style.divider)
  renderer.draw_rounded_rect(x, y, w, h, margin, style.background3)
  for index, line in ipairs(lines) do
    renderer.draw_text(font, line, x + padding, y + padding + (index - 1) * font:get_height(), style.text)
  end
end

function SidebarView:draw(width, height)
  if width ~= self.width or height ~= self.view_h then self:set_size(width, height) end
  local now = os.time()
  self.clock, self.spinning, self.ticking = system.get_time(), false, false
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
  local bar_w = math.max(2, math.floor(4 * SCALE))
  for _, area in ipairs(self:scroll_areas()) do
    local top, h = thumb(area, self[area.field])
    if top then
      local active = self.scroll_drag and self.scroll_drag.field == area.field
      local color = active and style.scrollbar_active
        or self.scrollbar_hover == area.field and style.scrollbar_hover or style.scrollbar
      renderer.draw_rounded_rect(width - bar_w - 4 * SCALE, top, bar_w, h, bar_w / 2, color)
    end
  end
  self:draw_tooltip(width, height)
end

return SidebarView
