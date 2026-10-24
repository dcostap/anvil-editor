local Object = require "core.object"
local style = require "core.style"
local config = require "core.config"
local tab = require "core.tab"
local numbered_panes = require "core.numbered_panes"
local common = require "core.common"
local LineInput = require "core.line_input"
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
-- Drag and drop: a dragged Tab or a drop from another application lands on a line between Tabs, which places a new
-- Pane there, or on a row. A Tab's middle takes the drop into its Pane; a Project's row takes it into that Project.
-- The receiving Project performs each request and reports its new Tabs, which then slide to their places.
local SidebarView = Object:extend()
local TOOLTIP_DELAY = 0.4
-- A press on a Tab becomes a drag after the pointer moves this far.
local DRAG_THRESHOLD = 6
-- Parts of a Tab's height. A drop near an edge inserts beside the Tab; at a Pane Group's outer edge, the outer
-- part makes a new group instead of joining it.
local EDGE, OUTER_EDGE = 0.32, 0.15
-- A drag this close to an area's edge scrolls it, up to this speed in pixels per second.
local SCROLL_ZONE, SCROLL_SPEED = 28, 900
-- A dropped Tab stays dim at its old place until its Project reports the result, at most this long.
local PENDING_MOVE, PENDING_TRANSFER = 1.5, 4
-- A chosen row keeps the selection until the model selects it, at most this long.
local CHOICE_TIMEOUT = 5
-- Animated values approach their targets at these rates per second. A change is 95% done after 3 / rate seconds.
local MOVE_RATE, FADE_RATE, SCROLL_RATE = 20, 14, 22
-- Highlights glide and fade at these base rates, times their speed. The hover highlight follows the pointer fastest.
local MARK_MOVE_RATE, MARK_FADE_RATE = 28, 21
local SELECTION_SPEED, HOVER_SPEED = 1.75, 3
-- Rows move, appear and leave at this multiple of the base rates.
local ROW_SPEED = 1.8
-- The search field opens and closes at this rate.
local SEARCH_RATE = 54
-- A working Terminal's status text shimmers: a light crosses it in SHIMMER_TRAVEL seconds, once each SHIMMER_PERIOD
-- seconds. The colours change one letter at a time, so SHIMMER_FRAME can be longer than a display frame.
local SHIMMER_TRAVEL, SHIMMER_PERIOD, SHIMMER_FRAME = 1.3, 1.5, 1 / 30
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
---@param collapsed table<string, boolean>? This Window's saved folding state.
---@param collapse_projects boolean? Start other Projects collapsed and restore saved folds on first selection.
function SidebarView:new(action, collapsed, seen, collapse_projects)
  self.action, self.rows, self.scroll, self.bottom_scroll = action, {}, 0, 0
  self.collapsed = collapsed or {}
  self.collapse_projects = collapse_projects == true
  -- When the user last looked at each Terminal Session, by its ID. Every surface shares it.
  self.seen = seen or {}
  -- The Selected Projects that show expanded over their saved state, and the Projects selected at the last layout.
  self.opened, self.was_selected = {}, {}
  self.width, self.view_h = 240, 600
  self.main_h, self.bottom_h = 0, 0
  -- The search field's text, caret and selection. `query` is its text.
  self.input, self.query, self.search_scroll = LineInput(), "", 0
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
    -- The space above each loaded Project after the first.
    project_gap = 14 * SCALE,
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
  -- The list starts below the caption strip. While a query is typed, the search field opens above it.
  m.top = m.search_y
  m.search_space = m.search + 8 * SCALE
  -- Tabs sit under their Project's badge. A Pane Group's container starts at the badge's middle.
  m.tab_left = pad + 6 * SCALE + math.floor(badge / 2) - 4 * SCALE
  m.tab_x = m.tab_left + 10 * SCALE
  -- A Pane Group's rail and a pending Terminal's bar share one line, so a pending Tab's bar covers its group's rail.
  m.rail_x, m.rail = m.tab_left + 3 * SCALE, math.max(2, math.floor(2 * SCALE))
  -- Pane numbers end here, left of their Tab's row and its Pane Group's rail.
  m.number_gutter = m.tab_left - 3 * SCALE
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
  self.input:set_text("")
  self.query, self.cursor, self.selecting = "", nil, nil
  self:rebuild_rows()
  if focused then
    for index, row in ipairs(self.rows) do
      if row.selected then self.cursor = index; break end
    end
    self:reveal_cursor()
  end
end

-- Filters the list again after the search field's text changed.
function SidebarView:input_changed()
  if self.input.text == self.query then return end
  self.query, self.cursor = self.input.text, nil
  self:rebuild_rows()
end

function SidebarView:on_text_input(text)
  if not self.focused then return end
  self.input:insert(text)
  self:input_changed()
end

-- Performs the editor's line command `name` in the search field, such as "select_to_previous_word_start". Without a
-- query it returns false, so the same keys move through the list. A paste can start a query.
function SidebarView:edit(name)
  if not self.focused or self.query == "" and name ~= "paste" then return false end
  if not self.input:perform(name) then return false end
  self:input_changed()
  return true
end

-- The shell keeps a Window's old selection until a chosen Pane renders, and opens a Terminal Session's Pane after
-- it selects the Project. The chosen row shows the selection meanwhile, so the highlight does not go back.
function SidebarView:choose(row)
  local owner = row.project.window_id
  if row.selected or row.current or self.window_id and owner and owner ~= 0 and owner ~= self.window_id then return end
  self.chosen = {key = row.id_key, path = row.project.path, session = row.kind == "terminal" and row.terminal.id or nil,
    deadline = system.get_time() + CHOICE_TIMEOUT}
  self:rebuild_rows()
end

function SidebarView:activate_row(row)
  if not row then return end
  if row.kind == "project" or row.kind == "tab" or row.kind == "terminal" then self:choose(row) end
  if row.kind == "project" then self.action("select", row.project.row_id)
  elseif row.kind == "tab" then self.action("request", "select", row.project.path, {action = "focus", pane = row.tab.id})
  elseif row.kind == "terminal" then self.action("select_terminal", row.project.row_id, row.terminal.id)
  elseif row.key then self:toggle(row.key, row.collapsed) end
end

function SidebarView:new_group()
  local row = self:get_cursor()
  if not self.focused or not row or not row.project then return false end
  self.action("request", "select", row.project.path, {action = "new_group"})
  return true
end

function SidebarView:on_key_pressed(key)
  if not self.focused then return end
  local row = self:get_cursor()
  if key == "escape" then self.action("return_focus")
  elseif key == "return" or key == "keypad enter" then self:activate_row(row)
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
  -- A Tab moved inside its Project shows its result in the next report.
  if self.pending and not self.pending.transfer then self.pending = nil end
  self:rebuild_rows()
end

function SidebarView:row_by_key(key)
  for index, row in ipairs(self.rows) do
    if row.id_key == key then return row, index end
  end
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
  local collapsed = self.opened[key] or not self:is_collapsed(key, default)
  self.opened[key] = nil
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
  local rows, selected_keys = {}, {}
  local area
  local function add(row, height)
    row.h, row.area = height, area
    rows[#rows + 1] = row
  end
  local selected = 0
  for _, window in ipairs(projects.windows or {}) do
    if window.id == window_id then selected = window.selected_project end
  end
  local numbers = numbered_panes.numbers(projects, self.seen)
  -- A collapsed Project shows only the Terminals that need the user.
  local only_attention = false
  local function add_tab(row, agent)
    row.agent = agent
    if row.tab.terminal then row.attention = tab.attention(row.tab, self.seen[row.tab.terminal.session]) end
    if only_attention and not row.attention then return end
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
    -- A Project expands when it becomes selected, over its saved state. A collapse while it is selected acts.
    if key then
      if is_selected and not self.was_selected[key] then
        -- A restored Window keeps its manual fold. Later selections still expand the chosen Project.
        self.opened[key] = not self.collapse_projects or self.selected_once or self.collapsed[key] == nil
        self.selected_once = true
      end
      if not is_selected then self.opened[key] = nil end
      selected_keys[key] = is_selected or nil
    end
    local collapsed = key and not self.opened[key] and self:is_collapsed(key, self.collapse_projects) or false
    add({kind = "project", project = project, key = key, collapsed = collapsed, tabs = #panes,
      id_key = "project:" .. project.path, current = is_selected,
      selected = is_selected and (not active or collapsed and not searching)}, m.project)
    only_attention = collapsed and not searching
    local shown, sizes, records = {}, {}, {}
    for _, item in ipairs(panes) do sizes[item.group or 0] = (sizes[item.group or 0] or 0) + 1 end
    for _, terminal in ipairs(project.terminals or {}) do records[terminal.id] = terminal end
    for index, item in ipairs(panes) do
      -- A Terminal Tab takes its agent's status from the Terminal Session record and its Pane's number.
      local record = item.terminal and records[item.terminal.session]
      local agent = record and record.state == "running" and tab.agent(record)
      local copy = {agent = agent}
      for field, value in pairs(item) do copy[field] = value end
      item, copy.number = copy, numbers[numbered_panes.key(project.path, item.id)]
      local session = item.terminal and item.terminal.session
      if session then
        shown[session] = true
        -- The user looks at the Selected Project's active Tab, so its Unread Result becomes read.
        local attention = index == active and tab.attention(item, self.seen[session])
        if attention and attention ~= "blocked" then
          self.seen[session] = now
          self.action("seen", session)
        end
      end
      local group = item.group or 0
      -- A Pane Group with several Panes shows as one container around its Tabs. A collapsed Project shows single
      -- Tabs, so it has no containers.
      local bracket = sizes[group] > 1 and not only_attention and {first = (panes[index - 1] or {}).group ~= group,
        last = (panes[index + 1] or {}).group ~= group, visible = group == panes.visible} or nil
      add_tab({kind = "tab", project = project, tab = item, selected = index == active, bracket = bracket,
        id_key = "tab:" .. project.path .. ":" .. tostring(item.id)}, item.agent)
    end
    -- Terminal Sessions that no Pane shows. Recent ones and those that need the user show directly, and so do
    -- those from hosts that do not report activity. Older ones fold into groups.
    local older = {}
    for _, terminal in ipairs(project.terminals or {}) do
      local bucket = (terminal.activity or 0) > 0 and age_bucket(terminal.activity, now)
      if shown[terminal.id] then
        -- Its Tab shows it.
      elseif bucket and bucket ~= "week"
        and not tab.attention(tab.describe_session(terminal), self.seen[terminal.id]) then
        older[bucket] = older[bucket] or {}
        table.insert(older[bucket], terminal)
      else
        add_terminal(project, terminal, 1)
      end
    end
    for _, group in ipairs(GROUPS) do
      local terminals = older[group.bucket]
      if terminals and not only_attention then
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
      if row.kind == "project" and main_y > 0 then main_y = main_y + m.project_gap end
      row.y, main_y = main_y, main_y + row.h
    else
      row.y, bottom_y = bottom_y, bottom_y + row.h
    end
  end
  -- The chosen row, or the Tab that shows the chosen Terminal Session, takes the selection until the model selects it.
  local chosen, target = self.chosen, nil
  if chosen then
    for _, row in ipairs(rows) do
      if row.id_key == chosen.key or chosen.session and row.kind == "tab" and row.project.path == chosen.path
        and row.tab.terminal and row.tab.terminal.session == chosen.session then target = row end
    end
    if not target or target.selected or target.current then
      self.chosen = nil
    else
      for _, row in ipairs(rows) do row.selected = nil end
      target.selected = true
    end
  end
  self.rows, self.main_h, self.bottom_h = rows, main_y, bottom_y
  self.was_selected = selected_keys
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
  if self.drag then self:update_drag() end
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
  self.scroll = math.max(0, math.min(self.scroll, self.main_h - (self:main_bottom() - self:list_top())))
  self.bottom_scroll = math.max(0, math.min(self.bottom_scroll, self.bottom_h + m.pad - bottom_height))
end

function SidebarView:search_open() return self.query ~= "" end

function SidebarView:list_top()
  local m = self:metrics()
  return m.top + (self:search_open() and m.search_space or 0)
end

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

-- Each scrolling area with its visible span, content height and scroll field.
function SidebarView:scroll_areas()
  local m = self:metrics()
  local bottom_top, bottom_height = self:bottom_area()
  return {
    {field = "scroll", top = self:list_top(), height = self:main_bottom() - self:list_top(), content = self.main_h},
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

-- The search field's text area: its left edge, top, width and height.
function SidebarView:search_box()
  local m = self:metrics()
  local tx = m.pad + 16 * SCALE + style.icon_font:get_width("L")
  return tx, m.search_y, math.max(0, self.width - m.pad - 12 * SCALE - tx), m.search
end

function SidebarView:in_search(x, y)
  local m = self:metrics()
  return self:search_open() and x >= m.pad and x < self.width - m.pad and y >= m.search_y
    and y < m.search_y + m.search
end

-- The caret offset at the pointer's `x` in the search field.
function SidebarView:search_offset(x)
  return self.input:offset_at(style.font, x - self:search_box() + self.search_scroll)
end

-- The Project arrow has its own hit area, even when the Project is not selected.
function SidebarView:project_arrow_at(row, x)
  return row and row.kind == "project" and row.key and self.query == ""
    and x >= self.width - 32 * SCALE and x < self.width - self:metrics().pad
end

function SidebarView:on_mouse_pressed(button, x, y)
  if button ~= "left" and button ~= "right" and button ~= "middle" then return end
  if self:in_search(x, y) then
    -- A press places the caret. A drag from it selects.
    if button == "left" then
      self.input:set_caret(self:search_offset(x))
      self.selecting = true
    end
    return
  end
  local area = button == "left" and self:scrollbar_at(x, y)
  if area then
    -- A press on the track centres the thumb there, then drags it.
    local top, h = thumb(area, self[area.field])
    local offset = (y >= top and y < top + h) and y - top or h / 2
    self.scroll_drag = {field = area.field, offset = offset}
    self:drag_scrollbar(y)
    return
  end
  local row, index = self:row_at(y)
  if not row then return end
  if row.kind == "group" or row.kind == "terminal_group" then
    if button == "left" then self:toggle(row.key, row.collapsed) end
    return
  end
  if row.kind == "terminal" then
    if button == "left" then self:activate_row(row) end
    return
  end
  if row.kind == "tab" then
    if button == "left" then
      self:activate_row(row)
      -- The press becomes a drag when the pointer moves far enough.
      self.press = {key = row.id_key, x = x, y = y}
    elseif button == "middle" then
      self.click_row = {button = button, path = row.project.path, pane = row.tab.id}
    end
    return
  end
  if row.kind ~= "project" then return end
  if button == "left" and row.key and self.query == "" and (row.current or self:project_arrow_at(row, x)) then
    self:toggle(row.key, row.collapsed)
    return
  end
  if button == "right" or button == "middle" then
    -- The release acts, so the menu's loop never takes the press's own release.
    self.click_row = {button = button, row_id = row.project.row_id}
  else
    self:activate_row(row)
  end
end

function SidebarView:on_mouse_released(button, x, y)
  if button == "left" then
    self.scroll_drag, self.press, self.selecting = nil, nil, nil
    if self.drag then self:finish_drag(x, y) end
    return
  end
  local pressed = self.click_row
  self.click_row = nil
  if not pressed or pressed.button ~= button then return end
  -- The shell sends a release outside the Sidebar too.
  local row = x >= 0 and x < self.width and self:row_at(y)
  if pressed.pane then
    if row and row.kind == "tab" and row.tab.id == pressed.pane and row.project.path == pressed.path then
      self.action("request", "select", pressed.path, {action = "close", pane = pressed.pane})
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
  local inside = self.hover_x and self.hover_x >= 0 and self.hover_x < self.width
  local row = inside and not self.drag and self:row_at(self.hover_y)
  local hover = row and row.kind ~= "empty" and row or nil
  local scrollbar = self.hover_x and self:scrollbar_at(self.hover_x, self.hover_y)
  if scrollbar then hover = nil end
  scrollbar = scrollbar and scrollbar.field
  local arrow = hover and self:project_arrow_at(hover, self.hover_x) and hover or nil
  local changed = hover ~= self.hover or scrollbar ~= self.scrollbar_hover or arrow ~= self.arrow_hover
  self.hover, self.scrollbar_hover, self.arrow_hover = hover, scrollbar, arrow
  local tooltip = self:get_tooltip()
  if tooltip ~= self.tooltip_text then
    self.tooltip_text, self.tooltip_started = tooltip, system.get_time()
    changed = true
  end
  return changed
end

-- Show the original Terminal title only when the Tab hides part of it.
function SidebarView:get_tooltip()
  if self.scroll_drag or self.drag then return nil end
  local row = self.hover
  local item = row and row.tab
  if not item or not item.terminal then return nil end
  local name = tab.display_name(item)
  local _, width = self:tab_bounds(row, self.width)
  local available = tab.name_width(item, width, self:metrics().terminal, {number_gutter = self:metrics().number_gutter})
  if name ~= item.name or tab.fit(style.font, name, available) ~= name then return item.name end
end

-- Returns true when the hover or a dragged scrollbar changed and the view needs a redraw.
function SidebarView:on_mouse_moved(x, y)
  self.hover_x, self.hover_y = x, y
  if self.selecting then
    self.input:set_caret(self:search_offset(x), true)
    return true
  end
  if self.scroll_drag then
    self:drag_scrollbar(y)
    self:update_hover()
    return true
  end
  local press = self.press
  if press and math.max(math.abs(x - press.x), math.abs(y - press.y)) >= DRAG_THRESHOLD * SCALE then
    self.press = nil
    local row, index = self:row_by_key(press.key)
    if row then
      self.drag = {key = press.key, row = row}
      self.card = {row = row, from = self:card_slot(row, self:row_y(index)), lift = 0, alpha = 1}
    end
  end
  if self.drag then
    self.drag.x, self.drag.y = x, y
    self:update_drag()
    if self.drag then self:send_work("move") end
    self:update_hover()
    return true
  end
  local changed = self:update_hover()
  return changed or self.tooltip_text ~= nil
end

-- The shell holds the pointer for the Sidebar while a button is down, so a drag does not end here. A pointer that
-- leaves anyway cancels the drag.
function SidebarView:on_mouse_left()
  self.hover_x, self.hover_y = nil, nil
  self.scroll_drag, self.click_row, self.press, self.selecting = nil, nil, nil, nil
  if self.drag then self:end_drag(nil) end
  return self:update_hover()
end

-- The pointer's cursor: a hand over rows that act on a click.
function SidebarView:pointer_cursor()
  if self.drag or self.scroll_drag or not self.hover_x then return "arrow" end
  if self.selecting or self:in_search(self.hover_x, self.hover_y) then return "ibeam" end
  if self.press then return "hand" end
  if self:scrollbar_at(self.hover_x, self.hover_y) then return "arrow" end
  return self.hover and "hand" or "arrow"
end

------------------------------------------------------------------------------------------------------------------
-- Drag and drop

-- Whether a Project takes a dragged Tab from `source`, or a drop from another application when `source` is nil.
local function accepts(project, source)
  if project.state == "failed" or project.state == "closing" then return false end
  if project.state == "dormant" and not project.exists then return false end
  if not source or source.project.path == project.path then return true end
  -- A Terminal Session belongs to its Project.
  return not source.tab.terminal
end

-- The Tab next to `row` in its Project, one row up or down.
function SidebarView:neighbor(row, direction)
  local _, index = self:row_by_key(row.id_key)
  local next = index and self.rows[index + direction]
  return next and next.kind == "tab" and next.project.path == row.project.path and next or nil
end

-- Whether placing the dragged Tab `source` beside `anchor` leaves its Project's layout as it is.
function SidebarView:unchanged(source, place, anchor)
  if anchor.project.path ~= source.project.path then return false end
  local single = not source.bracket
  if anchor.id_key == source.id_key then return place.mode == "join" or single end
  local group, own = anchor.tab.group, source.tab.group
  if place.mode == "join" then
    local next = group == own and self:neighbor(anchor, place.side == "after" and 1 or -1)
    return next and next.id_key == source.id_key or false
  end
  return single and (place.side == "after" and group == own - 1 or place.side == "before" and group == own + 1)
end

-- A line beside a Tab. Inside a Pane Group with several Panes the new Pane joins it, except on the group's outer
-- edge, where `outer` places a new group beside it.
function SidebarView:line_target(row, side, outer, source)
  local bracket = row.bracket
  local edge = bracket and (side == "before" and bracket.first or side == "after" and bracket.last)
  local join = bracket and not (outer and edge) or false
  local place = {mode = join and "join" or "group", anchor = row.tab.id, side = side}
  if source and self:unchanged(source, place, row) then return nil end
  return {kind = "line", row = row, project = row.project, place = place, inset = join, area = row.area,
    y = side == "before" and row.y or row.y + row.h}
end

-- The drop target at a point: a line between Tabs, or a row. `source` is the dragged Tab's row, or nil for a drop
-- from another application.
function SidebarView:drop_target_at(x, y, source)
  if not x or x < 0 or x >= self.width then return nil end
  local row, index = self:row_at(y)
  -- Search hides Tabs, so a line between the shown ones has no clear place.
  local lines = self.query == ""
  if not row then
    -- Just below a Project's last Tab: in the gap before the next Project, or below the list.
    local above = lines and self:tab_above(y)
    if not above or not accepts(above.project, source) then return nil end
    return self:line_target(above, "after", true, source)
  end
  if not row.project or not accepts(row.project, source) then return nil end
  local part = (y - self:row_y(index)) / row.h
  if row.kind == "project" then
    local first = self.rows[index + 1]
    if lines and part > 1 - EDGE and first and first.kind == "tab" and first.project == row.project then
      return self:line_target(first, "before", true, source)
    end
    if source and row.project.path == source.project.path then return nil end
    return {kind = "row", row = row, project = row.project, place = {mode = "group"}}
  end
  if row.kind ~= "tab" then return nil end
  if part < EDGE or part > 1 - EDGE then
    if not lines then return nil end
    return self:line_target(row, part < EDGE and "before" or "after", part < OUTER_EDGE or part > 1 - OUTER_EDGE,
      source)
  end
  if not source then return {kind = "row", row = row, project = row.project, pane = row.tab.id} end
  -- A Tab dropped on another Tab joins its Pane Group after it.
  local place = {mode = "join", anchor = row.tab.id, side = "after"}
  if self:unchanged(source, place, row) then return nil end
  return {kind = "row", row = row, project = row.project, place = place}
end

-- The Tab row that ends at most one Tab's height above `y` in the main list, when no row is between them.
function SidebarView:tab_above(y)
  if y < self:list_top() or y >= self:main_bottom() then return nil end
  local above, bottom
  for index, row in ipairs(self.rows) do
    local row_bottom = row.area == "main" and self:row_y(index) + row.h
    if row_bottom and row_bottom <= y and (not bottom or row_bottom > bottom) then above, bottom = row, row_bottom end
  end
  if above and above.kind == "tab" and y - bottom < self:metrics().terminal then return above end
end

-- The route, Project path and request for a drop. A Tab moves inside its Project, or its Project exports it to the
-- target Project. A drop from another application opens its files and text there, or goes into a Tab's Pane.
function SidebarView:drop_request(target, source, files, text)
  local path = target.project.path
  if source then
    local from = source.project.path
    if path == from then return "direct", from, {action = "move", pane = source.tab.id, target = target.place} end
    self.transfers = (self.transfers or 0) + 1
    return "direct", from, {action = "export", pane = source.tab.id, to = path, target = target.place,
      transfer = string.format("%d-%d-%d", self.window_id or 0, os.time(), self.transfers)}
  end
  files = files and #files > 0 and files or nil
  text = text ~= "" and text or nil
  if target.pane then return "select", path, {action = "drop", pane = target.pane, files = files, text = text} end
  return "select", path, {action = "open", files = files, text = text, target = target.place}
end

function SidebarView:drop_target()
  return self.drag and self.drag.target or self.external and self.external.target or nil
end

function SidebarView:update_drag()
  local drag = self.drag
  local row = self:row_by_key(drag.key)
  -- The Pane closed during the drag.
  if not row then self:end_drag(nil); return end
  drag.row = row
  drag.target = drag.x and self:drop_target_at(drag.x, drag.y, row) or nil
end

-- A Tab row's rectangle with its top at y.
function SidebarView:card_slot(row, y)
  local m = self:metrics()
  return {x = m.tab_left, y = y, w = self.width - m.pad - m.tab_left, h = row.h}
end

-- The dragged Tab's chip: below and right of the pointer, so the drop mark under the pointer stays visible.
function SidebarView:card_chip(drag)
  local m = self:metrics()
  local w = math.min(self.width - 2 * m.pad, m.tab_x - m.tab_left + tab.width(drag.row.tab, m.terminal) + 10 * SCALE)
  return {x = common.clamp(drag.x + 12 * SCALE, m.pad, self.width - m.pad - w), y = drag.y + 10 * SCALE,
    w = w, h = m.terminal}
end

-- The card's rectangle now. During a drag it shrinks from its row into the chip as it lifts.
function SidebarView:card_rect(drag)
  local card = self.card
  if not drag then return card.rect end
  if not drag.x then return card.from end
  local from, to, t = card.from, self:card_chip(drag), card.lift
  local rect = {}
  for key, value in pairs(from) do rect[key] = value + (to[key] - value) * t end
  return rect
end

-- Right of the Sidebar the drag goes on over the Selected Project's work area. That Project shows its Pane drop
-- overlay there and splits or swaps on the drop. A press on a Tab selects its Project, so the Tab is there.
-- Returns true when the Tab dropped there.
function SidebarView:send_work(phase)
  local drag = self.drag
  local over = drag.x and drag.x >= self.width
  if not over and not drag.work then return false end
  if not over then phase = "leave" end
  drag.work = phase == "move"
  self.action("request", "pointer", nil, {action = "drag", phase = phase, source = drag.row.project.path,
    pane = drag.row.tab.id}, math.floor(drag.x or -1), math.floor(drag.y or -1))
  return phase == "drop"
end

-- Ends the drag. The card grows back into a row at the target, or at its own row, and fades.
function SidebarView:end_drag(target)
  local drag, card = self.drag, self.card
  if drag.work then self:send_work("leave") end
  self.drag = nil
  if not card then return end
  if config.transitions == false or not drag.x then self.card = nil; return end
  card.rect = self:card_rect(drag)
  local row, y = drag.row
  local _, index = self:row_by_key(target and target.row.id_key or row.id_key)
  if target and target.kind == "line" then
    y = self:area_origin(target.area) + target.y - row.h / 2
  elseif index then
    y = self:row_y(index)
  end
  card.to = y and self:card_slot(row, y) or card.rect
  card.dropped = target ~= nil
end

function SidebarView:finish_drag(x, y)
  local drag = self.drag
  drag.x, drag.y = x, y
  self:update_drag()
  if not self.drag then return end
  if self:send_work("drop") then
    self.drag, self.card = nil, nil
    return
  end
  local target, source = drag.target, drag.row
  self:end_drag(target)
  if not target then return end
  local route, path, request = self:drop_request(target, source)
  local transfer = request.action == "export"
  self.pending = {key = source.id_key, transfer = transfer,
    deadline = system.get_time() + (transfer and PENDING_TRANSFER or PENDING_MOVE)}
  self.action("request", route, path, request)
end

-- A drop from another application. The shell sends a position of -1, -1 when it leaves the Sidebar.
function SidebarView:on_drop_begin()
  self.external = {files = {}, seen = {}, text = {}}
end

function SidebarView:on_drop_moved(x, y)
  if not self.external then self:on_drop_begin() end
  local drop = self.external
  if x and y and x >= 0 and y >= 0 then drop.x, drop.y = x, y else drop.x, drop.y = nil, nil end
  drop.target = drop.x and self:drop_target_at(drop.x, drop.y) or nil
end

function SidebarView:on_file_dropped(path, x, y)
  self:on_drop_moved(x, y)
  local drop = self.external
  if not drop.seen[path] then
    drop.seen[path] = true
    drop.files[#drop.files + 1] = path
  end
end

function SidebarView:on_text_dropped(text, x, y)
  self:on_drop_moved(x, y)
  local parts = self.external.text
  parts[#parts + 1] = text
end

-- Sends the completed drop to its target. Returns true when a target took it.
function SidebarView:on_drop_complete()
  local drop = self.external
  self.external = nil
  local target = drop and drop.x and self:drop_target_at(drop.x, drop.y)
  if not target then return false end
  local text = table.concat(drop.text):gsub("\r\n", "\n"):gsub("\r", "\n")
  if #drop.files == 0 and text == "" then return false end
  self.action("request", self:drop_request(target, nil, drop.files, text))
  return true
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
  if self.drag then self:update_drag() end
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
  if self.chosen and system.get_time() >= self.chosen.deadline then
    self.chosen = nil
    self:rebuild_rows()
  end
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
  -- A drag near an area's edge scrolls it. The list follows at once, so the target stays under the pointer.
  local drag = self.drag
  if drag and drag.x and drag.x >= 0 and drag.x < self.width and dt > 0 then
    local field, speed = self:autoscroll_speed(drag.y)
    local before = field and self[field]
    if field then
      self[field] = before + speed * dt
      self:clamp_scroll()
    end
    if field and self[field] ~= before then
      shown[field] = self[field]
      self:update_drag()
      moving = true
    end
  end
  local card = self.card
  if card and self.drag then
    card.lift = ease(card.lift, 1, FADE_RATE, 0.01)
    card.alpha = ease(card.alpha, self.drag.work and 0 or 1, FADE_RATE, 0.02)
  elseif card then
    for key, value in pairs(card.to) do card.rect[key] = ease(card.rect[key], value, MOVE_RATE) end
    card.lift = ease(card.lift, 0, FADE_RATE, 0.01)
    card.alpha = ease(card.alpha, 0, card.dropped and FADE_RATE or FADE_RATE * 0.6, 0.02)
    if card.alpha <= 0 then self.card = nil end
  end
  -- The rows beside a drop line part a little.
  local target, nudge = self:drop_target(), {}
  if target and target.kind == "line" and config.transitions ~= false then
    for _, row in ipairs(self.rows) do
      if row.area == target.area then
        if row.y + row.h == target.y then nudge[row.id_key] = -2 * SCALE
        elseif row.y == target.y then nudge[row.id_key] = 2 * SCALE end
      end
    end
  end
  shown.scroll = ease(shown.scroll, self.scroll, SCROLL_RATE)
  shown.bottom_scroll = ease(shown.bottom_scroll, self.bottom_scroll, SCROLL_RATE)
  shown.search = ease(shown.search, self:search_open() and 1 or 0, SEARCH_RATE, 0.01)
  -- Rows. A new row unfolds from the row above it, which already showed. A row that leaves fades where it was.
  local old, visuals = self.visuals, {}
  local unfold = {}
  for _, row in ipairs(self.rows) do
    local key, before = row.id_key, old[row.id_key]
    local visual
    local dim = self:dim_target(row)
    if before and before.area == row.area then
      visual = {area = row.area, y = ease(before.y, row.y + (nudge[key] or 0), MOVE_RATE * ROW_SPEED),
        alpha = ease(before.alpha, 1, FADE_RATE * ROW_SPEED, 0.01), dim = ease(before.dim, dim, FADE_RATE * 1.5, 0.01)}
    elseif animate then
      local start = unfold[row.area]
      visual = {area = row.area, y = start or row.y, alpha = 0, dim = dim}
      moving = true
    else
      visual = {area = row.area, y = row.y, alpha = 1, dim = dim}
    end
    if before and before.area == row.area then unfold[row.area] = before.y + row.h end
    visuals[key] = visual
    row.shown = visual
  end
  local leaving = {}
  for _, item in ipairs(self.leaving) do
    if not visuals[item.row.id_key] then
      item.alpha = ease(item.alpha, 0, FADE_RATE * 1.8 * ROW_SPEED, 0.02)
      if item.alpha > 0 then leaving[#leaving + 1] = item end
    end
  end
  if animate then
    for key, visual in pairs(old) do
      if not visuals[key] and visual.row and visual.alpha > 0.05 then
        leaving[#leaving + 1] = {row = visual.row, area = visual.area, y = visual.y, alpha = visual.alpha * visual.dim}
        moving = true
      end
    end
  end
  for _, row in ipairs(self.rows) do visuals[row.id_key].row = row end
  self.visuals, self.leaving = visuals, leaving
  -- A moved Tab's old row stays dim until its Project reports the result or the row leaves.
  local pending = self.pending
  if pending and (not visuals[pending.key] or system.get_time() >= pending.deadline) then
    self.pending, moving = nil, true
  end
  -- Highlights glide from row to row and fade where no row takes them.
  local m = self:metrics()
  local function mark(name, row, speed)
    local move, fade_rate = MARK_MOVE_RATE * speed, MARK_FADE_RATE * speed
    local current = self.marks[name]
    if not row or not row.shown then
      if current then
        current.alpha = ease(current.alpha, 0, fade_rate, 0.01)
        if current.alpha <= 0 then self.marks[name] = nil end
      end
      return
    end
    local x = (row.kind == "project" or row.kind == "group" or row.kind == "empty") and m.pad or m.tab_left
    if not current or current.area ~= row.area or current.alpha <= 0.01 then
      self.marks[name] = {area = row.area, x = x, y = row.shown.y, h = row.h, alpha = ease(0, 1, fade_rate, 0.01)}
      return
    end
    current.x = ease(current.x, x, move)
    current.y = ease(current.y, row.shown.y, move)
    current.h = ease(current.h, row.h, move)
    current.alpha = ease(current.alpha, 1, fade_rate, 0.01)
  end
  local active
  for _, row in ipairs(self.rows) do
    if row.selected then active = row; break end
  end
  mark("active", active, SELECTION_SPEED)
  mark("cursor", self.focused and self:get_cursor() or nil, SELECTION_SPEED)
  mark("hover", self.hover, HOVER_SPEED)
  -- The drop target's mark: a line between rows that grows into a box around a target row.
  local drop = self.marks.drop
  if target then
    local area, x, right, y, h, box = target.row.area
    if target.kind == "line" then
      local line = math.max(2, math.floor(2 * SCALE))
      x = target.inset and m.tab_x or m.tab_left
      right = self.width - m.pad - (target.inset and 4 * SCALE or 0)
      y, h, box = target.y - line / 2, line, 0
    else
      x = target.row.kind == "project" and m.pad or m.tab_left
      right = self.width - m.pad
      y, h, box = target.row.y, target.row.h, 1
    end
    if not drop or drop.area ~= area or drop.alpha <= 0.01 then
      self.marks.drop = {area = area, x = x, w = right - x, y = y, h = h, box = box,
        alpha = ease(0, 1, FADE_RATE * 1.5, 0.01)}
    else
      local rate = MOVE_RATE * 1.6
      drop.x, drop.w = ease(drop.x, x, rate), ease(drop.w, right - x, rate)
      drop.y, drop.h = ease(drop.y, y, rate), ease(drop.h, h, rate)
      drop.box = ease(drop.box, box, rate, 0.01)
      drop.alpha = ease(drop.alpha, 1, FADE_RATE * 1.5, 0.01)
    end
  elseif drop then
    drop.alpha = ease(drop.alpha, 0, FADE_RATE * 1.5, 0.01)
    if drop.alpha <= 0 then self.marks.drop = nil end
  end
  for _, row in ipairs(self.rows) do
    if row.key then
      local target = row.collapsed and 0 or 1
      self.chevrons[row.key] = ease(self.chevrons[row.key], target, MOVE_RATE * 0.8, 0.01)
    end
  end
  return moving
end

-- The area to scroll for a drag at `y`, and the speed in pixels per second: faster as the pointer goes deeper into
-- the edge zone. Nil when `y` is not near an edge.
function SidebarView:autoscroll_speed(y)
  local m = self:metrics()
  local zone = SCROLL_ZONE * SCALE
  local function speed(depth) return SCROLL_SPEED * SCALE * math.min(1, depth / zone) ^ 2 end
  local bottom_top, bottom_height = self:bottom_area()
  if bottom_height <= 0 or y < bottom_top - m.gap / 2 then
    local main_bottom = self:main_bottom()
    local top = self:list_top()
    if y < top + zone then return "scroll", -speed(top + zone - y) end
    if y > main_bottom - zone then return "scroll", speed(y - main_bottom + zone) end
    return
  end
  if y < bottom_top + zone then return "bottom_scroll", -speed(bottom_top + zone - y) end
  if y > self.view_h - zone then return "bottom_scroll", speed(y - self.view_h + zone) end
end

-- Other Windows' Projects and their children stay dim. A dragged or moved Tab dims further at its old place.
function SidebarView:dim_target(row)
  local key = row.id_key
  local drag, pending = self.drag, self.pending
  if drag and drag.key == key or pending and pending.key == key then return 0.35 end
  local owner = row.project and row.project.window_id
  if self.window_id and owner and owner ~= 0 and owner ~= self.window_id then return 0.7 end
  return 1
end

-- The top of the list on screen, as the search field opens or closes.
function SidebarView:shown_list_top()
  local m = self:metrics()
  local open = (self.shown or {}).search or (self:search_open() and 1 or 0)
  return m.top + open * m.search_space
end

-- The top of a row's area on screen, at the shown scroll.
function SidebarView:shown_origin(area)
  local shown = self.shown or {}
  if area == "bottom" then return self:area_origin(area, shown.bottom_scroll) end
  return self:shown_list_top() - (shown.scroll or self.scroll)
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

-- An outline `stroke` wide along a rounded rectangle's edge. One polygon with a seam draws it, so it needs no fill
-- below it and shows on a transparent surface too.
local function ring(x, y, w, h, radius, stroke, color)
  local r = math.min(radius, w / 2, h / 2)
  local ix, iy, iw, ih = x + stroke, y + stroke, w - 2 * stroke, h - 2 * stroke
  local ir = math.max(0, r - stroke)
  renderer.draw_poly({
    {x, y + r, x, y, x + r, y},
    {x + w - r, y, x + w, y, x + w, y + r},
    {x + w, y + h - r, x + w, y + h, x + w - r, y + h},
    {x + r, y + h, x, y + h, x, y + h - r},
    {x, y + r},
    {ix, iy + ir},
    {ix, iy + ih - ir, ix, iy + ih, ix + ir, iy + ih},
    {ix + iw - ir, iy + ih, ix + iw, iy + ih, ix + iw, iy + ih - ir},
    {ix + iw, iy + ir, ix + iw, iy, ix + iw - ir, iy},
    {ix + ir, iy, ix, iy, ix, iy + ir},
  }, color)
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
    elseif name == "number" then fonts[name] = base:copy(math.floor(size * 1.2 + 0.5))
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
  if self.shimmer_delay then delay = math.min(delay or math.huge, self.shimmer_delay) end
  if self.animating or self.focus_feedback:active(clock) then delay = math.min(delay or math.huge, FRAME) end
  if self.ticking then delay = math.min(delay or 1, 1 - clock % 1) end
  if self.tooltip_text then
    local remaining = TOOLTIP_DELAY - (clock - self.tooltip_started)
    if remaining > 0 then delay = math.min(delay or remaining, remaining) end
  end
  if self.pending then delay = math.min(delay or math.huge, math.max(0, self.pending.deadline - clock)) end
  if self.chosen then delay = math.min(delay or math.huge, math.max(0, self.chosen.deadline - clock)) end
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
      elseif tab.working(tab.describe_session(terminal).terminal, agent) then
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
  -- Keep the badge dim, including for the Window's Selected Project.
  local size = m.badge
  local bx, by = left + 6 * SCALE, math.floor(cy - size / 2)
  local color = badge_color(name)
  local strength = dormant and 0.55 or 1
  local radius = math.floor(size * 0.3)
  local bold = font_variant("bold")
  local letter = initial(name)
  local letter_color = tint(color, 255 * strength)
  renderer.draw_rounded_rect(bx, by, size, size, radius, tint(color, 64 * strength))
  -- The letter's ink centres in the badge. Its line box has room for descenders, so centring the line would put a
  -- capital too high.
  local ink_top, ink_bottom = bold:get_ink_extent(letter)
  local ly = ink_top and by + (size - ink_top - ink_bottom) / 2 or by + (size - bold:get_height()) / 2
  text(letter, bx + math.floor((size - bold:get_width(letter)) / 2), math.floor(ly + 0.5), letter_color, bold)
  local status, note = project_status(project)
  if status then
    -- A ring in the panel's colour separates the dot from the badge.
    dot(bx + size - SCALE, by + size - SCALE, 5 * SCALE, style.background2)
    dot(bx + size - SCALE, by + size - SCALE, 3.5 * SCALE, status)
  end
  -- The chevron keeps its space, so the note does not move when it shows.
  if row.key and self.query == "" then
    local shows = row.collapsed or self.hover == row or self.focused and self:get_cursor() == row
    local hovered = self.arrow_hover == row
    if hovered then
      renderer.draw_rounded_rect(width - 32 * SCALE, y + 1, 32 * SCALE - m.pad, row.h - 2,
        m.radius, style.sidebar_hover)
    end
    if shows then chevron(right - 12 * SCALE, cy, self.chevrons[row.key], hovered and style.text or style.dim) end
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
    if row.attention then self:draw_attention(row, y, width) end
    local x, tab_width = self:tab_bounds(row, width)
    self:draw_tab(row, x, y, tab_width, now)
    return
  end
  self:draw_project(row, y, width, now)
end

-- The phase of the shimmer through a working Terminal's status text, from 0 to 1, or nil while the light rests.
function SidebarView:shimmer_phase()
  if config.transitions == false then return nil end
  local progress = (self.clock % SHIMMER_PERIOD) / SHIMMER_TRAVEL
  -- The next frame comes soon while the light moves, or when the next pass starts.
  local wait = progress < 1 and SHIMMER_FRAME or SHIMMER_PERIOD - self.clock % SHIMMER_PERIOD
  self.shimmer_delay = math.min(self.shimmer_delay or wait, wait)
  return progress < 1 and progress or nil
end

-- The strength of a pending row's tint at its left edge, and the part of the row that the tint fades out over.
local ATTENTION_TINT, ATTENTION_SPAN = 0.14, 0.6

-- A Terminal that needs the user: a bar in its attention colour at the row's left edge, and a tint of that colour
-- that fades out to the right. The renderer has no gradients, so thin strips with a falling alpha draw the fade.
function SidebarView:draw_attention(row, y, width)
  local m = self:metrics()
  local color = tab.attention_color(row.attention)
  local x, h = m.rail_x + m.rail, row.h - 2
  local span = (width - m.pad - x) * ATTENTION_SPAN
  local step = math.max(1, math.floor(3 * SCALE))
  for offset = 0, span - 1, step do
    local strength = 1 - offset / span
    renderer.draw_rect(x + offset, y + 1, math.min(step, span - offset), h,
      fade(color, ATTENTION_TINT * strength * strength))
  end
  renderer.draw_rounded_rect(m.rail_x, y + 1, m.rail, h, m.rail / 2, color)
end

-- A Tab's or Terminal Session's content in [x, x + width): its icon, name and status, and an agent's step below.
function SidebarView:draw_tab(row, x, y, width, now)
  local m = self:metrics()
  -- A working Terminal shimmers its agent's line, or its name when it has no such line.
  local shimmer = tab.working(row.tab.terminal or {}, row.agent) and self:shimmer_phase() or nil
  -- A Terminal that needs the user has a dot at the right edge of its name's line and a bold name.
  local name_font, right = nil, x + width
  if row.attention then
    local radius = 3 * SCALE
    dot(x + width - radius, y + m.terminal / 2, radius, tab.attention_color(row.attention))
    width = width - radius * 2 - 6 * SCALE
    name_font = font_variant("bold")
  end
  local spinning, name_x = tab.draw(row.tab, x, y, width, m.terminal, {name_color = style.text, now = now,
    clock = self.clock, name_font = name_font, number_font = font_variant("number"), number_gutter = m.number_gutter, shimmer = not row.agent and shimmer or nil})
  if spinning then self.spinning = true end
  local unread = row.attention == "done" or row.attention == "error"
  if row.agent and tab.draw_agent(row.agent, name_x, y + m.terminal - 6 * SCALE, right - name_x,
      m.terminal, {now = now, unread = unread, shimmer = shimmer}) then
    self.ticking = true
  end
end

-- Pane Groups with several Panes: a rail beside their Tabs, in the accent colour for the visible group. A drop line
-- inside a group tints its Tabs: the new Pane joins that group.
function SidebarView:draw_containers(area, width)
  local m = self:metrics()
  local origin = self:shown_origin(area)
  local drop, mark = self:drop_target(), self.marks.drop
  local join = drop and drop.kind == "line" and drop.inset and mark and drop.row.id_key
  local first, joined
  for _, row in ipairs(self.rows) do
    if row.area == area and row.bracket and row.shown then
      if row.bracket.first or not first then first, joined = row, false end
      joined = joined or row.id_key == join
      if row.bracket.last then
        local top = origin + first.shown.y
        local bottom = origin + row.shown.y + row.h
        local alpha = math.min(first.shown.alpha * first.shown.dim, row.shown.alpha * row.shown.dim)
        local x, w = m.tab_left, width - m.pad - m.tab_left
        if joined then
          renderer.draw_rounded_rect(x, top + 1, w, bottom - top - 2, m.radius,
            fade(style.drop_target_background, alpha * mark.alpha))
        end
        renderer.draw_rect(m.rail_x, top + 6 * SCALE, m.rail, bottom - top - 12 * SCALE,
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

-- The drop target's mark. Below the rows: the box's fill. Above them: the line, or the box's outline.
function SidebarView:draw_drop(area, above)
  local mark = self.marks.drop
  if not mark or mark.area ~= area or mark.alpha <= 0.01 then return end
  local m = self:metrics()
  local x, y, w, h = mark.x, self:shown_origin(area) + mark.y, mark.w, mark.h
  if not above then
    if mark.box > 0.01 then
      renderer.draw_rounded_rect(x, y + 1, w, h - 2, m.radius, fade(style.drop_target_background, mark.alpha * mark.box))
    end
    return
  end
  local color = fade(style.drop_target_accent, mark.alpha)
  local stroke = math.max(1, math.floor(1.5 * SCALE + 0.5))
  if h - 2 > 3 * stroke then
    ring(x, y + 1, w, h - 2, m.radius, stroke, color)
  else
    renderer.draw_rounded_rect(x, y, w, h, h / 2, color)
  end
  -- A line starts with a dot.
  if mark.box < 0.99 then
    local radius = 3 * SCALE
    dot(x + radius, y + h / 2, radius, fade(style.drop_target_accent, mark.alpha * (1 - mark.box)))
  end
end

-- The dragged Tab's card: a chip that follows the pointer while the drag lasts, then a row that glides to its
-- target and fades.
function SidebarView:draw_card(width, height, now)
  local card = self.card
  if not card then return end
  local m = self:metrics()
  local rect = self:card_rect(self.drag)
  local alpha, lift = card.alpha, card.lift
  local x, y = math.floor(rect.x + 0.5), math.floor(rect.y + 0.5)
  local w, h = math.floor(rect.w + 0.5), math.floor(rect.h + 0.5)
  -- A soft shadow that deepens as the card lifts.
  for i = 3, 1, -1 do
    local spread = i * SCALE
    renderer.draw_rounded_rect(x - spread, y - spread + 2 * SCALE * lift, w + 2 * spread, h + 2 * spread,
      m.radius + spread, fade(style.sidebar_shadow, alpha * lift * (4 - i) / 6))
  end
  local border = math.max(1, math.floor(SCALE))
  renderer.draw_rounded_rect(x - border, y - border, w + 2 * border, h + 2 * border, m.radius + border,
    fade(style.divider, alpha))
  renderer.draw_rounded_rect(x, y, w, h, m.radius, fade(style.sidebar_card, alpha))
  local tx = x + m.tab_x - m.tab_left
  renderer.set_clip_rect(x, y, w, h)
  if alpha < 0.999 then renderer.push_transform(0, 0, 1, alpha) end
  if tab.draw(card.row.tab, tx, y + math.floor((h - m.terminal) / 2), x + w - 8 * SCALE - tx, m.terminal,
      {name_color = style.text, now = now, clock = self.clock}) then
    self.spinning = true
  end
  if alpha < 0.999 then renderer.pop_transform() end
  renderer.set_clip_rect(0, 0, width, height)
end

-- The search field shows only while a query is typed. It grows in and fades as it opens, and keeps the last query
-- while it closes.
function SidebarView:draw_search(width, height)
  local open = self.shown.search
  local input = self.input
  if self:search_open() then self.shown_input = {text = input.text, caret = input.caret, anchor = input.anchor} end
  local shown = self.shown_input
  if open <= 0.01 or not shown then return end
  local m = self:metrics()
  local x, y, w, h = m.pad, m.search_y, self.width - 2 * m.pad, m.search
  local transformed = open < 0.999
  if transformed then renderer.push_transform(x + w / 2, y, 0.94 + 0.06 * open, open) end
  -- An input field with an accent outline.
  local border = math.max(1, math.floor(1.5 * SCALE + 0.5))
  renderer.draw_rounded_rect(x, y, w, h, m.radius, style.accent)
  renderer.draw_rounded_rect(x + border, y + border, w - 2 * border, h - 2 * border, m.radius - border,
    style.background)
  local icon = style.icon_font
  local ix = x + 8 * SCALE
  text("L", ix, y + math.floor((h - icon:get_height()) / 2), style.accent, icon)
  local tx, _, available = self:search_box()
  local font = style.font
  local ty = y + math.floor((h - font:get_height()) / 2)
  local caret_w = math.max(1, math.floor(1.5 * SCALE))
  -- The text scrolls as little as it can to keep the caret in view.
  local function offset_x(pos) return font:get_width(shown.text:sub(1, pos)) end
  local caret_x = offset_x(shown.caret)
  local scroll = math.min(self.search_scroll, math.max(0, offset_x(#shown.text) + SCALE + caret_w - available))
  scroll = math.max(0, math.min(caret_x, math.max(scroll, caret_x + SCALE + caret_w - available)))
  self.search_scroll = scroll
  renderer.set_clip_rect(tx, y, available, h)
  local first, last = math.min(shown.caret, shown.anchor), math.max(shown.caret, shown.anchor)
  if first ~= last then
    local left = offset_x(first)
    renderer.draw_rect(tx - scroll + left, ty, offset_x(last) - left, font:get_height(), style.selection)
  end
  text(shown.text, tx - scroll, ty, style.text)
  renderer.draw_rect(tx - scroll + caret_x + SCALE, ty, caret_w, font:get_height(), style.accent)
  renderer.set_clip_rect(0, 0, width, height)
  if transformed then renderer.pop_transform() end
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
  self.clock, self.last_clock, self.spinning, self.ticking, self.shimmer_delay = clock, clock, false, false, nil
  self.animating = self:step(dt)
  self.drawn = true
  renderer.set_clip_rect(0, 0, width, height)
  -- On a transparent surface the shell blends the panel over the Project's backdrop and wallpaper.
  renderer.draw_rect(0, 0, width, height,
    system.is_surface_transparent() and style.wallpaper_surface(style.background2) or style.background2)
  renderer.draw_rect(width - math.max(1, SCALE), 0, math.max(1, SCALE), height, style.divider)
  self:draw_search(width, height)
  local top, main_bottom = self:shown_list_top(), self:main_bottom()
  local bottom_top = self:bottom_area()
  local active_color = self.focused and style.row_selection_inactive or style.row_selection
  for _, area in ipairs({{"main", top, main_bottom}, {"bottom", bottom_top, height}}) do
    local name, area_top, area_bottom = area[1], area[2], area[3]
    renderer.set_clip_rect(0, area_top, width, math.max(0, area_bottom - area_top))
    self:draw_containers(name, width)
    self:draw_mark("hover", name, width, style.sidebar_hover)
    self:draw_mark("active", name, width, active_color)
    self:draw_mark("cursor", name, width, style.row_selection)
    self:draw_drop(name, false)
    local origin = self:shown_origin(name)
    for _, item in ipairs(self.leaving) do
      if item.area == name then self:draw_shown(item.row, origin + item.y, item.alpha, width, now) end
    end
    for _, row in ipairs(self.rows) do
      if row.area == name then
        local y = origin + row.shown.y
        if y + row.h > area_top and y < area_bottom then
          self:draw_shown(row, y, row.shown.alpha * row.shown.dim, width, now)
        end
      end
    end
    self:draw_drop(name, true)
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
  self:draw_card(width, height, now)
  self.focus_feedback:draw(0, 0, width, height, self.clock)
  self:draw_tooltip(width, height)
end

return SidebarView
