local Object = require "core.object"
local style = require "core.style"
local config = require "core.config"
local tab = require "core.tab"
local numbered_panes = require "core.numbered_panes"
local common = require "core.common"
local LineInput = require "core.line_input"
local FocusFeedback = require "core.focus_feedback"
local look = require "core.project_look"
local command = require "core.command"
local icons = require("core.context_menu").icons

-- The shell owns identity and lifecycle. This view sends only Project, Pane and Terminal Session actions.
-- A right-click on a Project or a Terminal Tab, or the Context Menu key on the cursor's row, opens that row's
-- Context Menu. The menu can extend over the Project, because the Sidebar's surface covers the whole Window.
-- A click on a loaded Project in this Window toggles its children. An empty Project opens its initial Pane.
-- Dormant Projects and Projects in other Windows open on click. Project clicks act at the release, because a press
-- on a loaded Project can start a drag that reorders the loaded Projects. See "Project reorder".
-- Left on a collapsed loaded Project asks to unload it. A second Left unloads it; any other input cancels.
-- Layout: a search field below the window caption, then the main list: the Scratch Project's section in every Window,
-- then loaded Projects with their Tabs, one for each Pane, and the Terminal Sessions that no Pane shows.
-- Other Windows' Projects sit above the unloaded Projects'
-- collapsible age groups at the bottom. This area takes at most part of the height and scrolls on its own.
-- Unloaded Project rows count their running Terminal Sessions.
-- Each area that overflows shows a scrollbar; its thumb drags and its track pages.
-- Inside a Project, older Terminal Sessions fold into collapsible groups the same way.
-- Rows keep the shell's order. Age only chooses a row's group, so rows never swap places under the pointer.
-- The shell saves that order, so it stays after a restart.
-- Rows, highlights, chevrons and scrolling animate toward the layout. Hit testing uses the layout itself, so a
-- click acts on the row that moves to the pointer.
-- Drag and drop: a dragged Tab or a drop from another application lands on a line between Tabs, which places a new
-- Pane there, or on a row. A Tab's middle takes the drop into its Pane; a Project's row takes it into that Project.
-- The Snoozed fold takes a drop after the Project's other Tabs. A dropped Snoozed Tab wakes.
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
-- Left on a collapsed loaded Project asks "Unload?" for this long. A second Left unloads it.
local UNLOAD_TIMEOUT = 3
-- Cursor moves closer together than this show only the row where the cursor rests, so a held key does not load each
-- row it passes.
local PEEK_DELAY = 0.09
-- A Project id that names no loaded Project: the shell shows a row without content.
local PEEK_NO_CONTENT = 0xffffffff
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
local SHIMMER_TRAVEL, SHIMMER_PERIOD, SHIMMER_FRAME = 1.3, 1.3, 1 / 30
-- The longest step between two frames. After a pause, an animation starts where it stopped.
local MAX_STEP = 1 / 30
local FRAME = 1 / 120

local DAY = 24 * 60 * 60
local WEEK, MONTH = 7 * DAY, 30 * DAY
-- The groups. Each starts open or collapsed as given here unless saved otherwise. Unloaded Projects use every
-- group; a loaded Project's older Terminal Sessions use the groups with a terminal label.
local GROUPS = {
  {bucket = "week", label = "Last week", collapsed = true},
  {bucket = "month", label = "Last month", terminal_label = "Older than a week", collapsed = true},
  {bucket = "older", label = "Older", terminal_label = "Older than a month", collapsed = true},
}
-- The groups take at most this part of the height below the list top, and at most this many Project rows.
local GROUPS_HEIGHT = 0.5
local GROUPS_ROWS = 16

---@param action fun(name: string, ...)
---@param collapsed table<string, boolean>? This Window's saved folding state.
---@param restore_folds boolean? Restore saved folds on first selection.
---@param snoozes table<string, number>? The Snooze time of each Terminal Session, by its ID.
---@param snooze_spans table<string, {from: number, to: number}>? The start and end of each Terminal Session's last
---Snooze, by its ID, until the Terminal gets new work after it.
function SidebarView:new(action, collapsed, seen, restore_folds, snoozes, snooze_spans)
  self.action, self.rows, self.scroll, self.bottom_scroll = action, {}, 0, 0
  self.collapsed = collapsed or {}
  self.restore_folds = restore_folds == true
  -- When the user last looked at each Terminal Session, by its ID. Every surface shares it.
  self.seen = seen or {}
  -- Every surface shares the Snoozes too.
  self.snoozes = snoozes or {}
  self.snooze_spans = snooze_spans or {}
  -- The Projects selected at the last layout.
  self.was_selected = {}
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
    project_gap = 18 * SCALE,
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

-- Scrolls the row's area as little as it can to show the row, with `margin` free space beside it.
function SidebarView:reveal_row(index, margin)
  local row = self.rows[index]
  if not row then return end
  margin = margin or 0
  local field = row.area == "main" and "scroll" or "bottom_scroll"
  local top = row.area == "main" and self:list_top() or self:bottom_area()
  local bottom = row.area == "main" and self:main_bottom() or self.view_h
  local y, before = self:row_y(index), self[field]
  if y - margin < top then self[field] = self[field] + y - margin - top
  elseif y + row.h + margin > bottom then self[field] = self[field] + y + row.h + margin - bottom end
  self:clamp_scroll()
  if self[field] ~= before and self.hover_y then self:update_hover() end
end

function SidebarView:reveal_cursor()
  self:reveal_row(self.cursor)
end

function SidebarView:reset_cursor_to_selection()
  for index, row in ipairs(self.rows) do
    if row.selected then self.cursor = index; break end
  end
  self:reveal_cursor()
end

function SidebarView:on_focus(focused, refresh_pending)
  self.focused, self.unload_ask = focused, nil
  -- The shell ends a Peek when the Sidebar loses the keyboard.
  self.peek_wanted, self.peek_sent = nil, nil
  -- A hidden Sidebar can still hold the previous Pane report when it gets the keyboard.
  self.focus_pending = focused and refresh_pending or nil
  -- The hours field asks for the keyboard and waits for it. It closes when the Sidebar loses the keyboard.
  if not focused then self.hours = nil end
  self.focus_feedback:update(focused and self or nil)
  self.input:set_text("")
  self.query, self.cursor, self.selecting = "", nil, nil
  self:rebuild_rows()
  if focused then self:reset_cursor_to_selection() end
end

-- Filters the list again after the search field's text changed.
function SidebarView:input_changed()
  if self.input.text == self.query then return end
  self.focus_pending = nil
  self.query, self.cursor = self.input.text, nil
  self:rebuild_rows()
end

function SidebarView:on_text_input(text)
  if not self.focused then return end
  self.unload_ask = nil
  if self.hours then
    -- The hours field takes whole hours only.
    self.hours.input:insert((text:gsub("%D", "")))
    return
  end
  self.input:insert(text)
  self:input_changed()
end

-- The field that takes the keyboard's text: the hours field while it is open, or else the search field.
function SidebarView:field()
  return self.hours and self.hours.input or self.input
end

-- Whether the line command `name` edits a field: the hours field, the search field while it has a query, or a
-- paste that starts a query.
function SidebarView:edits(name)
  return self.focused == true and (self.hours ~= nil or self.query ~= "" or name == "paste")
end

-- Performs the editor's line command `name` in the field, such as "select_to_previous_word_start". Without a
-- query it returns false, so the same keys move through the list.
function SidebarView:edit(name)
  if not self:edits(name) then return false end
  local input = self:field()
  if not input:perform(name) then return false end
  self.unload_ask = nil
  if self.hours then
    input:set_text((input.text:gsub("%D", "")))
  else
    self:input_changed()
  end
  return true
end

-- The Terminal menu's Snooze times, in hours.
local SNOOZE_HOURS = {0.5, 1, 2, 3, 4, 12, 24}

-- The Context Menu commands. Each takes the Sidebar View first, so the command list never offers them alone.
command.add(function(view, ...)
  return SidebarView:is_class_of(view), view, ...
end, {
  ["sidebar:snooze"] = function(view, target, hours) view:set_snooze(target, hours) end,
  ["sidebar:snooze_custom"] = function(view, target) view:ask_snooze_hours(target) end,
  ["sidebar:remove_snooze"] = function(view, target) view:set_snooze(target, nil) end,
  ["sidebar:mark_read"] = function(view, item, session)
    view:look(item, session, os.time())
    view:rebuild_rows()
  end,
  -- These show their Project, so the user sees the new Pane or an unsaved-file question.
  ["sidebar:perform"] = function(view, path, name, pane)
    view.action("request", "select", path, {action = "perform", command = name, pane = pane})
  end,
  ["sidebar:close_pane"] = function(view, path, pane)
    view.action("request", "select", path, {action = "close", pane = pane})
  end,
  ["sidebar:move_project"] = function(view, project, window_id) view.action("move", project.row_id, window_id) end,
  ["sidebar:open_project_window"] = function(view, project) view.action("open_window", project.row_id) end,
  ["sidebar:unload_project"] = function(view, project) view.action("unload", project.row_id) end,
  ["sidebar:copy_project_path"] = function(view, project) view.action("copy_path", project.row_id) end,
  ["sidebar:copy_agent_address"] = function(_, path, pane, session)
    system.set_clipboard(require("core.json").encode({project = path, pane = pane, terminal = session}))
  end,
  ["sidebar:show_project_in_folder"] = function(view, project) view.action("show_in_folder", project.row_id) end,
})

-- The Context Menu items of a row. A Project has New Terminal and New Pi. While it is loaded, it also has Reopen
-- Closed Pane, Move and Unload, or else Open in New Window. The Scratch Project's folder holds no work, and it follows
-- the user, so it has no folder or Window actions. A Tab has Duplicate and Close, and a Terminal Tab also
-- has Snooze times. A running Pi Tab also has Copy Agent Address. Other rows have no menu.
function SidebarView:context_menu(row)
  if row.kind == "tab" then
    local path, pane, items = row.project.path, row.tab.id, {}
    if row.tab.terminal then
      local target = {session = row.tab.terminal.session, pane = pane, path = path}
      if row.tab.terminal.state == "running" and row.tab.terminal.app == "pi" and target.session then
        items[#items + 1] = {label = "Copy Agent Address", icon = icons.path, command = "sidebar:copy_agent_address",
          args = {self, path, pane, target.session}}
      end
      -- An agent's question needs an answer, not a look.
      if row.attention and row.attention ~= "blocked" then
        items[#items + 1] = {label = "Mark as Read", command = "sidebar:mark_read",
          args = {self, row.tab, target.session}}
      end
      local times = {}
      for _, hours in ipairs(SNOOZE_HOURS) do
        local label = hours < 1 and hours * 60 .. " Minutes" or hours == 1 and "1 Hour" or hours .. " Hours"
        times[#times + 1] = {label = label, command = "sidebar:snooze",
          args = {self, target, hours}}
      end
      times[#times + 1] = {label = "Custom…", command = "sidebar:snooze_custom", args = {self, target}}
      items[#items + 1] = {label = "Snooze", items = times}
      if self.snoozes[target.session] then
        items[#items + 1] = {label = "Remove Snooze", command = "sidebar:remove_snooze", args = {self, target}}
      end
      items[#items + 1] = "-"
    end
    items[#items + 1] = {label = "Duplicate", icon = icons.split_right, command = "sidebar:perform",
      args = {self, path, "pane:copy_view_to_new_group", pane}}
    items[#items + 1] = {label = "Close", icon = icons.close, command = "sidebar:close_pane", args = {self, path, pane}}
    return items
  end
  if row.kind ~= "project" then return nil end
  local project, items = row.project, {}
  local owner = project.window_id or 0
  local loaded = owner ~= 0 and project.id and project.state ~= "dormant"
  if project.exists then
    items[#items + 1] = {label = "New Terminal", icon = icons.terminal, command = "sidebar:perform",
      args = {self, project.path, "terminal:open_at_project_root"}}
    items[#items + 1] = {label = "New Pi", icon = icons.pi, command = "sidebar:perform", args = {self, project.path, "terminal:open_pi"}}
    -- A Project keeps its closed Panes in memory, so an unloaded Project has none.
    if loaded then
      items[#items + 1] = {label = "Reopen Closed Pane", icon = icons.reopen, command = "sidebar:perform",
        args = {self, project.path, "core:reopen_last_closed_pane"}}
    end
    if project.scratch then return items end
    items[#items + 1] = "-"
  end
  if loaded then
    for _, window in ipairs((self.projects or {}).windows or {}) do
      if window.id ~= owner then
        items[#items + 1] = {label = "Move to Window " .. window.id, command = "sidebar:move_project",
          args = {self, project, window.id}}
      end
    end
    items[#items + 1] = {label = "Move to New Window", icon = icons.split_right, command = "sidebar:move_project",
      args = {self, project, 0}}
    items[#items + 1] = {label = "Unload", icon = icons.close, command = "sidebar:unload_project",
      args = {self, project}}
  elseif project.exists then
    items[#items + 1] = {label = "Open in New Window", icon = icons.split_right,
      command = "sidebar:open_project_window", args = {self, project}}
  end
  items[#items + 1] = "-"
  items[#items + 1] = {label = "Copy Path", icon = icons.path, command = "sidebar:copy_project_path",
    args = {self, project}}
  if project.exists then
    items[#items + 1] = {label = "Show in File Explorer", icon = icons.reveal,
      command = "sidebar:show_project_in_folder", args = {self, project}}
  end
  return items
end

-- Opens the Context Menu of `row` at the point. `button` is the mouse button that opened it, if any. The action
-- also names the row's Project for diagnostics.
function SidebarView:open_menu(row, x, y, button)
  local items = row and self:context_menu(row)
  if not items then return false end
  self.focus_pending = nil
  self.unload_ask = nil
  -- The menu takes pointer input, so end the row's hover until the pointer returns.
  self:on_mouse_left()
  self.action("menu", items, x, y, button, row.project.row_id)
  return true
end

-- Opens the Context Menu of the cursor's row below the row, as the Context Menu key does at the editor's caret.
function SidebarView:open_cursor_menu()
  if not self.focused or self.hours or not self.cursor then return false end
  local row, m = self:get_cursor(), self:metrics()
  return self:open_menu(row, row.kind == "project" and m.pad or m.tab_x, self:row_y(self.cursor) + row.h)
end

-- Opens the field that takes a Snooze time in whole hours for the Pane `target`.
function SidebarView:ask_snooze_hours(target)
  -- A field opened with the mouse gives the keyboard back when it closes. One opened from the keyboard keeps it.
  self.hours = {session = target.session, target = target, input = LineInput(), return_focus = not self.focused}
  self.action("focus")
  self:rebuild_rows()
end

-- Snoozes the Pane `target` for `hours` from now, or removes its Snooze for nil. The time is saved first, so the
-- Project finds it when it snoozes or wakes the Pane.
function SidebarView:set_snooze(target, hours)
  return self:set_snooze_until(target, hours and os.time() + hours * 60 * 60 or nil)
end

-- A new time for a Snooze that has not ended keeps its start, so the span counts the whole time away.
function SidebarView:set_snooze_until(target, time)
  local session, now = target.session, os.time()
  local previous, previous_span = self.snoozes[session], self.snooze_spans[session]
  self.snoozes[session] = time
  local from = previous_span and previous_span.to > now and previous_span.from or now
  self.snooze_spans[session] = time and {from = from, to = time} or nil
  local saved, err = self.action("snooze", session)
  if saved == false then
    self.snoozes[session], self.snooze_spans[session] = previous, previous_span
    core.error("Could not save Snooze: %s", tostring(err))
    return false
  end
  core.log_quiet("Sidebar Snooze: session=%s Pane=%s until=%s", session, tostring(target.pane), tostring(time))
  self.action("request", "direct", target.path, {action = time and "snooze" or "unsnooze", pane = target.pane})
  self:rebuild_rows()
  return true
end

-- Agent control requests use absolute times, so delivery does not extend the requested Snooze.
function SidebarView:on_snooze_request(text)
  local ok, request = pcall(require("core.json").decode, text)
  if not ok or type(request) ~= "table" or request.action ~= "snooze"
    or type(request.path) ~= "string" or request.path == ""
    or type(request.pane) ~= "string" or request.pane == ""
    or type(request.session) ~= "string" or request.session == ""
    or request.until_time ~= nil and (type(request.until_time) ~= "number"
      or request.until_time <= 0 or request.until_time % 1 ~= 0) then
    core.log_quiet("Sidebar Snooze request rejected")
    return false
  end
  return self:set_snooze_until(request, request.until_time)
end

-- Closes the hours field. With `accept`, a whole number of hours above zero sets the Snooze; other text keeps
-- the field open.
function SidebarView:close_hours(accept)
  local hours = self.hours
  local count = accept and tonumber(hours.input.text)
  if accept and not (count and count >= 1) then return end
  self.hours = nil
  if count then self:set_snooze(hours.target, count) else self:rebuild_rows() end
  if hours.return_focus then self.action("return_focus") end
end

local function in_other_window(project, window_id)
  local owner = project and project.window_id
  return window_id and owner and owner ~= 0 and owner ~= window_id
end

-- The shell keeps a Window's old selection until a chosen Pane renders, and opens a Terminal Session's Pane after
-- it selects the Project. The chosen row shows the selection meanwhile, so the highlight does not go back.
-- With `jump`, the highlight goes to the chosen row at once instead of gliding there.
function SidebarView:choose(row, jump)
  local owner = row.project.window_id
  if row.selected or row.current or self.window_id and owner and owner ~= 0 and owner ~= self.window_id then return end
  self.chosen = {key = row.id_key, path = row.project.path, session = row.kind == "terminal" and row.terminal.id or nil,
    deadline = system.get_time() + CHOICE_TIMEOUT}
  self.jump_selection = jump
  self:rebuild_rows()
end

-- A row activated from the keyboard takes the highlight at once. The user already moved the cursor there. When the
-- Project area shows the row's Peek, the Peek stays until the selection draws, so the switch shows no other frame.
function SidebarView:activate_row(row, from_keyboard)
  if not row then return end
  local sent, wanted = self.peek_sent, self.peek_wanted
  if from_keyboard and sent and sent.id ~= 0 and wanted and wanted.key == sent.key and row == self:get_cursor()
    and (row.kind == "project" or row.kind == "tab" or row.kind == "terminal") then
    -- The shell keeps the Peek until the selection follows. A new message for the same row would end that wait.
    self.action("peek_commit")
    sent.committed = true
  end
  if row.kind == "project" or row.kind == "tab" or row.kind == "terminal" then self:choose(row, from_keyboard) end
  if row.kind == "project" then
    if row.project.state == "ready" and not row.key and not in_other_window(row.project, self.window_id) then
      self.action("request", "select", row.project.path, {action = "open_project"})
    else
      self.action("select", row.project.row_id)
    end
  elseif row.kind == "tab" then self.action("request", "select", row.project.path, {action = "focus", pane = row.tab.id})
  elseif row.kind == "terminal" then self.action("select_terminal", row.project.row_id, row.terminal.id)
  elseif row.key then self:toggle(row.key, row.collapsed) end
end

-- The Peek of the cursor row: a Project id and a Pane number. Zero shows the Selected Project as it is.
function SidebarView:peek_target()
  if not self.focused or self.hours or self.drag or self.reorder then return 0, 0 end
  local row = self:get_cursor()
  local project = row and row.project
  if not project then return 0, 0 end
  if project.state == "dormant" or (project.id or 0) == 0 then return PEEK_NO_CONTENT, 0 end
  local pane = row.kind == "tab" and tonumber(tostring(row.tab.id):match("^pane%-(%d+)$")) or 0
  local selected = self:selected_project()
  if selected and selected.id == project.id
    and (pane == 0 or row.tab.group == (project.panes or {}).visible and not row.tab.snoozed) then
    return 0, 0
  end
  return project.id, pane
end

-- Where the cursor's highlight shows, from top to bottom, in surface pixels. The shell draws its bead there.
function SidebarView:peek_rect()
  local mark = self.marks.cursor
  if not mark or mark.alpha <= 0.01 then return 0, 0 end
  local y = self:shown_origin(mark.area) + mark.y + 1
  local top, bottom = self:shown_list_top(), self:main_bottom(self.shown.bottom_h)
  if mark.area == "bottom" then top, bottom = self:bottom_area(self.shown.bottom_h), self.view_h end
  return math.floor(math.max(top, y) + 0.5), math.floor(math.min(bottom, y + mark.h - 2) + 0.5)
end

-- Peek: while the Sidebar has the keyboard, the Project area shows the cursor row's content. The shell shows it and
-- draws a bead beside the cursor's highlight. Returns true when the shown row changed.
function SidebarView:update_peek(now)
  local id, pane = self:peek_target()
  local key = id .. ":" .. pane
  local wanted = self.peek_wanted
  if not wanted or wanted.key ~= key then
    local rested = not wanted or now - wanted.at >= PEEK_DELAY
    wanted = {key = key, id = id, pane = pane, at = now, due = rested and now or now + PEEK_DELAY}
    self.peek_wanted = wanted
  end
  local sent = self.peek_sent or {key = "0:0", id = 0, pane = 0}
  local shown = now >= wanted.due and wanted or sent
  self.peek_due = shown ~= wanted and wanted.due or nil
  local top, bottom = self:peek_rect()
  if shown.key == sent.key and (shown.id == 0 or sent.committed or top == sent.top and bottom == sent.bottom) then
    return false
  end
  local changed = shown.key ~= sent.key
  local direction = 0
  if changed and self.peek_index and self.cursor then
    direction = self.cursor > self.peek_index and 1 or self.cursor < self.peek_index and -1 or 0
  end
  if changed then
    self.peek_index = self.cursor
    core.log_quiet("Sidebar Peek: Project=%d Pane=%d direction=%d", shown.id, shown.pane, direction)
  end
  self.peek_sent = {key = shown.key, id = shown.id, pane = shown.pane, top = top, bottom = bottom}
  self.action("peek", shown.id, shown.pane, direction, top, bottom)
  return changed
end

function SidebarView:selected_project()
  for _, window in ipairs((self.projects or {}).windows or {}) do
    if window.id == self.window_id then
      for _, project in ipairs(self.projects) do
        if project.id == window.selected_project then return project end
      end
    end
  end
end

-- Pane History belongs to the Window, not the Sidebar cursor's row.
function SidebarView:move_pane_history(direction)
  if not self.focused or self.hours then return false end
  local project = self:selected_project()
  if not project then return false end
  self.focus_pending, self.unload_ask = nil, nil
  self.action("return_focus")
  self.action("request", "select", project.path, {action = "perform", command = "pane:history_" .. direction})
  return true
end

-- Keys with Ctrl or Alt, and function keys, cannot type text. AltGr and Shift keys type text in the search field.
local function forwardable(stroke)
  for part in stroke:gmatch("[^+]+") do
    if part == "ctrl" or part == "alt" or part:match("^f%d+$") then return true end
  end
  return false
end

-- A key that the Sidebar does not use acts as if the user pressed it in the cursor's Pane, or else in the cursor's
-- Project. A row without a Project, such as an age group, sends it to the Selected Project. The key also gives the
-- keyboard to the Project, unless `keep_sidebar` keeps it here, as for a key that closes Panes. The Project then
-- takes the keyboard only to ask a question.
function SidebarView:forward_key(stroke, keep_sidebar)
  if not self.focused or self.hours or not forwardable(stroke) then return false end
  local row = self:get_cursor()
  local project = row and row.project or self:selected_project()
  if not project then return false end
  self.focus_pending = nil
  self.unload_ask = nil
  -- The shell gets both messages in this order.
  if not keep_sidebar then self.action("return_focus") end
  self.action("request", "select", project.path, {action = "key", stroke = stroke,
    pane = row and row.kind == "tab" and row.tab.id or nil, keep_sidebar = keep_sidebar or nil})
  return true
end

-- Copies the cursor row's name: a Tab's name, with a file's path, or a Project's path.
function SidebarView:copy_cursor_name()
  if not self.focused or self.hours then return false end
  local row = self:get_cursor()
  local text = row and (row.tab and tab.copy_text(row.tab)
    or row.kind == "project" and row.project.path:gsub("/", PATHSEP))
  if not text then return false end
  system.set_clipboard(text)
  core.log_quiet("Sidebar copied the name of a %s row", row.kind)
  return true
end

-- The Pane close command unloads a Project header. Other rows keep their normal key forwarding.
function SidebarView:unload_cursor_project(repeating)
  if not self.focused or self.hours then return false end
  local row = self:get_cursor()
  if not row or row.kind ~= "project" then return false end
  self.focus_pending = nil
  self.unload_ask = nil
  local state = row.project.state
  if not repeating and state ~= "dormant" and state ~= "closing" and not row.project.scratch then
    self.action("unload", row.project.row_id)
  end
  return true
end

-- Asks to unload the cursor's Project, or unloads it when the last key asked the same. A held key does neither.
function SidebarView:ask_unload(row, asked, repeating)
  local state = row.project.state
  if state == "dormant" or state == "closing" then return end
  if repeating then
    self.unload_ask = asked
  elseif asked and asked.key == row.id_key then
    self.action("unload", row.project.row_id)
  else
    self.unload_ask = {key = row.id_key, deadline = system.get_time() + UNLOAD_TIMEOUT}
  end
end

---@param repeating boolean? The key is held down and repeats.
function SidebarView:on_key_pressed(key, repeating)
  if not self.focused then return end
  self.focus_pending = nil
  if self.hours then
    if key == "escape" then self:close_hours(false)
    elseif key == "return" or key == "keypad enter" then self:close_hours(true) end
    return
  end
  local row = self:get_cursor()
  -- Each key ends the question. Only Left on the same Project continues it.
  local asked = self.unload_ask
  self.unload_ask = nil
  if key == "escape" then self.action("return_focus")
  elseif key == "return" or key == "keypad enter" then self:activate_row(row, true)
  elseif key == "previous_project" or key == "next_project" then
    local step = key == "previous_project" and -1 or 1
    local index = (self.cursor or 1) + step
    while self.rows[index] do
      local target = self.rows[index]
      if target.kind == "project" and (not row or target.project ~= row.project) then
        self.cursor = index
        break
      end
      index = index + step
    end
    self:reveal_cursor()
  elseif key == "up" or key == "down" or key == "home" or key == "end" then
    local index = key == "home" and 1 or key == "end" and #self.rows
      or (self.cursor or 1) + (key == "up" and -1 or 1)
    index = math.max(1, math.min(#self.rows, index))
    if self.rows[index] and self.rows[index].kind ~= "empty" then self.cursor = index end
    self:reveal_cursor()
  elseif row and (key == "left" or key == "right") and self.query == "" then
    if key == "left" and row.kind == "project" and (row.collapsed or not row.key) then
      if not row.project.scratch then self:ask_unload(row, asked, repeating) end
    elseif row.key then
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

-- Forgets the ended Snoozes of the Terminals that got new work after their wake: a new agent turn or a new shell
-- command. A turn that ran at the wake and ends later is not new work.
function SidebarView:forget_resumed_snoozes(projects)
  local now = os.time()
  for _, project in ipairs(projects or {}) do
    for _, record in ipairs(project.terminals or {}) do
      local span = self.snooze_spans[record.id]
      local agent = span and span.to <= now and record.state == "running" and tab.agent(record)
      if agent and (agent.since or 0) > span.to and (agent.command or tab.working(record, agent)) then
        self.snooze_spans[record.id] = nil
        core.log_quiet("Sidebar Snooze span ended: session=%s new work=%s", record.id,
          agent.command and "command" or "turn")
        self.action("snooze", record.id)
      end
    end
  end
end

function SidebarView:set_model(projects, window_id)
  self.projects, self.window_id = projects, window_id
  self:forget_resumed_snoozes(projects)
  -- A Tab moved inside its Project shows its result in the next report.
  if self.pending and not self.pending.transfer then self.pending = nil end
  self:rebuild_rows()
  if self.focus_pending then
    self.focus_pending = nil
    self:reset_cursor_to_selection()
    local row = self:get_cursor()
    core.log_quiet("Sidebar focus refreshed: Window=%s row=%s", tostring(window_id), row and row.id_key or "none")
  end
end

-- The index in `rows` of the main list's Project row nearest the cursor in the current rows: above it first, then
-- below it.
function SidebarView:nearest_project(rows)
  local headers = {}
  for index, row in ipairs(rows) do
    if row.kind == "project" and row.area == "main" then headers[row.id_key] = index end
  end
  local old = self.rows
  for index = self.cursor - 1, 1, -1 do
    if headers[old[index].id_key] then return headers[old[index].id_key] end
  end
  for index = self.cursor + 1, #old do
    if headers[old[index].id_key] then return headers[old[index].id_key] end
  end
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

-- The user looks at a Terminal Session: this reads its Unread Result, and ends its Snooze once the time came.
-- Looking at an agent's question does not answer it.
function SidebarView:look(item, session, now)
  local snooze = self.snoozes[session]
  local attention = tab.attention(item, self.seen[session], snooze)
  if attention and attention ~= "blocked" then
    self.seen[session] = now
    self.action("seen", session)
  end
  if snooze and snooze <= now then
    self.snoozes[session] = nil
    self.action("snooze", session)
  end
end

function SidebarView:rebuild_rows()
  local pending = self.reorder_pending
  if pending and (system.get_time() >= pending.deadline or self:has_order(pending.order)) then
    self.reorder_pending = nil
  end
  local cursor_row = self:get_cursor()
  local cursor_key = row_key(cursor_row)
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
  local selected, selected_projects = 0, {}
  for _, window in ipairs(projects.windows or {}) do
    selected_projects[window.selected_project] = true
    if window.id == window_id then selected = window.selected_project end
  end
  local numbers = numbered_panes.numbers(projects, self.seen, self.snoozes, window_id)
  -- The next Snooze time. The rows change then.
  self.next_snooze = nil
  for _, time in pairs(self.snoozes) do
    if time > now and time < (self.next_snooze or math.huge) then self.next_snooze = time end
  end
  -- A collapsed Project shows only the Terminals that need the user.
  local only_attention = false
  -- What a Terminal needs from the user: its attention mark, or its agent's question, also during a Snooze.
  local function needs_user(attention, agent)
    return attention or agent and agent.state == "blocked" and "blocked" or nil
  end
  -- Adds `count` Terminals that need `kind` to the count of a hidden Project or group. A question sets the kind.
  local function add_pending(pending, kind, count)
    if not kind then return pending end
    pending = pending or {count = 0}
    pending.count = pending.count + (count or 1)
    if not pending.kind or kind == "blocked" then pending.kind = kind end
    return pending
  end
  local function mark(row, agent)
    row.agent = agent
    local session = row.tab.terminal and row.tab.terminal.session
    if session then
      local snooze = self.snoozes[session]
      row.attention = tab.attention(row.tab, self.seen[session], snooze)
      local running = row.tab.terminal.state == "running"
      if snooze and snooze > now and running then row.snooze = snooze end
      local span = self.snooze_spans[session]
      if span and span.to <= now and running then row.woke = span end
    end
    return row
  end
  local function add_tab(row, agent)
    mark(row, agent)
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
    local seen_active = (selected_projects[project.id] or not window_id and project.selected) and panes.active
    -- The Selected Project's active Tab takes the highlight.
    local active = is_selected and panes[panes.active or 0] and panes.active
    -- Another Window's Project stays collapsed and has no fold key, so it does not toggle.
    local elsewhere = in_other_window(project, window_id)
    local key = not elsewhere and (#panes > 0 or #(project.terminals or {}) > 0) and ("project:" .. project.path) or nil
    -- A Project expands when it becomes selected, and stays expanded after it loses the selection.
    if key then
      if is_selected and not self.was_selected[key] then
        -- A restored Window keeps its manual fold. Later selections still expand the chosen Project.
        if (not self.restore_folds or self.selected_once) and self.collapsed[key] then
          self.collapsed[key] = false
          self.action("collapsed", key, false)
        end
        self.selected_once = true
      end
      selected_keys[key] = is_selected or nil
    end
    local collapsed = elsewhere or key and self:is_collapsed(key, false) or false
    local project_row = {kind = "project", project = project, key = key, collapsed = collapsed, tabs = #panes,
      id_key = "project:" .. project.path, current = is_selected,
      selected = is_selected and (not active or collapsed and not searching)}
    if project.scratch then
      -- Its section header counts the Tabs that it hides.
      project_row.label, project_row.count = look.name(project), collapsed and #panes > 0 and #panes or nil
    end
    add(project_row, m.project)
    only_attention = collapsed and not searching
    local shown, sizes, records, snoozed = {}, {}, {}, {}
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
        -- A Tab shown in any Window is read, even when that Window's Sidebar is hidden.
        if index == seen_active then self:look(item, session, now) end
      end
      local group = item.group or 0
      -- A Pane Group with several Panes shows as one container around its Tabs. A collapsed Project shows single
      -- Tabs, so it has no containers.
      local bracket = sizes[group] > 1 and not only_attention and {first = (panes[index - 1] or {}).group ~= group,
        last = (panes[index + 1] or {}).group ~= group, visible = group == panes.visible} or nil
      local row = {kind = "tab", project = project, tab = item, selected = index == active, bracket = bracket,
        id_key = "tab:" .. project.path .. ":" .. tostring(item.id)}
      if item.snoozed then
        row.bracket, row.depth = nil, 2
        snoozed[#snoozed + 1] = mark(row, item.agent)
      else
        add_tab(row, item.agent)
      end
      project_row.pending = add_pending(project_row.pending, needs_user(row.attention, row.agent))
    end
    -- Terminal Sessions that no Pane shows. Recent ones and those that need the user show directly, and so do
    -- those from hosts that do not report activity. Older ones fold into groups. A Session in a Pane's history
    -- shows only when it needs the user.
    local older, held = {}, {}
    for _, id in ipairs(panes.held or {}) do held[id] = true end
    for _, terminal in ipairs(project.terminals or {}) do
      local bucket = (terminal.activity or 0) > 0 and age_bucket(terminal.activity, now)
      local attention = tab.attention(tab.describe_session(terminal), self.seen[terminal.id], self.snoozes[terminal.id])
      if not shown[terminal.id] and terminal.state == "running" then
        project_row.pending = add_pending(project_row.pending, needs_user(attention, tab.agent(terminal)))
      end
      if shown[terminal.id] or held[terminal.id] and not attention then
        -- Its Tab shows it, or its Pane's history keeps it.
      elseif bucket and bucket ~= "week" and not attention then
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
    -- Snoozed Panes fold at the end of the Project. The fold shows a question from a Snoozed agent, and a Snooze
    -- that came due before the Project woke its Pane, so a collapsed fold or Project still tells the user.
    if #snoozed > 0 then
      local fold_key = "snoozed:" .. project.path
      local fold = {kind = "terminal_group", project = project, label = "Snoozed", count = #snoozed, key = fold_key,
        id_key = fold_key, snoozed = true, collapsed = self:is_collapsed(fold_key, true)}
      for _, row in ipairs(snoozed) do fold.attention = fold.attention or needs_user(row.attention, row.agent) end
      if not only_attention or fold.attention then add(fold, m.terminal) end
      if not only_attention and (searching or not fold.collapsed) then
        for _, row in ipairs(snoozed) do add(row, row.agent and m.agent or m.terminal) end
      end
    end
  end
  area = "main"
  local other_windows = {}
  -- The Scratch Project follows the user, so it comes first in every Window, even when it is Dormant.
  for _, project in ipairs(projects) do
    if project.scratch then add_loaded(project) end
  end
  local grouped = {}
  for _, project in ipairs(self:ordered_projects(projects)) do
    if project.scratch then
      -- It is listed first.
    elseif in_other_window(project, window_id) then
      other_windows[#other_windows + 1] = project
    elseif project.state == "dormant" then
      local bucket = age_bucket(look.activity(project), now)
      grouped[bucket] = grouped[bucket] or {}
      table.insert(grouped[bucket], project)
    else
      add_loaded(project)
    end
  end
  if #rows == 0 and #other_windows == 0 then
    local label = #projects > 0 and "No loaded Projects" or "No Projects yet"
    add({kind = "empty", label = label, id_key = "empty"}, m.project)
  end
  area = "bottom"
  for _, project in ipairs(other_windows) do add_loaded(project) end
  for _, group in ipairs(GROUPS) do
    local members = grouped[group.bucket]
    if members then
      local key = "group:" .. group.bucket
      local collapsed = self:is_collapsed(key, group.collapsed)
      local group_row = {kind = "group", bucket = group.bucket, label = group.label, count = #members, key = key,
        id_key = key, collapsed = collapsed}
      add(group_row, m.group)
      for _, project in ipairs(members) do
        local pending
        for _, terminal in ipairs(project.terminals or {}) do
          if terminal.state == "running" then
            local attention = tab.attention(tab.describe_session(terminal), self.seen[terminal.id],
              self.snoozes[terminal.id])
            pending = add_pending(pending, needs_user(attention, tab.agent(terminal)))
          end
        end
        if pending then group_row.pending = add_pending(group_row.pending, pending.kind, pending.count) end
        if searching or not collapsed then
          add({kind = "project", project = project, id_key = "project:" .. project.path, pending = pending}, m.project)
        end
      end
    end
  end
  if searching then
    local filtered, matches = {}, {}
    for _, row in ipairs(rows) do
      if row.project and row.kind ~= "terminal_group" then
        local project_match = common.fuzzy_match(look.name(row.project), self.query) ~= nil
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
  local lift = self.lift
  for _, row in ipairs(rows) do
    row.lifted = lift and row.area == "main" and row.project and row.project.path == lift.path or nil
    if row.area == "main" then
      row.gap = row.kind == "project" and main_y > 0 or nil
      if row.gap then main_y = main_y + m.project_gap end
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
  -- A Snooze puts the cursor's Tab away like a close, so the cursor follows the Project's new active Tab.
  local cursor
  for index, row in ipairs(rows) do
    if cursor_key and row_key(row) == cursor_key then
      if not (row.tab and row.tab.snoozed and not cursor_row.tab.snoozed) then cursor = index end
      break
    end
  end
  if not cursor and cursor_row and cursor_row.kind == "tab" then
    -- The Pane manager chooses the replacement. Follow its report, within the same Project.
    local active_found = false
    for index, row in ipairs(rows) do
      if row.project and row.project.path == cursor_row.project.path then
        local panes = row.project.panes or {}
        local active = panes[panes.active or 0]
        if row.kind == "project" then cursor = index end
        if row.kind == "tab" and active and row.tab.id == active.id then
          cursor, active_found = index, true
          break
        end
      end
    end
    if searching and not active_found then
      self.input:set_text("")
      self.query = ""
      core.log_quiet("Sidebar close selection: cleared search to show Project=%s", cursor_row.project.path)
      return self:rebuild_rows()
    end
  end
  -- The cursor's row left the main list, for example when its Project unloaded. The cursor takes the nearest
  -- Project row above it, or else below it.
  if cursor_row and cursor_row.area == "main" and not (cursor and rows[cursor].area == "main") then
    cursor = self:nearest_project(rows) or cursor
  end
  if not cursor then
    for index, row in ipairs(rows) do
      if row.kind ~= "empty" and (not searching or row.matches) then cursor = index; break end
    end
  end
  self.rows, self.main_h, self.bottom_h = rows, main_y, bottom_y
  self.was_selected, self.cursor = selected_keys, cursor
  self:clamp_scroll()
  -- The list scrolls only to show a new selection or a cursor that moved to another row. Otherwise it keeps the
  -- user's scroll, because the model changes often.
  local selected_index
  for index, row in ipairs(rows) do
    if row.selected then selected_index = index; break end
  end
  local selected_key = selected_index and rows[selected_index].id_key
  if selected_key and selected_key ~= self.selected_key then self:reveal_row(selected_index) end
  self.selected_key = selected_key
  if self.focused and cursor_key and cursor_key ~= row_key(rows[cursor]) then self:reveal_cursor() end
  if self.drag then self:update_drag() end
  if self.reorder and not self.reordering then self:update_reorder() end
  if self.hover_y then self:update_hover() end
end

-- The groups' height on screen, and the top of the area that shows them. `content` is the height of their rows,
-- by default the layout's.
function SidebarView:bottom_area(content)
  content = content or self.bottom_h
  if content <= 0 then return self.view_h, 0 end
  local m = self:metrics()
  local available = math.max(0, self.view_h - m.top)
  local height = math.min(content + m.pad, math.floor(available * GROUPS_HEIGHT), GROUPS_ROWS * m.project + m.pad)
  return self.view_h - height, height
end

function SidebarView:main_bottom(content)
  local bottom_top, bottom_height = self:bottom_area(content)
  return bottom_height > 0 and bottom_top - self:metrics().gap or self.view_h
end

function SidebarView:clamp_scroll()
  local m = self:metrics()
  local _, bottom_height = self:bottom_area()
  self.scroll = math.max(0, math.min(self.scroll, self.main_h - (self:main_bottom() - self:list_top())))
  self.bottom_scroll = math.max(0, math.min(self.bottom_scroll, self.bottom_h + m.pad - bottom_height))
end

function SidebarView:search_open() return self.query ~= "" or self.hours ~= nil end

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
  return self:field():offset_at(style.font, x - self:search_box() + self.search_scroll)
end

function SidebarView:on_mouse_pressed(button, x, y)
  if button ~= "left" and button ~= "right" and button ~= "middle" then return end
  self.focus_pending = nil
  self.unload_ask = nil
  if self:in_search(x, y) then
    -- A press places the caret. A drag from it selects.
    if button == "left" then
      self:field():set_caret(self:search_offset(x))
      self.selecting = true
    end
    return
  end
  local pill = self:attention_pill_at(x, y)
  if pill then
    if button == "left" then self:open_attention_pill(pill) end
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
  if button == "right" then
    self:open_menu(row, x, y, button)
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
  if button == "left" then
    -- A click acts at its release. A loaded Project's press becomes a reorder drag when the pointer moves far enough.
    self.press = {key = row.id_key, x = x, y = y, click = true}
  elseif button == "middle" then
    -- A middle-click unloads at its release, so a press that moves to another row does nothing.
    if not row.project.scratch then self.click_row = {button = button, row_id = row.project.row_id} end
  end
end

-- A click on a Project row: a loaded Project in this Window toggles its children, other Projects open.
function SidebarView:click_project(key, x, y)
  local row = x >= 0 and x < self.width and self:row_at(y)
  if not row or row.id_key ~= key then return end
  if row.project.state ~= "dormant" and row.key and not in_other_window(row.project, self.window_id) then
    self:toggle(row.key, row.collapsed)
  else
    self:activate_row(row)
  end
end

function SidebarView:on_mouse_released(button, x, y)
  if button == "left" then
    local press = self.press
    self.scroll_drag, self.press, self.selecting = nil, nil, nil
    if self.reorder then
      self.reorder.y = y
      self:update_reorder()
      if self.reorder then self:end_reorder(true) end
    elseif self.drag then
      self:finish_drag(x, y)
    elseif press and press.click then
      self:click_project(press.key, x, y)
    end
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
  if row and row.kind == "project" and row.project.row_id == pressed.row_id then self.action("unload", pressed.row_id) end
end

function SidebarView:update_hover()
  local inside = self.hover_x and self.hover_x >= 0 and self.hover_x < self.width
  local row = inside and not self.drag and not self.reorder and self:row_at(self.hover_y)
  local hover = row and row.kind ~= "empty" and row or nil
  local scrollbar = self.hover_x and self:scrollbar_at(self.hover_x, self.hover_y)
  local pill = inside and not self.drag and not self.reorder and self:attention_pill_at(self.hover_x, self.hover_y)
  if scrollbar or pill then hover = nil end
  scrollbar = scrollbar and scrollbar.field
  local changed = hover ~= self.hover or scrollbar ~= self.scrollbar_hover
  self.hover, self.scrollbar_hover, self.pill_hover = hover, scrollbar, pill and pill.id or nil
  local tooltip = self:get_tooltip()
  if tooltip ~= self.tooltip_text then
    self.tooltip_text, self.tooltip_started = tooltip, system.get_time()
    changed = true
  end
  return changed
end

-- A Snooze's length in whole minutes: "45m", "2h 30m", or whole days from two days: "3d".
local function minutes_text(minutes)
  if minutes < 60 then return minutes .. "m" end
  if minutes >= 2 * 24 * 60 then return math.floor(minutes / (24 * 60) + 0.5) .. "d" end
  local hours, rest = math.floor(minutes / 60), minutes % 60
  return rest > 0 and string.format("%dh %02dm", hours, rest) or hours .. "h"
end

-- The time until a Snooze, rounded up to a whole minute.
local function snooze_text(time, now)
  return minutes_text(math.max(1, math.ceil((time - now) / 60)))
end

-- A Snooze's length, rounded to a whole minute.
local function span_text(span)
  return minutes_text(math.max(1, math.floor((span.to - span.from) / 60 + 0.5)))
end

-- An ended Snooze's note: its length and the time since its wake, such as "12h · 12m ago".
local function woke_text(span, now)
  local age = tab.age_text(span.to, now)
  return span_text(span) .. " · " .. (age == "now" and age or age .. " ago")
end

-- The width of a Snooze's note with the text `label`.
local function snooze_note_width(label)
  local font = style.font
  return font:get_width(label) + 4 * SCALE + math.floor(font:get_height() * 0.6 + 0.5)
end

-- An ended Snooze's note explains itself. Show the original Terminal title only when the Tab hides part of it.
function SidebarView:get_tooltip()
  if self.scroll_drag or self.drag or self.reorder then return nil end
  local row = self.hover
  local item = row and row.tab
  if not item or not item.terminal then return nil end
  local x, width = self:tab_bounds(row, self.width)
  if row.woke then
    local now = os.time()
    if (self.hover_x or 0) >= x + width - snooze_note_width(woke_text(row.woke, now)) then
      local age = tab.age_text(row.woke.to, now)
      return string.format("Back from a %s Snooze %s", span_text(row.woke),
        age == "now" and "just now" or age .. " ago")
    end
  end
  local name = tab.display_name(item)
  local available = tab.name_width(item, width, self:metrics().terminal, {number_gutter = self:metrics().number_gutter})
  if name ~= item.name or tab.fit(style.font, name, available) ~= name then return item.name end
end

-- Returns true when the hover or a dragged scrollbar changed and the view needs a redraw.
function SidebarView:on_mouse_moved(x, y)
  self.hover_x, self.hover_y = x, y
  if self.selecting then
    self:field():set_caret(self:search_offset(x), true)
    return true
  end
  if self.scroll_drag then
    self:drag_scrollbar(y)
    self:update_hover()
    return true
  end
  local press = self.press
  if press and math.max(math.abs(x - press.x), math.abs(y - press.y)) >= DRAG_THRESHOLD * SCALE then
    local row, index = self:row_by_key(press.key)
    if not press.click then
      self.press = nil
      if row then
        self.drag = {key = press.key, row = row}
        self.card = {row = row, from = self:card_slot(row, self:row_y(index)), lift = 0, alpha = 1}
      end
    elseif row and self:can_reorder(row) then
      -- Other Project rows stay a click while the pointer stays on them.
      self.press = nil
      self:begin_reorder(row, press.y)
    end
  end
  if self.reorder then
    self.reorder.y = y
    self:update_reorder()
    self:update_hover()
    return true
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
  if self.reorder then self:end_reorder(false) end
  return self:update_hover()
end

-- The pointer's cursor: a hand over rows that act on a click.
function SidebarView:pointer_cursor()
  if self.drag or self.reorder or self.scroll_drag or not self.hover_x then return "arrow" end
  if self.selecting or self:in_search(self.hover_x, self.hover_y) then return "ibeam" end
  if self.press then return "hand" end
  if self.pill_hover then return "hand" end
  if self:scrollbar_at(self.hover_x, self.hover_y) then return "arrow" end
  return self.hover and "hand" or "arrow"
end

------------------------------------------------------------------------------------------------------------------
-- Drag and drop

-- Whether a Project takes a dragged Tab or a drop from another application.
local function accepts(project)
  if project.state == "failed" or project.state == "closing" then return false end
  if project.state == "dormant" and not project.exists then return false end
  return true
end

-- The Tab next to `row` in its Project, one row up or down.
function SidebarView:neighbor(row, direction)
  local _, index = self:row_by_key(row.id_key)
  local next = index and self.rows[index + direction]
  return next and next.kind == "tab" and next.project.path == row.project.path and next or nil
end

-- Whether placing the dragged Tab `source` beside `anchor` leaves its Project's layout as it is.
function SidebarView:unchanged(source, place, anchor)
  -- A dropped Snoozed Tab wakes.
  if anchor.project.path ~= source.project.path or source.tab.snoozed then return false end
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

-- The line after the last Tab of `project` outside its Snoozed fold.
function SidebarView:end_target(project, source)
  local last
  for _, row in ipairs(self.rows) do
    if row.kind == "tab" and row.project.path == project.path and not row.tab.snoozed then last = row end
  end
  return last and self:line_target(last, "after", true, source) or nil
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
    if not above or not accepts(above.project) then return nil end
    if above.tab.snoozed then return self:end_target(above.project, source) end
    return self:line_target(above, "after", true, source)
  end
  if not row.project or not accepts(row.project) then return nil end
  -- A drop cannot snooze, and the Snoozed Panes have no visible place in the Project's order. So the Snoozed
  -- fold takes a drop after the Project's other Tabs.
  if row.snoozed or row.kind == "tab" and row.tab.snoozed then
    return lines and self:end_target(row.project, source) or nil
  end
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
    return "direct", from, {action = "export", pane = source.tab.id, to = path, target = target.place, focus = true,
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
  local target, source = drag.target, drag.row
  -- A dropped Snoozed Tab wakes. Its saved time goes first, so the Project's check does not snooze it again.
  local session = source.tab.snoozed and source.tab.terminal and source.tab.terminal.session
  if session and (target or drag.x >= self.width) then
    if not self:set_snooze({session = session, pane = source.tab.id, path = source.project.path}, nil) then
      self:end_drag(nil)
      return
    end
  end
  if self:send_work("drop") then
    self.drag, self.card = nil, nil
    return
  end
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

------------------------------------------------------------------------------------------------------------------
-- Project reorder
--
-- A loaded Project in the main list drags with its children. The other Projects slide out of its way while it moves.
-- The drop asks the shell to place it beside a neighbour. All Windows share the shell's order, and the shell saves it.

-- The main list's loaded Projects, each with its children, in layout order. A block starts at the gap above its
-- Project row. The Scratch Project stays first and does not move.
function SidebarView:reorder_blocks()
  local m = self:metrics()
  local blocks, current = {}, nil
  for _, row in ipairs(self.rows) do
    if row.area == "main" then
      if row.kind == "project" then
        current = nil
        if not row.project.scratch then
          current = {project = row.project, top = row.y - (row.gap and m.project_gap or 0), bottom = row.y + row.h}
          blocks[#blocks + 1] = current
        end
      elseif current then
        current.bottom = row.y + row.h
      end
    end
  end
  return blocks
end

function SidebarView:can_reorder(row)
  return row.kind == "project" and row.area == "main" and not row.project.scratch and self.query == ""
    and #self:reorder_blocks() > 1
end

function SidebarView:begin_reorder(row, y)
  local path = row.project.path
  local grab
  for _, block in ipairs(self:reorder_blocks()) do
    if block.project.path == path then grab = y - self:area_origin("main") - block.top end
  end
  self.reorder = {path = path, row_id = row.project.row_id, grab = grab, y = y}
  self.lift = {path = path, amount = 0}
  self.reorder.start = self:reorder_paths()
  self.reorder.order = self.reorder.start
  core.log_quiet("Sidebar reorder started: Window=%s Project=%s", tostring(self.window_id), path)
  self:rebuild_rows()
end

function SidebarView:reorder_paths()
  local paths = {}
  for _, block in ipairs(self:reorder_blocks()) do paths[#paths + 1] = block.project.path end
  return paths
end

-- The dragged block passes a neighbour when its edge crosses that neighbour's middle. Moving back needs the same
-- crossing, so the order does not flicker at one point.
function SidebarView:update_reorder()
  local drag = self.reorder
  for _ = 1, 64 do
    local blocks = self:reorder_blocks()
    local index
    for i, block in ipairs(blocks) do
      if block.project.path == drag.path then index = i end
    end
    -- The Project unloaded or left this Window during the drag.
    if not index then self:end_reorder(false); return end
    drag.order = self:reorder_paths()
    local own, previous, next = blocks[index], blocks[index - 1], blocks[index + 1]
    local h = own.bottom - own.top
    drag.min, drag.max = blocks[1].top, blocks[#blocks].bottom - h
    local top = drag.y - drag.grab - self:area_origin("main")
    local to
    if previous and top < (previous.top + previous.bottom) / 2 then to = index - 1
    elseif next and top + h > (next.top + next.bottom) / 2 then to = index + 1 end
    if not to then return end
    table.remove(drag.order, index)
    table.insert(drag.order, to, drag.path)
    self.reordering = true
    self:rebuild_rows()
    self.reordering = nil
  end
end

-- Ends the drag. With `commit`, a changed order goes to the shell. The list keeps the new order until the shell
-- reports it. The block settles into its place.
function SidebarView:end_reorder(commit)
  local drag = self.reorder
  self.reorder = nil
  local order, present = drag.order, {}
  for _, path in ipairs(order) do present[path] = true end
  local start = {}
  for _, path in ipairs(drag.start) do
    if present[path] then start[#start + 1] = path end
  end
  local index
  for i, path in ipairs(order) do
    if path == drag.path then index = i end
  end
  local changed = index and #start == #order and table.concat(start, "\0") ~= table.concat(order, "\0")
  if commit and changed then
    local anchor_path, after = order[index + 1], false
    if not anchor_path then anchor_path, after = order[index - 1], true end
    local anchor
    for _, project in ipairs(self.projects or {}) do
      if project.path == anchor_path then anchor = project.row_id end
    end
    self.reorder_pending = {order = order, deadline = system.get_time() + PENDING_MOVE}
    core.log_quiet("Sidebar reorder dropped: Project=%s anchor=%s after=%s", drag.path, tostring(anchor_path),
      tostring(after))
    self.action("reorder", drag.row_id, anchor, after)
  else
    core.log_quiet("Sidebar reorder ended without a change: Project=%s commit=%s", drag.path, tostring(commit))
  end
  self:rebuild_rows()
end

-- `projects` with the loaded Projects that a drag or its pending result names put in that order. The other
-- Projects keep their places.
function SidebarView:ordered_projects(projects)
  local order = self.reorder and self.reorder.order or self.reorder_pending and self.reorder_pending.order
  if not order then return projects end
  local by_path, slots, listed = {}, {}, {}
  for index, project in ipairs(projects) do
    by_path[project.path] = project
    listed[index] = project
  end
  local named = {}
  for _, path in ipairs(order) do named[path] = by_path[path] ~= nil end
  for index, project in ipairs(projects) do
    if named[project.path] then slots[#slots + 1] = index end
  end
  local next = 0
  for _, path in ipairs(order) do
    if named[path] then
      next = next + 1
      listed[slots[next]] = by_path[path]
    end
  end
  return listed
end

-- Whether the shell's order already has the loaded Projects that `order` names in that order.
function SidebarView:has_order(order)
  local named, index = {}, 0
  for _, path in ipairs(order) do named[path] = true end
  for _, project in ipairs(self.projects or {}) do
    if named[project.path] then
      index = index + 1
      while order[index] and order[index] ~= project.path do index = index + 1 end
      if not order[index] then return false end
    end
  end
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
  if self.reorder then self:update_reorder() end
  if self.hover_y then self:update_hover() end
end

-- Whether a minute passed since the last layout, so ages and groups need an update.
function SidebarView:refresh_ages()
  local now = os.time()
  if math.floor(now / 60) == self.built_minute and not (self.next_snooze and now >= self.next_snooze) then
    return false
  end
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
  if self.reorder_pending and system.get_time() >= self.reorder_pending.deadline then self:rebuild_rows() end
  local ask = self.unload_ask
  if ask and (system.get_time() >= ask.deadline or not self:row_by_key(ask.key)) then
    ask, self.unload_ask = nil, nil
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
  -- The question slides in over its Project's row and fades out when it ends.
  local asked = self.unload_shown
  if ask then
    if not asked or asked.key ~= ask.key then asked = {key = ask.key, amount = 0} end
    asked.amount = ease(asked.amount, 1, FADE_RATE, 0.01)
  elseif asked then
    asked.amount = ease(asked.amount, 0, FADE_RATE * 1.5, 0.01)
    if asked.amount <= 0 then asked = nil end
  end
  self.unload_shown = asked
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
  -- A dragged Project scrolls only the main list, where it can move.
  local reorder = self.reorder
  if reorder and dt > 0 then
    local field, speed = self:autoscroll_speed(reorder.y)
    local before = field == "scroll" and self.scroll
    if before then
      self.scroll = before + speed * dt
      self:clamp_scroll()
    end
    if before and self.scroll ~= before then
      shown.scroll = self.scroll
      self:update_reorder()
      moving = true
    end
  end
  -- The dragged Project lifts above the list, and lands again after the drop.
  local lift = self.lift
  if lift then
    lift.amount = ease(lift.amount, self.reorder and 1 or 0, FADE_RATE, 0.01)
    if lift.amount <= 0 then
      self.lift = nil
      for _, row in ipairs(self.rows) do row.lifted = nil end
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
  shown.main_h = ease(shown.main_h, self.main_h, MOVE_RATE * ROW_SPEED)
  -- The groups' area grows and shrinks with its rows, so the rows below an expanding group stay in place.
  shown.bottom_h = ease(shown.bottom_h, self.bottom_h, MOVE_RATE * ROW_SPEED)
  shown.search = ease(shown.search, self:search_open() and 1 or 0, SEARCH_RATE, 0.01)
  -- New children keep their full spacing below the header. The next existing row reveals them as it moves down.
  -- A row that leaves fades where it was.
  local old, visuals = self.visuals, {}
  local previous
  -- The dragged Project's rows follow the pointer at once, inside the main list's loaded Projects.
  local lifted_top, lifted_base
  if reorder then
    local m = self:metrics()
    for _, row in ipairs(self.rows) do
      if row.lifted and row.kind == "project" then lifted_base = row.y - (row.gap and m.project_gap or 0) end
    end
    lifted_top = common.clamp(reorder.y - reorder.grab - self:shown_origin("main"), reorder.min or -math.huge,
      reorder.max or math.huge)
  end
  for _, row in ipairs(self.rows) do
    local key, before = row.id_key, old[row.id_key]
    local visual
    local dim = self:dim_target(row)
    if lifted_base and row.lifted then
      visual = {area = row.area, y = lifted_top + row.y - lifted_base, alpha = 1, dim = dim}
      moving = true
    elseif before and before.area == row.area and not before.entering then
      visual = {area = row.area, y = ease(before.y, row.y + (nudge[key] or 0), MOVE_RATE * ROW_SPEED),
        alpha = ease(before.alpha, 1, FADE_RATE * ROW_SPEED, 0.01), dim = ease(before.dim, dim, FADE_RATE * 1.5, 0.01)}
    elseif animate then
      local y = row.y
      if previous and previous.area == row.area then y = row.y + (previous.shown.y - previous.y) end
      visual = {area = row.area, y = y, entering = true,
        alpha = ease(before and before.alpha or 0, 1, FADE_RATE * ROW_SPEED, 0.01), dim = dim}
      moving = true
    else
      visual = {area = row.area, y = row.y, alpha = 1, dim = dim}
    end
    visuals[key] = visual
    row.shown = visual
    previous = row
  end
  local following
  for index = #self.rows, 1, -1 do
    local row = self.rows[index]
    local visual = row.shown
    if visual.entering then
      visual.clip_bottom = following and following.area == row.area and following.shown.y
        or (row.area == "main" and shown.main_h or shown.bottom_h)
      if visual.y == row.y and visual.clip_bottom >= visual.y + row.h then
        visual.entering, visual.clip_bottom = nil, nil
      end
    else
      following = row
    end
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
  -- Highlights glide from row to row and fade where no row takes them. With `jump`, a highlight goes to a new row at
  -- once. A highlight that follows the pointer stays on the screen while the list scrolls: its row ends under the
  -- pointer, so it glides only when the pointer moves to another row.
  local m = self:metrics()
  local function mark(name, row, speed, jump, follows_pointer)
    local move, fade_rate = MARK_MOVE_RATE * speed, MARK_FADE_RATE * speed
    local current = self.marks[name]
    if current and current.origin then
      local origin = self:shown_origin(current.area)
      current.y, current.origin = current.y + current.origin - origin, origin
    end
    if not row or not row.shown then
      if current then
        current.alpha = ease(current.alpha, 0, fade_rate, 0.01)
        if current.alpha <= 0 then self.marks[name] = nil end
      end
      return
    end
    local x = (row.kind == "project" or row.kind == "group" or row.kind == "empty") and m.pad or m.tab_left
    local y, origin = row.shown.y, nil
    if follows_pointer then
      origin = self:shown_origin(row.area)
      y = y + self:area_origin(row.area) - origin
    end
    if not current or current.area ~= row.area or current.alpha <= 0.01 then
      self.marks[name] = {area = row.area, x = x, y = y, h = row.h, alpha = ease(0, 1, fade_rate, 0.01),
        key = row.id_key, origin = origin}
      return
    end
    current.origin = origin
    if jump and current.key ~= row.id_key or row.lifted then
      current.x, current.y, current.h = x, y, row.h
    else
      current.x = ease(current.x, x, move)
      current.y = ease(current.y, y, move)
      current.h = ease(current.h, row.h, move)
    end
    current.key = row.id_key
    current.alpha = ease(current.alpha, 1, fade_rate, 0.01)
  end
  local active
  for _, row in ipairs(self.rows) do
    if row.selected then active = row; break end
  end
  -- A keyboard choice moves the selection at once. Its row was selected when the choice was made, so one step uses it.
  mark("active", active, SELECTION_SPEED, self.jump_selection)
  self.jump_selection = nil
  mark("cursor", self.focused and self:get_cursor() or nil, SELECTION_SPEED)
  -- While the Project area shows a Peek, the cursor's highlight reaches the Sidebar's edge and joins the shell's bead.
  local peeking = self.peek_sent ~= nil and self.peek_sent.id ~= 0
  self.peek_join = ease(self.peek_join or 0, peeking and 1 or 0, FADE_RATE, 0.01)
  mark("hover", self.hover, HOVER_SPEED, false, true)
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
    if row.key and (row.kind ~= "project" or row.project.scratch) then
      local target = row.collapsed and 0 or 1
      self.chevrons[row.key] = ease(self.chevrons[row.key], target, MOVE_RATE * 0.8, 0.01)
    end
  end
  -- Attention Pills fade in and out at their edges. A drag scrolls at the edges, so it hides them.
  local live, order = {}, self.drag == nil and self.reorder == nil and self:offscreen_attention() or {}
  for _, item in ipairs(order) do live[item.id] = item end
  local pills = {}
  for _, entry in ipairs(self.pills or {}) do
    local item = live[entry.item.id]
    if item then entry.item, live[item.id] = item, nil end
    entry.alpha = ease(entry.alpha, item and 1 or 0, FADE_RATE, 0.01)
    if entry.alpha > 0 then pills[#pills + 1] = entry end
  end
  for _, item in ipairs(order) do
    if live[item.id] then pills[#pills + 1] = {item = item, alpha = ease(0, 1, FADE_RATE, 0.01)} end
  end
  self.pills = pills
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

-- Working agents and Terminals with a Snooze stay dim unless selected. Other Windows' Projects and their children
-- also stay dim, except the Scratch Project, which follows the user.
-- A dragged or moved Tab dims further at its old place.
function SidebarView:dim_target(row)
  local key = row.id_key
  local drag, pending = self.drag, self.pending
  if drag and drag.key == key or pending and pending.key == key then return 0.35 end
  if not row.selected and (row.snooze or row.agent and not row.agent.command
    and tab.working(row.tab.terminal or {}, row.agent)) then return 0.5 end
  if row.project and not row.project.scratch and in_other_window(row.project, self.window_id) then return 0.5 end
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
  if area == "bottom" then return self:bottom_area(shown.bottom_h) - (shown.bottom_scroll or self.bottom_scroll) end
  return self:shown_list_top() - (shown.scroll or self.scroll)
end

------------------------------------------------------------------------------------------------------------------
-- Drawing

-- The color with its alpha scaled. The color itself when the scale is 1, so callers can compare it.
local function fade(color, amount)
  if amount >= 1 then return color end
  return {color[1], color[2], color[3], (color[4] or 255) * amount}
end

-- The radius of a Terminal Tab's attention dot, before scaling.
local ATTENTION_DOT = 3

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

-- What a row shows that needs the user: the attention kind, and how many Terminals it stands for. A Terminal's mark
-- counts one. A Dormant Project's or collapsed age group's pill counts its Terminals, which show no rows. A collapsed
-- loaded Project still shows its Terminals that need the user, so its pill does not count. Nil when the row needs
-- nothing.
local function row_need(row)
  if row.attention then return row.attention, 1 end
  local pending = row.pending
  if pending and (row.kind == "group" and row.collapsed
    or row.kind == "project" and row.project.state == "dormant" and not row.project.scratch) then
    return pending.kind, pending.count
  end
end

-- The Attention Pills: for each edge of a scrolling area that hides rows that need the user, a pill with their
-- count. `target` is the hidden row nearest the edge. A question sets the pill's kind, as in a pending count.
function SidebarView:offscreen_attention()
  local key = self.rows
  local cache = self.attention_cache
  if cache and cache.rows == key and cache.scroll == self.scroll and cache.bottom_scroll == self.bottom_scroll
    and cache.width == self.width and cache.height == self.view_h and cache.top == self:list_top() then
    return cache.marks
  end
  local font = font_variant("small")
  local h = font:get_height() + 4 * SCALE
  local inset = 6 * SCALE
  local bottom_top = self:bottom_area()
  local spans = {main = {self:list_top(), self:main_bottom()}, bottom = {bottom_top, self.view_h}}
  local found = {}
  for index, row in ipairs(self.rows) do
    local kind, count = row_need(row)
    local span = kind and spans[row.area]
    if span then
      local centre = self:row_y(index) + row.h / 2
      local edge = centre < span[1] and "top" or centre > span[2] and "bottom" or nil
      if edge then
        local id = row.area .. ":" .. edge
        local item = found[id]
        if not item then
          item = {area = row.area, edge = edge, count = 0, id = id}
          found[id], found[#found + 1] = item, item
        end
        item.count = item.count + count
        if not item.kind or kind == "blocked" then item.kind = kind end
        -- The nearest hidden row: the last one above the top, or the first one below the bottom.
        if edge == "top" or not item.target then item.target = index end
      end
    end
  end
  local marks = {}
  for _, item in ipairs(found) do
    local span = spans[item.area]
    local label = tostring(item.count)
    item.label, item.h = label, h
    item.w = math.floor(font:get_width(label) + h + 8 * SCALE)
    item.x = math.floor((self.width - item.w) / 2)
    item.y = math.floor(item.edge == "top" and span[1] + inset or span[2] - inset - h)
    marks[#marks + 1] = item
  end
  self.attention_cache = {rows = key, scroll = self.scroll, bottom_scroll = self.bottom_scroll, width = self.width,
    height = self.view_h, top = self:list_top(), marks = marks}
  return marks
end

-- The Attention Pill at the point.
function SidebarView:attention_pill_at(x, y)
  for _, item in ipairs(self:offscreen_attention()) do
    if x >= item.x and x < item.x + item.w and y >= item.y and y < item.y + item.h then return item end
  end
end

-- A click on an Attention Pill scrolls to the nearest hidden row, clear of a pill at the same edge.
function SidebarView:open_attention_pill(item)
  self:reveal_row(item.target, item.h + 12 * SCALE)
  core.log_quiet("Sidebar Attention Pill: area=%s edge=%s count=%d", item.area, item.edge, item.count)
end

-- Each Attention Pill floats over the rows at its edge, with a shadow: an arrow toward the hidden rows and their count.
function SidebarView:draw_attention_pills()
  local font = font_variant("small")
  for _, entry in ipairs(self.pills or {}) do
    local item, alpha = entry.item, entry.alpha
    local x, y, w, h = item.x, item.y, item.w, item.h
    for i = 3, 1, -1 do
      local spread = i * SCALE
      renderer.draw_rounded_rect(x - spread, y - spread + SCALE, w + 2 * spread, h + 2 * spread, h / 2 + spread,
        fade(style.sidebar_shadow, alpha * (4 - i) / 8))
    end
    renderer.draw_rounded_rect(x, y, w, h, h / 2, fade(tab.attention_color(item.kind), alpha))
    local color = fade(style.background, alpha)
    local size, cx, cy = h * 0.2, x + h / 2 + SCALE, y + h / 2
    local d = item.edge == "top" and -1 or 1
    renderer.draw_poly({{cx - size * 1.2, cy - d * size * 0.6}, {cx + size * 1.2, cy - d * size * 0.6},
      {cx, cy + d * size * 0.8}}, color)
    -- The digits' ink centres in the pill, as in a pending count.
    local ink_top, ink_bottom = font:get_ink_extent(item.label)
    local ty = ink_top and y + (h - ink_top - ink_bottom) / 2 or y + 2 * SCALE
    text(item.label, x + h + SCALE, math.floor(ty + 0.5), color, font)
  end
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
  if self.unload_ask then delay = math.min(delay or math.huge, math.max(0, self.unload_ask.deadline - clock)) end
  return delay
end

-- Draws a label shortened before a right-aligned note, then the note. The note keeps the same inset from the
-- row highlight's right edge as the row's content keeps from its left edge. The first hint that fits follows the
-- label in the dim colour. `mark_w` keeps that much space free after the label, for the caller to draw a mark in.
-- Returns the label's right edge.
function SidebarView:label_with_note(label, color, note, x, y, row, right, hints, font, note_color, mark_w)
  mark_w = mark_w or 0
  font = font or style.font
  local ty = y + math.floor((row.h - font:get_height()) / 2)
  local note_ty = y + math.floor((row.h - style.font:get_height()) / 2)
  right = right - 8 * SCALE
  local note_w = note and style.font:get_width(note) + 8 * SCALE or 0
  if note_w > (right - x) / 2 then note, note_w = nil, 0 end
  local available = math.max(0, right - x - note_w)
  label = tab.fit(font, label, math.max(0, available - mark_w))
  text(label, x, ty, color, font)
  local label_end = x + font:get_width(label)
  local hint_x = label_end + mark_w + 8 * SCALE
  for _, hint in ipairs(hints or {}) do
    if hint_x + style.font:get_width(hint) <= x + available then
      text(hint, hint_x, note_ty, style.dim)
      break
    end
  end
  if note then text(note, right - note_w + 8 * SCALE, note_ty, note_color or style.dim) end
  return label_end
end

-- The count of a hidden Project's or group's Terminals that need the user: a pill in their attention colour, which
-- ends at `right`, or centres on `centre`. Returns the pill's left edge.
function SidebarView:draw_pending(pending, right, cy, centre)
  local font = font_variant("small")
  local label = tostring(pending.count)
  local h = font:get_height()
  local w = math.max(h, font:get_width(label) + 6 * SCALE)
  if centre then right = math.floor(centre + w / 2 + 0.5) end
  local y = math.floor(cy - h / 2)
  renderer.draw_rounded_rect(right - w, y, w, h, h / 2, tab.attention_color(pending.kind))
  -- The digits' ink centres in the pill, as a badge's letter does. Their line box has room for descenders.
  local ink_top, ink_bottom = font:get_ink_extent(label)
  local ty = ink_top and y + (h - ink_top - ink_bottom) / 2 or y + SCALE
  text(label, right - w + math.floor((w - font:get_width(label)) / 2), math.floor(ty + 0.5), style.background, font)
  return right - w
end

-- A section header: a chevron when it folds, a small uppercase label, a line and a count. A collapsed group also
-- shows the count of its Terminals that need the user.
function SidebarView:draw_section(row, x, y, right)
  local cy = y + row.h / 2
  local hovered = self.hover == row
  local color = hovered and style.text or style.dim
  if row.key then chevron(x + 4 * SCALE, cy, self.chevrons[row.key], color) end
  local font = font_variant("small")
  local label = row.label:upper()
  local lx = x + 14 * SCALE
  local count = row.count and tostring(row.count) or ""
  local count_w = font:get_width(count)
  right = right - 8 * SCALE
  label = tab.fit(font, label, math.max(0, right - count_w - 12 * SCALE - lx))
  local ty = y + math.floor((row.h - font:get_height()) / 2)
  text(label, lx, ty, color, font)
  text(count, right - count_w, ty, style.dim, font)
  local line_x = lx + font:get_width(label) + 8 * SCALE
  local line_right = right - count_w - 8 * SCALE
  if row.pending and row.collapsed then line_right = self:draw_pending(row.pending, line_right, cy) - 6 * SCALE end
  if line_right > line_x then
    renderer.draw_rect(line_x, math.floor(cy), line_right - line_x, math.max(1, math.floor(SCALE)), style.divider)
  end
end

function SidebarView:draw_project(row, y, width, now)
  local m = self:metrics()
  local cy = y + row.h / 2
  local left, right = m.pad, width - m.pad
  local project = row.project
  local dormant = project.state == "dormant"
  local asked = self.unload_shown
  local asking = asked and asked.key == row.id_key and asked.amount
  if asking then
    -- A tint slides in from the left.
    renderer.draw_rounded_rect(left, y + 1, math.max(2 * m.radius, (right - left) * asking), row.h - 2, m.radius,
      fade(style.warn, 0.16 * asking))
  end
  -- Keep the badge dim, including for the Window's Selected Project.
  local size = m.badge
  local bx = left + 6 * SCALE
  look.draw_badge(project, bx, math.floor(cy - size / 2), size, font_variant("bold"), style.background2)
  -- The pill centres on the column of its Terminals' attention dots.
  if row.pending and (row.collapsed or dormant) then
    local tx, tw = self:tab_bounds(row, width)
    right = self:draw_pending(row.pending, nil, cy, tx + tw - ATTENTION_DOT * SCALE)
  end
  local note = look.note(project, self.window_id, now)
  local hints
  if dormant then
    hints = {look.terminal_hint(project)}
  elseif row.collapsed and (row.tabs or 0) > 0 then
    hints = {row.tabs .. (row.tabs == 1 and " tab" or " tabs")}
  end
  local note_color
  if asking then note, note_color = "Unload?", fade(style.warn, asking) end
  local name_color = dormant and not project.exists and style.dim or style.text
  -- A collapsed Project that can open shows a chevron after its name.
  local folded = row.key and row.collapsed
  local name_end = self:label_with_note(look.name(project), name_color, note, bx + size + 8 * SCALE, y, row, right,
    hints, dormant and style.font or font_variant("bold"), note_color, folded and 11 * SCALE or nil)
  if folded then chevron(name_end + 8.5 * SCALE, cy, 0, self.hover == row and style.text or style.dim) end
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
  -- The Scratch Project is a list of loose Tabs, not a folder, so it draws as a section, not as a Project.
  if row.kind == "project" and row.project.scratch then
    self:draw_section(row, left + 4 * SCALE, y, right)
    return
  end
  if row.kind == "terminal_group" then
    -- The Snoozed fold carries the mark of a Snoozed Pane that needs the user.
    if row.attention then self:draw_attention(row, y, width) end
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

-- A small clock, the Snooze icon, at the left edge `x` of a line centred at `cy`. Returns its width.
local function clock(x, cy, color)
  local size = math.floor(style.font:get_height() * 0.6 + 0.5)
  local stroke = math.max(1, math.floor(1.25 * SCALE + 0.5))
  local y, half = math.floor(cy - size / 2), math.floor(size / 2)
  x = math.floor(x)
  ring(x, y, size, size, size / 2, stroke, color)
  renderer.draw_rect(x + half - stroke / 2, y + 3 * stroke, stroke, half - 3 * stroke, color)
  renderer.draw_rect(x + half - stroke / 2, y + half - stroke / 2, half - 2 * stroke, stroke, color)
  return size
end

-- A Snooze's note, right-aligned at `right` on a line centred at `cy`: the clock and `label`. Returns its width.
local function draw_snooze(label, right, cy)
  local font = style.font
  local label_w = font:get_width(label)
  text(label, right - label_w, math.floor(cy - font:get_height() / 2), style.dim)
  local size = math.floor(font:get_height() * 0.6 + 0.5)
  clock(right - label_w - 4 * SCALE - size, cy, style.dim)
  return snooze_note_width(label)
end

-- A Tab's or Terminal Session's content in [x, x + width): its icon, name and status, and an agent's step below.
function SidebarView:draw_tab(row, x, y, width, now)
  local m = self:metrics()
  -- A working Terminal shimmers its agent's line, or its name when it has no such line.
  local shimmer = tab.working(row.tab.terminal or {}, row.agent) and self:shimmer_phase() or nil
  -- A Terminal that needs the user has a dot at the right edge of its name's line and a bold name.
  local name_font, right = nil, x + width
  local note = row.snooze and snooze_text(row.snooze, now) or row.woke and woke_text(row.woke, now)
  if note then
    width = width - draw_snooze(note, x + width, y + m.terminal / 2) - 6 * SCALE
  end
  if row.attention then
    local radius = ATTENTION_DOT * SCALE
    dot(x + width - radius, y + m.terminal / 2, radius, tab.attention_color(row.attention))
    width = width - radius * 2 - 6 * SCALE
    name_font = font_variant("bold")
  end
  -- A Snooze's note replaces the Terminal's age.
  local spinning, name_x = tab.draw(row.tab, x, y, width, m.terminal, {name_color = style.text, now = now,
    clock = self.clock, name_font = name_font, note = not note, dir = true, number_font = font_variant("number"), number_gutter = m.number_gutter, shimmer = not row.agent and shimmer or nil})
  if spinning then self.spinning = true end
  local unread = row.attention == "done" or row.attention == "error"
  if row.agent and tab.draw_agent(row.agent, name_x, y + m.terminal - 6 * SCALE, right - name_x,
      m.terminal, {now = now, unread = unread, shimmer = shimmer}) then
    self.ticking = true
  end
end

-- Pane Groups with several Panes: a rail beside their Tabs, in the accent colour for the visible group. A drop line
-- inside a group tints its Tabs: the new Pane joins that group.
function SidebarView:draw_containers(area, width, lifted)
  local m = self:metrics()
  local origin = self:shown_origin(area)
  local drop, mark = self:drop_target(), self.marks.drop
  local join = drop and drop.kind == "line" and drop.inset and mark and drop.row.id_key
  local first, joined
  for _, row in ipairs(self.rows) do
    if row.area == area and row.bracket and row.shown and (row.lifted or false) == lifted then
      if row.bracket.first or not first then first, joined = row, false end
      joined = joined or row.id_key == join
      if row.bracket.last then
        local top = origin + first.shown.y
        local bottom = origin + row.shown.y + row.h
        if row.shown.clip_bottom then bottom = math.min(bottom, origin + row.shown.clip_bottom) end
        local alpha = math.min(first.shown.alpha * first.shown.dim, row.shown.alpha * row.shown.dim)
        local x, w = m.tab_left, width - m.pad - m.tab_left
        if joined and bottom - top > 2 then
          renderer.draw_rounded_rect(x, top + 1, w, bottom - top - 2, m.radius,
            fade(style.drop_target_background, alpha * mark.alpha))
        end
        if bottom - top > 12 * SCALE then
          renderer.draw_rect(m.rail_x, top + 6 * SCALE, m.rail, bottom - top - 12 * SCALE,
            fade(row.bracket.visible and style.titlebar_group_indicator or style.divider, alpha))
        end
        first = nil
      end
    end
  end
end

-- `reach` from 0 to 1 extends the highlight to the right edge, where the clip squares its corners.
function SidebarView:draw_mark(name, area, width, color, lifted, reach)
  local mark = self.marks[name]
  if not mark or mark.area ~= area or mark.alpha <= 0.01 then return end
  local visual = self.visuals[mark.key]
  if (visual and visual.row and visual.row.lifted or false) ~= lifted then return end
  local m = self:metrics()
  local y = self:shown_origin(area) + mark.y
  local h = mark.h - 2
  if visual and visual.clip_bottom then h = math.min(h, self:shown_origin(area) + visual.clip_bottom - y - 1) end
  if h > 0 then
    local right = width - m.pad + (m.pad + m.radius) * (reach or 0)
    renderer.draw_rounded_rect(mark.x, y + 1, right - mark.x, h, m.radius, fade(color, mark.alpha))
  end
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

-- The dragged Project and its children, above the other rows on a card with a shadow that deepens as it lifts.
function SidebarView:draw_lifted(width, active_color, now)
  local lift = self.lift
  if not lift then return end
  local top, bottom
  for _, row in ipairs(self.rows) do
    if row.lifted then
      top = math.min(top or math.huge, row.shown.y)
      bottom = math.max(bottom or -math.huge, row.shown.y + row.h)
    end
  end
  if not top then return end
  local m = self:metrics()
  local origin = self:shown_origin("main")
  local x, w = m.pad - 2 * SCALE, width - 2 * m.pad + 4 * SCALE
  local y, h = math.floor(origin + top + 0.5), math.floor(bottom - top + 0.5)
  local amount = lift.amount
  for i = 3, 1, -1 do
    local spread = i * SCALE
    renderer.draw_rounded_rect(x - spread, y - spread + 2 * SCALE * amount, w + 2 * spread, h + 2 * spread,
      m.radius + spread, fade(style.sidebar_shadow, amount * (4 - i) / 6))
  end
  renderer.draw_rounded_rect(x, y, w, h, m.radius, fade(style.sidebar_card, amount))
  self:draw_containers("main", width, true)
  self:draw_mark("active", "main", width, active_color, true)
  self:draw_mark("cursor", "main", width, style.sidebar_cursor, true)
  for _, row in ipairs(self.rows) do
    if row.lifted then self:draw_shown(row, origin + row.shown.y, row.shown.alpha * row.shown.dim, width, now) end
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
-- while it closes. The hours field for a Snooze shows in its place.
function SidebarView:draw_search(width, height)
  local open = self.shown.search
  local input = self:field()
  if self:search_open() then
    self.shown_input = {text = input.text, caret = input.caret, anchor = input.anchor, hours = self.hours ~= nil}
  end
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
  if shown.hours then
    clock(ix + (icon:get_width("L") - style.font:get_height() * 0.6) / 2, y + h / 2, style.accent)
  else
    text("L", ix, y + math.floor((h - icon:get_height()) / 2), style.accent, icon)
  end
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
  if shown.hours and shown.text == "" then text("Hours", tx + SCALE + caret_w * 2, ty, style.dim) end
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
  local top, main_bottom = self:shown_list_top(), self:main_bottom(self.shown.bottom_h)
  local bottom_top = self:bottom_area(self.shown.bottom_h)
  local active_color = self.focused and style.sidebar_selection_behind or style.sidebar_selection
  for _, area in ipairs({{"main", top, main_bottom}, {"bottom", bottom_top, height}}) do
    local name, area_top, area_bottom = area[1], area[2], area[3]
    renderer.set_clip_rect(0, area_top, width, math.max(0, area_bottom - area_top))
    self:draw_containers(name, width, false)
    self:draw_mark("hover", name, width, style.sidebar_hover, false)
    self:draw_mark("active", name, width, active_color, false)
    self:draw_mark("cursor", name, width, style.sidebar_cursor, false, self.peek_join)
    self:draw_drop(name, false)
    local origin = self:shown_origin(name)
    for _, item in ipairs(self.leaving) do
      if item.area == name then self:draw_shown(item.row, origin + item.y, item.alpha, width, now) end
    end
    for _, row in ipairs(self.rows) do
      if row.area == name and not row.lifted then
        local y = origin + row.shown.y
        if y + row.h > area_top and y < area_bottom then
          local clip_bottom = row.shown.clip_bottom and math.min(area_bottom, origin + row.shown.clip_bottom)
          if clip_bottom then renderer.set_clip_rect(0, area_top, width, math.max(0, clip_bottom - area_top)) end
          self:draw_shown(row, y, row.shown.alpha * row.shown.dim, width, now)
          if clip_bottom then renderer.set_clip_rect(0, area_top, width, math.max(0, area_bottom - area_top)) end
        end
      end
    end
    self:draw_drop(name, true)
    if name == "main" then self:draw_lifted(width, active_color, now) end
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
  self:draw_attention_pills()
  self:draw_card(width, height, now)
  self.focus_feedback:draw(0, 0, width, height, self.clock)
  self:draw_tooltip(width, height)
end

return SidebarView
