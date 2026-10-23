local Object = require "core.object"
local style = require "core.style"
local config = require "core.config"
local tab = require "core.tab"
local common = require "core.common"
local FocusFeedback = require "core.focus_feedback"

-- The shell owns identity and lifecycle. This view sends only Project, Pane and Terminal Session actions. A
-- right-click on a Project asks the shell for its native actions menu: Move, Unload and the rest.
-- The menu opens at the button's release. A menu opened at the press takes the release into its own loop, and the
-- shell then reports a stray left press that selects the Project.
-- Layout: a search field below the window caption, then the main list: loaded Projects with their Tabs, one for
-- each Pane, and the Terminal Sessions that no Pane shows. Unloaded Projects sit in collapsible age groups aligned
-- to the bottom, which take at most part of the height and scroll on their own. Their rows count their running
-- Terminal Sessions.
-- Each area that overflows shows a scrollbar; its thumb drags and its track pages.
-- Inside a Project, older Terminal Sessions fold into collapsible groups the same way.
-- Rows keep the shell's order. Age only chooses a row's group, so rows never swap places under the pointer.
-- Rows, highlights, chevrons and scrolling animate toward the layout. Hit testing uses the layout itself, so a
-- click acts on the row that moves to the pointer.
local SidebarView = Object:extend()
local TOOLTIP_DELAY = 0.4
-- Animated values approach their targets at these rates per second. A change is 95% done after 3 / rate seconds.
local MOVE_RATE, FADE_RATE, SCROLL_RATE = 20, 14, 22
-- The longest step between two frames. After a pause, an animation starts where it stopped.
local MAX_STEP = 1 / 30
local FRAME = 1 / 120

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

local function name_of(path)
  return path:match("([^/\\]+)[/\\]*$") or path
end

---@param action fun(name: string, ...)
---@param collapsed table<string, boolean>? Saved collapse state, shared by every Sidebar surface.
function SidebarView:new(action, collapsed)
  self.action, self.rows, self.scroll, self.bottom_scroll = action, {}, 0, 0
  self.collapsed = collapsed or {}
  self.width, self.view_h = 240, 600
  self.main_h, self.bottom_h = 0, 0
  self.query = ""
  self.focus_feedback = FocusFeedback()
  -- Shown state. Each value moves toward its layout target as frames draw.
  self.visuals, self.leaving, self.marks, self.chevrons = {}, {}, {}, {}
end

local function row_key(row)
  return row and row.id_key
end

-- Sizes in pixels at the current font and scale.
function SidebarView:metrics()
  local font = style.font
  local m = self.metrics_cache
  if m and m.font == font and m.scale == SCALE then return m end
  local h = font:get_height()
  local pad = 8 * SCALE
  local badge = math.floor(h + 3 * SCALE + 0.5)
  -- The shell drags the Window from a caption strip as tall as the Project's Title Bar, also over the Sidebar.
  local caption = math.max(h + 14 * SCALE, 32 * SCALE)
  m = {font = font, scale = SCALE,
    pad = pad,
    gap = 16 * SCALE,
    search_y = caption + 2 * SCALE,
    search = math.floor(h + 12 * SCALE + 0.5),
    group = h + 16 * SCALE,
    project = h + 16 * SCALE,
    terminal = h + 9 * SCALE,
    -- An agent's Tab adds a line for what the agent does.
    agent = 2 * h + 11 * SCALE,
    indent = 14 * SCALE,
    radius = 6 * SCALE,
    badge = badge,
  }
  m.top = m.search_y + m.search + 8 * SCALE
  -- Tabs sit under their Project's badge. A Pane Group's container starts at the badge's middle.
  m.tab_left = pad + 6 * SCALE + math.floor(badge / 2) - 4 * SCALE
  m.tab_x = m.tab_left + 10 * SCALE
  self.metrics_cache = m
  return m
end

function SidebarView:get_cursor() return self.rows[self.cursor] end

function SidebarView:reveal_cursor()
  local row = self:get_cursor()
  if not row then return end
  local field = row.area == "main" and "scroll" or "bottom_scroll"
  local top = row.area == "main" and self:list_top() or self:bottom_area()
  local bottom = row.area == "main" and self:main_bottom() or self.view_h
  local y = self:row_y(self.cursor)
  if y < top then self[field] = self[field] + y - top
  elseif y + row.h > bottom then self[field] = self[field] + y + row.h - bottom end
  self:clamp_scroll()
end

function SidebarView:on_focus(focused)
  self.focused = focused
  self.focus_feedback:update(focused and self or nil)
  self.query, self.cursor = "", nil
  self:rebuild_rows()
  if focused then
    for index, row in ipairs(self.rows) do
      if row.selected then self.cursor = index; break end
    end
    self:reveal_cursor()
  end
end

function SidebarView:on_text_input(text)
  if not self.focused then return end
  self.query, self.cursor = self.query .. text, nil
  self:rebuild_rows()
end

function SidebarView:activate_row(row)
  if not row then return end
  if row.kind == "project" then self.action("select", row.project.row_id)
  elseif row.kind == "tab" then self.action("pane", row.project.row_id, row.tab.id, "focus")
  elseif row.kind == "terminal" then self.action("select_terminal", row.project.row_id, row.terminal.id)
  elseif row.key then self:toggle(row.key, row.collapsed) end
end

function SidebarView:on_key_pressed(key)
  if not self.focused then return end
  local row = self:get_cursor()
  if key == "escape" then self.action("return_focus")
  elseif key == "return" or key == "keypad enter" then self:activate_row(row)
  elseif key == "backspace" then
    self.query = self.query:gsub("[%z\1-\127\194-\244][\128-\191]*$", "", 1)
    self.cursor = nil
    self:rebuild_rows()
  elseif key == "up" or key == "down" or key == "home" or key == "end" then
    local index = key == "home" and 1 or key == "end" and #self.rows
      or (self.cursor or 1) + (key == "up" and -1 or 1)
    index = math.max(1, math.min(#self.rows, index))
    if self.rows[index] and self.rows[index].kind ~= "empty" then self.cursor = index end
    self:reveal_cursor()
  elseif row and (key == "left" or key == "right") and self.query == "" then
    if row.key then
      if row.collapsed == (key == "right") then self:toggle(row.key, row.collapsed)
      elseif key == "right" then self:on_key_pressed("down") end
    elseif key == "left" and row.project then
      for index = self.cursor - 1, 1, -1 do
        local parent = self.rows[index]
        if parent.kind == "project" and parent.project == row.project then self.cursor = index; break end
      end
    end
    self:reveal_cursor()
  end
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

-- The left edge and width of a Tab's content.
function SidebarView:tab_bounds(row, width)
  local m = self:metrics()
  local x = m.tab_x + ((row.depth or 1) - 1) * m.indent
  return x, width - m.pad - 8 * SCALE - x
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
  local cursor_key = row_key(self:get_cursor())
  local searching = self.query ~= ""
  local projects, window_id = self.projects or {}, self.window_id
  local m = self:metrics()
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
    add_tab({kind = "terminal", project = project, terminal = terminal, depth = depth, tab = item,
      id_key = "terminal:" .. project.path .. ":" .. terminal.id}, item.agent)
  end
  local function add_loaded(project)
    local is_selected = window_id and selected ~= 0 and project.id == selected or not window_id and project.selected
    local panes = project.panes or {}
    -- The Selected Project's active Tab takes the highlight.
    local active = is_selected and panes[panes.active or 0] and panes.active
    local key = (#panes > 0 or #(project.terminals or {}) > 0) and ("project:" .. project.path) or nil
    local collapsed = key and self:is_collapsed(key, false) or false
    add({kind = "project", project = project, key = key, collapsed = collapsed, tabs = #panes,
      id_key = "project:" .. project.path, current = is_selected,
      selected = is_selected and (not active or collapsed and not searching)}, m.project)
    if collapsed and not searching then return end
    local shown, sizes, records = {}, {}, {}
    for _, item in ipairs(panes) do sizes[item.group or 0] = (sizes[item.group or 0] or 0) + 1 end
    for _, terminal in ipairs(project.terminals or {}) do records[terminal.id] = terminal end
    for index, item in ipairs(panes) do
      -- A Terminal Tab takes its agent's status from the Terminal Session record.
      local record = item.terminal and records[item.terminal.session]
      local agent = record and record.state == "running" and tab.agent(record)
      if agent then
        local copy = {agent = agent}
        for field, value in pairs(item) do copy[field] = value end
        item = copy
      end
      if item.terminal and item.terminal.session then shown[item.terminal.session] = true end
      local group = item.group or 0
      -- A Pane Group with several Panes shows as one container around its Tabs.
      local bracket = sizes[group] > 1 and {first = (panes[index - 1] or {}).group ~= group,
        last = (panes[index + 1] or {}).group ~= group, visible = group == panes.visible} or nil
      add_tab({kind = "tab", project = project, tab = item, selected = index == active, bracket = bracket,
        id_key = "tab:" .. project.path .. ":" .. tostring(item.id)}, item.agent)
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
        local group_key = "terminals:" .. group.bucket .. ":" .. project.path
        local group_collapsed = self:is_collapsed(group_key, true)
        add({kind = "terminal_group", project = project, bucket = group.bucket, label = group.terminal_label,
          count = #terminals, key = group_key, id_key = group_key, collapsed = group_collapsed}, m.terminal)
        if searching or not group_collapsed then
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
    local label = #projects > 0 and "No loaded Projects" or "No Projects yet"
    add({kind = "empty", label = label, id_key = "empty"}, m.project)
  end
  area = "bottom"
  for _, group in ipairs(GROUPS) do
    local members = grouped[group.bucket]
    if members then
      local key = "group:" .. group.bucket
      local collapsed = self:is_collapsed(key, group.collapsed)
      add({kind = "group", bucket = group.bucket, label = group.label, count = #members, key = key, id_key = key,
        collapsed = collapsed}, m.group)
      if searching or not collapsed then
        for _, project in ipairs(members) do
          add({kind = "project", project = project, id_key = "project:" .. project.path}, m.project)
        end
      end
    end
  end
  if searching then
    local filtered, matches = {}, {}
    for _, row in ipairs(rows) do
      if row.project and row.kind ~= "terminal_group" then
        local project_match = common.fuzzy_match(name_of(row.project.path), self.query) ~= nil
        row.matches = project_match or row.tab and common.fuzzy_match(row.tab.name or "", self.query) ~= nil
        if row.matches then matches[row.project] = true end
      end
    end
    for _, row in ipairs(rows) do
      if row.matches or row.kind == "project" and matches[row.project] then
        filtered[#filtered + 1] = row
      end
    end
    rows = filtered
    if #rows == 0 then rows = {{kind="empty",label="No matches",area="main",h=m.project,id_key="empty"}} end
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
  self.cursor = nil
  for index, row in ipairs(rows) do
    if cursor_key and row_key(row) == cursor_key then self.cursor = index; break end
  end
  if not self.cursor then
    for index, row in ipairs(rows) do
      if row.kind ~= "empty" and (not searching or row.matches) then self.cursor = index; break end
    end
  end
  self:clamp_scroll()
  if self.focused then self:reveal_cursor() end
  if self.hover_y then self:update_hover() end
end

-- The groups' height on screen, and the top of the area that shows them.
function SidebarView:bottom_area()
  if self.bottom_h == 0 then return self.view_h, 0 end
  local m = self:metrics()
  local available = math.max(0, self.view_h - m.top)
  local height = math.min(self.bottom_h + m.pad, math.floor(available * GROUPS_HEIGHT), GROUPS_ROWS * m.project + m.pad)
  return self.view_h - height, height
end

function SidebarView:main_bottom()
  local bottom_top, bottom_height = self:bottom_area()
  return bottom_height > 0 and bottom_top - self:metrics().gap or self.view_h
end

function SidebarView:clamp_scroll()
  local m = self:metrics()
  local _, bottom_height = self:bottom_area()
  self.scroll = math.max(0, math.min(self.scroll, self.main_h - (self:main_bottom() - m.top)))
  self.bottom_scroll = math.max(0, math.min(self.bottom_scroll, self.bottom_h + m.pad - bottom_height))
end

function SidebarView:list_top() return self:metrics().top end

-- The top of an area's content at a scroll offset.
function SidebarView:area_origin(area, scroll)
  if area == "bottom" then return self:bottom_area() - (scroll or self.bottom_scroll) end
  return self:list_top() - (scroll or self.scroll)
end

function SidebarView:row_y(index)
  local row = self.rows[index]
  if not row then return end
  return self:area_origin(row.area) + row.y
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

-- The search field's rectangle: x, y, width, height.
function SidebarView:search_rect()
  local m = self:metrics()
  return m.pad, m.search_y, self.width - 2 * m.pad, m.search
end

function SidebarView:search_at(x, y)
  local sx, sy, sw, sh = self:search_rect()
  return x >= sx and x < sx + sw and y >= sy and y < sy + sh
end

-- Each scrolling area with its visible span, content height and scroll field.
function SidebarView:scroll_areas()
  local m = self:metrics()
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
  -- The thumb follows the pointer without easing.
  self.shown = self.shown or {}
  self.shown[area.field] = self[area.field]
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
  if button == "left" and self:search_at(x, y) then
    if not self.focused then self.action("focus") end
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
  if button == "left" and row.key and x >= self.width - 32 * SCALE and self.query == "" then
    self:toggle(row.key, row.collapsed)
    return
  end
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
  local search = self.hover_x and self:search_at(self.hover_x, self.hover_y) or false
  local changed = hover ~= self.hover or scrollbar ~= self.scrollbar_hover or search ~= self.search_hover
  self.hover, self.scrollbar_hover, self.search_hover = hover, scrollbar, search
  local tooltip = self:get_tooltip()
  if tooltip ~= self.tooltip_text then
    self.tooltip_text, self.tooltip_started = tooltip, system.get_time()
    changed = true
  end
  return changed
end

-- Show the original Terminal title only when the Tab hides part of it.
function SidebarView:get_tooltip()
  if self.scroll_drag then return nil end
  local row = self.hover
  local item = row and row.tab
  if not item or not item.terminal then return nil end
  local name = tab.display_name(item)
  local _, width = self:tab_bounds(row, self.width)
  local available = tab.name_width(item, width, self:metrics().terminal)
  if name ~= item.name or tab.fit(style.font, name, available) ~= name then return item.name end
end

-- Returns true when the hover or a dragged scrollbar changed and the view needs a redraw.
function SidebarView:on_mouse_moved(x, y)
  self.hover_x, self.hover_y = x, y
  if self.scroll_drag then
    self:drag_scrollbar(y)
    self:update_hover()
    return true
  end
  local changed = self:update_hover()
  return changed or self.tooltip_text ~= nil
end

function SidebarView:on_mouse_left()
  self.hover_x, self.hover_y = nil, nil
  self.scroll_drag, self.click_row = nil, nil
  return self:update_hover()
end

-- Scrolls the area under the pointer.
function SidebarView:on_mouse_wheel(amount, height, y)
  if height then self.view_h = height end
  local step = self:metrics().project
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

------------------------------------------------------------------------------------------------------------------
-- Animation

-- Moves the shown state one step toward the layout. Returns true while something still moves.
function SidebarView:step(dt)
  local animate = config.transitions ~= false and dt > 0 and self.drawn
  local moving = false
  local function ease(value, target, rate, epsilon)
    if not animate or value == nil then return target end
    local next = value + (target - value) * (1 - math.exp(-rate * dt))
    if math.abs(target - next) <= (epsilon or 0.25) then return target end
    moving = true
    return next
  end
  self.shown = self.shown or {}
  local shown = self.shown
  shown.scroll = ease(shown.scroll, self.scroll, SCROLL_RATE)
  shown.bottom_scroll = ease(shown.bottom_scroll, self.bottom_scroll, SCROLL_RATE)
  -- Rows. A new row unfolds from the row above it, which already showed. A row that leaves fades where it was.
  local old, visuals = self.visuals, {}
  local unfold = {}
  for _, row in ipairs(self.rows) do
    local key, before = row.id_key, old[row.id_key]
    local visual
    if before and before.area == row.area then
      visual = {area = row.area, y = ease(before.y, row.y, MOVE_RATE), alpha = ease(before.alpha, 1, FADE_RATE, 0.01)}
    elseif animate then
      local start = unfold[row.area]
      visual = {area = row.area, y = start or row.y, alpha = 0}
      moving = true
    else
      visual = {area = row.area, y = row.y, alpha = 1}
    end
    if before and before.area == row.area then unfold[row.area] = before.y + row.h end
    visuals[key] = visual
    row.shown = visual
  end
  local leaving = {}
  for _, item in ipairs(self.leaving) do
    if not visuals[item.row.id_key] then
      item.alpha = ease(item.alpha, 0, FADE_RATE * 1.8, 0.02)
      if item.alpha > 0 then leaving[#leaving + 1] = item end
    end
  end
  if animate then
    for key, visual in pairs(old) do
      if not visuals[key] and visual.row and visual.alpha > 0.05 then
        leaving[#leaving + 1] = {row = visual.row, area = visual.area, y = visual.y, alpha = visual.alpha}
        moving = true
      end
    end
  end
  for _, row in ipairs(self.rows) do visuals[row.id_key].row = row end
  self.visuals, self.leaving = visuals, leaving
  -- Highlights glide from row to row and fade where no row takes them.
  local m = self:metrics()
  local function mark(name, row)
    local current = self.marks[name]
    if not row or not row.shown then
      if current then
        current.alpha = ease(current.alpha, 0, FADE_RATE * 1.5, 0.01)
        if current.alpha <= 0 then self.marks[name] = nil end
      end
      return
    end
    local x = (row.kind == "project" or row.kind == "group" or row.kind == "empty") and m.pad or m.tab_left
    if not current or current.area ~= row.area or current.alpha <= 0.01 then
      self.marks[name] = {area = row.area, x = x, y = row.shown.y, h = row.h, alpha = ease(0, 1, FADE_RATE * 1.5, 0.01)}
      return
    end
    current.x = ease(current.x, x, MOVE_RATE * 1.4)
    current.y = ease(current.y, row.shown.y, MOVE_RATE * 1.4)
    current.h = ease(current.h, row.h, MOVE_RATE * 1.4)
    current.alpha = ease(current.alpha, 1, FADE_RATE * 1.5, 0.01)
  end
  local active
  for _, row in ipairs(self.rows) do
    if row.selected then active = row; break end
  end
  mark("active", active)
  mark("cursor", self.focused and self:get_cursor() or nil)
  mark("hover", self.hover)
  for _, row in ipairs(self.rows) do
    if row.key then
      local target = row.collapsed and 0 or 1
      self.chevrons[row.key] = ease(self.chevrons[row.key], target, MOVE_RATE * 0.8, 0.01)
    end
  end
  return moving
end

-- The top of a row's area on screen, at the shown scroll.
function SidebarView:shown_origin(area)
  local shown = self.shown or {}
  return self:area_origin(area, area == "bottom" and shown.bottom_scroll or shown.scroll)
end

------------------------------------------------------------------------------------------------------------------
-- Drawing

local function tint(color, alpha)
  return {color[1], color[2], color[3], alpha}
end

-- The color with its alpha scaled. The color itself when the scale is 1, so callers can compare it.
local function fade(color, amount)
  if amount >= 1 then return color end
  return {color[1], color[2], color[3], (color[4] or 255) * amount}
end

local function project_status(project)
  if project.state == "failed" then return style.error, "failed" end
  if project.state == "dormant" then
    if not project.exists then return style.error, "unavailable" end
    return nil
  end
  if project.close_choice or project.deferred_dialog then return style.warn, "needs answer" end
  if project.state == "starting" then return style.warn, "starting" end
  if project.state == "closing" then return style.warn, "closing" end
  return nil
end

local function dot(x, cy, radius, color)
  renderer.draw_rounded_rect(x - radius, cy - radius, radius * 2, radius * 2, radius, color)
end

-- A small triangle that points right when closed and turns to point down as it opens.
local function chevron(cx, cy, openness, color)
  local size = 3.5 * SCALE
  local angle = (openness or 0) * math.pi / 2
  local c, s = math.cos(angle), math.sin(angle)
  local function point(x, y) return {cx + x * c - y * s, cy + x * s + y * c} end
  renderer.draw_poly({point(-0.6 * size, -size), point(0.9 * size, 0), point(-0.6 * size, size)}, color)
end

-- Draws text left-aligned in [x, right), clipped by the caller's clip rect.
local function text(label, x, y, color, font)
  renderer.draw_text(font or style.font, label, x, y, color)
end

-- Fonts derived from the current interface font: bold for Project names, small for section labels.
local derived = setmetatable({}, {__mode = "k"})
local function font_variant(name)
  local base = style.font
  local fonts = derived[base]
  if not fonts then fonts = {}; derived[base] = fonts end
  if not fonts[name] then
    local size = base:get_size()
    if name == "bold" then fonts[name] = base:copy(size, {bold = true})
    else fonts[name] = base:copy(math.max(1, math.floor(size * 0.84 + 0.5))) end
  end
  return fonts[name]
end

-- A Project's badge color: one of the theme's bright terminal colors, chosen by the Project's name, so the Project
-- keeps its color in every theme.
local function badge_color(name)
  local palette = style.terminal_palette
  local hash = 0
  for i = 1, #name do hash = (hash * 31 + name:byte(i)) % 65521 end
  return palette and palette[10 + hash % 6] or style.accent
end

local function initial(name)
  local first = name:match("[%w]") or name:match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
  return first:upper()
end

-- Seconds until the next spinner frame, elapsed-time update, animation frame or hover tooltip.
function SidebarView:animation_delay(clock)
  local delay = self.spinning and tab.spinner_delay(clock) or nil
  if self.animating or self.focus_feedback:active(clock) then delay = math.min(delay or math.huge, FRAME) end
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
function SidebarView:label_with_note(label, color, note, x, y, row, right, hints, font)
  font = font or style.font
  local ty = y + math.floor((row.h - font:get_height()) / 2)
  local note_ty = y + math.floor((row.h - style.font:get_height()) / 2)
  right = right - 8 * SCALE
  local note_w = note and style.font:get_width(note) + 8 * SCALE or 0
  if note_w > (right - x) / 2 then note, note_w = nil, 0 end
  local available = math.max(0, right - x - note_w)
  label = tab.fit(font, label, available)
  text(label, x, ty, color, font)
  local hint_x = x + font:get_width(label) + 8 * SCALE
  for _, hint in ipairs(hints or {}) do
    if hint_x + style.font:get_width(hint) <= x + available then
      text(hint, hint_x, note_ty, style.dim)
      break
    end
  end
  if note then text(note, right - note_w + 8 * SCALE, note_ty, style.dim) end
end

-- A section header: a chevron, a small uppercase label, a line and a count.
function SidebarView:draw_section(row, x, y, right)
  local cy = y + row.h / 2
  local hovered = self.hover == row
  local color = hovered and style.text or style.dim
  chevron(x + 4 * SCALE, cy, self.chevrons[row.key], color)
  local font = font_variant("small")
  local label = row.label:upper()
  local lx = x + 14 * SCALE
  local count = tostring(row.count)
  local count_w = font:get_width(count)
  right = right - 8 * SCALE
  label = tab.fit(font, label, math.max(0, right - count_w - 12 * SCALE - lx))
  local ty = y + math.floor((row.h - font:get_height()) / 2)
  text(label, lx, ty, color, font)
  text(count, right - count_w, ty, style.dim, font)
  local line_x = lx + font:get_width(label) + 8 * SCALE
  local line_right = right - count_w - 8 * SCALE
  if line_right > line_x then
    renderer.draw_rect(line_x, math.floor(cy), line_right - line_x, math.max(1, math.floor(SCALE)), style.divider)
  end
end

function SidebarView:draw_project(row, y, width, now)
  local m = self:metrics()
  local cy = y + row.h / 2
  local left, right = m.pad, width - m.pad
  local project = row.project
  local name = name_of(project.path)
  local dormant = project.state == "dormant"
  -- The badge. The Window's Selected Project has a solid badge.
  local size = m.badge
  local bx, by = left + 6 * SCALE, math.floor(cy - size / 2)
  local color = badge_color(name)
  local strength = dormant and 0.55 or 1
  local radius = math.floor(size * 0.3)
  local bold = font_variant("bold")
  local letter = initial(name)
  local letter_color = tint(color, 255 * strength)
  if row.current then
    renderer.draw_rounded_rect(bx, by, size, size, radius, color)
    letter_color = style.background2
  else
    renderer.draw_rounded_rect(bx, by, size, size, radius, tint(color, 46 * strength))
  end
  text(letter, bx + math.floor((size - bold:get_width(letter)) / 2), by + math.floor((size - bold:get_height()) / 2),
    letter_color, bold)
  local status, note = project_status(project)
  if status then
    -- A ring in the panel's colour separates the dot from the badge.
    dot(bx + size - SCALE, by + size - SCALE, 5 * SCALE, style.background2)
    dot(bx + size - SCALE, by + size - SCALE, 3.5 * SCALE, status)
  end
  -- The chevron keeps its space, so the note does not move when it shows.
  if row.key and self.query == "" then
    local shows = row.collapsed or self.hover == row or self.focused and self:get_cursor() == row
    if shows then chevron(right - 12 * SCALE, cy, self.chevrons[row.key], style.dim) end
    right = right - 20 * SCALE
  end
  if not note and project.window_id and project.window_id ~= 0 and self.window_id
    and project.window_id ~= self.window_id then
    note = "Window " .. project.window_id
  end
  local hints
  if dormant then
    note = note or tab.age_text(project_activity(project), now)
    hints = {terminal_hint(project)}
  elseif row.collapsed and (row.tabs or 0) > 0 then
    hints = {row.tabs .. (row.tabs == 1 and " tab" or " tabs")}
  end
  local name_color = dormant and not project.exists and style.dim or style.text
  self:label_with_note(name, name_color, note, bx + size + 8 * SCALE, y, row, right, hints,
    dormant and style.font or bold)
end

function SidebarView:draw_row(row, y, width, now)
  local m = self:metrics()
  local left, right = m.pad, width - m.pad
  if row.kind == "empty" then
    self:label_with_note(row.label, style.dim, nil, left + 8 * SCALE, y, row, right)
    return
  end
  if row.kind == "group" then
    self:draw_section(row, left + 4 * SCALE, y, right)
    return
  end
  if row.kind == "terminal_group" then
    self:draw_section(row, m.tab_x, y, right)
    return
  end
  if row.kind == "tab" or row.kind == "terminal" then
    local x, tab_width = self:tab_bounds(row, width)
    local spinning, name_x = tab.draw(row.tab, x, y, tab_width, m.terminal,
      {name_color = style.text, now = now, clock = self.clock})
    if spinning then self.spinning = true end
    if row.agent and tab.draw_agent(row.agent, name_x, y + m.terminal - 6 * SCALE, right - 8 * SCALE - name_x,
        m.terminal, {now = now, seen = row.seen}) then
      self.ticking = true
    end
    return
  end
  self:draw_project(row, y, width, now)
end

-- Pane Groups with several Panes: one rounded container behind their Tabs. The visible group has an accent rail.
function SidebarView:draw_containers(area, width)
  local m = self:metrics()
  local origin = self:shown_origin(area)
  local first
  for _, row in ipairs(self.rows) do
    if row.area == area and row.bracket and row.shown then
      if row.bracket.first or not first then first = row end
      if row.bracket.last then
        local top = origin + first.shown.y
        local bottom = origin + row.shown.y + row.h
        local alpha = math.min(first.shown.alpha, row.shown.alpha)
        local x, w = m.tab_left, width - m.pad - m.tab_left
        renderer.draw_rounded_rect(x, top + 1, w, bottom - top - 2, m.radius, fade(style.sidebar_group, alpha))
        local rail = math.max(2, math.floor(2 * SCALE))
        renderer.draw_rect(x + 3 * SCALE, top + 6 * SCALE, rail, bottom - top - 12 * SCALE,
          fade(row.bracket.visible and style.titlebar_group_indicator or style.divider, alpha))
        first = nil
      end
    end
  end
end

function SidebarView:draw_mark(name, area, width, color)
  local mark = self.marks[name]
  if not mark or mark.area ~= area or mark.alpha <= 0.01 then return end
  local m = self:metrics()
  local y = self:shown_origin(area) + mark.y
  renderer.draw_rounded_rect(mark.x, y + 1, width - m.pad - mark.x, mark.h - 2, m.radius, fade(color, mark.alpha))
end

function SidebarView:draw_search()
  local m = self:metrics()
  local x, y, w, h = self:search_rect()
  local focused = self.focused
  if focused then
    -- An input field with an accent outline.
    local border = math.max(1, math.floor(1.5 * SCALE + 0.5))
    renderer.draw_rounded_rect(x, y, w, h, m.radius, style.accent)
    renderer.draw_rounded_rect(x + border, y + border, w - 2 * border, h - 2 * border, m.radius - border,
      style.background)
  else
    renderer.draw_rounded_rect(x, y, w, h, m.radius, self.search_hover and style.sidebar_hover or style.sidebar_field)
  end
  local icon = style.icon_font
  local ix = x + 8 * SCALE
  text("L", ix, y + math.floor((h - icon:get_height()) / 2), focused and style.accent or style.dim, icon)
  local tx = ix + icon:get_width("L") + 8 * SCALE
  local ty = y + math.floor((h - style.font:get_height()) / 2)
  local right = x + w - 8 * SCALE
  if focused then
    local query = tab.fit(style.font, self.query, math.max(0, right - tx - 4 * SCALE))
    if query ~= "" then text(query, tx, ty, style.text) end
    local caret_x = tx + style.font:get_width(query)
    renderer.draw_rect(caret_x + SCALE, ty, math.max(1, math.floor(1.5 * SCALE)), style.font:get_height(), style.accent)
    if self.query == "" then
      text(tab.fit(style.font, "Type to search", right - caret_x - 6 * SCALE), caret_x + 6 * SCALE, ty, style.dim)
    end
    return
  end
  local hint = self.shortcut
  local hint_w = hint and style.font:get_width(hint) or 0
  if hint and hint_w + 60 * SCALE > right - tx then hint, hint_w = nil, 0 end
  text(tab.fit(style.font, "Search", right - tx - hint_w - 8 * SCALE), tx, ty, style.dim)
  if hint then text(hint, right - hint_w, ty, style.dim) end
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
  local x = math.max(margin, math.min(self.hover_x + margin, width - w - margin))
  local y = math.max(margin, math.min(self.hover_y + font:get_height(), height - h - margin))
  renderer.draw_rounded_rect(x - 1, y - 1, w + 2, h + 2, margin + 1, style.divider)
  renderer.draw_rounded_rect(x, y, w, h, margin, style.background3)
  for index, line in ipairs(lines) do
    renderer.draw_text(font, line, x + padding, y + padding + (index - 1) * font:get_height(), style.text)
  end
end

-- Draws one row at its shown position and opacity.
function SidebarView:draw_shown(row, y, alpha, width, now)
  if alpha < 0.999 then
    renderer.push_transform(0, 0, 1, alpha)
    self:draw_row(row, y, width, now)
    renderer.pop_transform()
  else
    self:draw_row(row, y, width, now)
  end
end

function SidebarView:draw(width, height)
  if width ~= self.width or height ~= self.view_h then self:set_size(width, height) end
  local now = os.time()
  local clock = system.get_time()
  local dt = self.last_clock and math.max(0, math.min(MAX_STEP, clock - self.last_clock)) or 0
  self.clock, self.last_clock, self.spinning, self.ticking = clock, clock, false, false
  self.animating = self:step(dt)
  self.drawn = true
  renderer.set_clip_rect(0, 0, width, height)
  -- On a transparent surface the shell blends the panel over the Project's backdrop and wallpaper.
  renderer.draw_rect(0, 0, width, height,
    system.is_surface_transparent() and style.wallpaper_surface(style.background2) or style.background2)
  renderer.draw_rect(width - math.max(1, SCALE), 0, math.max(1, SCALE), height, style.divider)
  self:draw_search()
  local m = self:metrics()
  local top, main_bottom = self:list_top(), self:main_bottom()
  local bottom_top, bottom_height = self:bottom_area()
  if bottom_height > 0 then
    renderer.draw_rect(m.pad + 8 * SCALE, bottom_top - math.floor(m.gap / 2), width - 2 * m.pad - 16 * SCALE,
      math.max(1, math.floor(SCALE)), style.divider)
  end
  local active_color = self.focused and style.row_selection_inactive or style.row_selection
  for _, area in ipairs({{"main", top, main_bottom}, {"bottom", bottom_top, height}}) do
    local name, area_top, area_bottom = area[1], area[2], area[3]
    renderer.set_clip_rect(0, area_top, width, math.max(0, area_bottom - area_top))
    self:draw_containers(name, width)
    self:draw_mark("hover", name, width, style.sidebar_hover)
    self:draw_mark("active", name, width, active_color)
    self:draw_mark("cursor", name, width, style.row_selection)
    local origin = self:shown_origin(name)
    for _, item in ipairs(self.leaving) do
      if item.area == name then self:draw_shown(item.row, origin + item.y, item.alpha, width, now) end
    end
    for _, row in ipairs(self.rows) do
      if row.area == name then
        local y = origin + row.shown.y
        if y + row.h > area_top and y < area_bottom then self:draw_shown(row, y, row.shown.alpha, width, now) end
      end
    end
  end
  renderer.set_clip_rect(0, 0, width, height)
  local bar_w = math.max(2, math.floor(4 * SCALE))
  for _, area in ipairs(self:scroll_areas()) do
    local thumb_top, h = thumb(area, self.shown[area.field] or self[area.field])
    if thumb_top then
      local active = self.scroll_drag and self.scroll_drag.field == area.field
      local color = active and style.scrollbar_active
        or self.scrollbar_hover == area.field and style.scrollbar_hover or style.scrollbar
      renderer.draw_rounded_rect(width - bar_w - 4 * SCALE, thumb_top, bar_w, h, bar_w / 2, color)
    end
  end
  self.focus_feedback:draw(0, 0, width, height, self.clock)
  self:draw_tooltip(width, height)
end

return SidebarView
