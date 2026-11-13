-- The results of a Query, as Tabs. Each Tab is a Results View that shows one result of a run. A new run replaces
-- the Tabs that are not kept. A dragged Tab moves within the Tabs, to the Tabs of other results, or to a new Pane.
-- The Tabs draw like the Title Bar's Tabs, with the same code.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local tab = require "core.tab"
local View = require "core.view"
local panes = require "core.panes"
local Results = require "plugins.sql_server.results"

local ResultTabs = View:extend()
function ResultTabs:__tostring() return "SQLResultTabs" end
ResultTabs.view_icon = Results.view_icon

local DRAG_THRESHOLD = 6

local function index_of(list, value)
  for i, item in ipairs(list) do
    if item == value then return i end
  end
end

local function contains(rect, x, y)
  return rect and x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end

function ResultTabs:new(connection_name)
  ResultTabs.super.new(self)
  self.connection_name = connection_name
  self.tabs, self.tab_rects, self.targets = {}, {}, {}
  self.tab_scroll = 0
  self.cursor = "arrow"
end

-- The shown Tab's Results View.
function ResultTabs:current() return self.shown end
function ResultTabs:get_name()
  return self.shown and self.shown:get_name() or "SQL Results · " .. self.connection_name
end
function ResultTabs:get_state() return nil end
function ResultTabs:get_focus_view() return self.shown end
function ResultTabs:get_surface_focus_targets() return self.targets end

-- Whether the keyboard is in these results.
function ResultTabs:has_focus()
  local active = core.active_view
  return active == self or (active ~= nil and active.host == self)
end

function ResultTabs:add(view, index)
  table.insert(self.tabs, index or #self.tabs + 1, view)
  view.host = self
  panes.register_focus_target(self, view)
  core.redraw = true
end

-- Takes the Tab out and returns its place. The caller selects another Tab.
function ResultTabs:take(view)
  local index = index_of(self.tabs, view)
  if not index then return nil end
  table.remove(self.tabs, index)
  view.host = nil
  panes.unregister_focus_target(view)
  if self.shown == view then self.shown, self.targets[1] = nil, nil end
  core.redraw = true
  return index
end

function ResultTabs:select(view, focus)
  self.shown, self.targets[1] = view, view
  core.redraw = true
  local pane = focus and view and panes.pane_for_view(self)
  if pane then panes.focus(pane) end
end

-- Results without Tabs close their View.
function ResultTabs:close_if_empty()
  if #self.tabs > 0 then return end
  local pane = panes.pane_for_view(self)
  if pane then panes.close_view(pane, { view = self, force = true, focus = false }) end
end

function ResultTabs:close_tab(view)
  local focus = self:has_focus()
  local index = self:take(view)
  if not index then return false end
  view:on_close()
  if not self.shown then self:select(self.tabs[index] or self.tabs[index - 1], focus) end
  self:close_if_empty()
  return true
end

-- A run replaces the Tabs that are not kept with one Tab, which shows its progress.
function ResultTabs:begin_run(buffer, connection_name, cancel, explain, text)
  local focus = self:has_focus()
  local index
  for i = #self.tabs, 1, -1 do
    local view = self.tabs[i]
    if not view.kept then
      index = self:take(view)
      view:on_close()
    end
  end
  local view = Results(connection_name)
  view.source_buffer = buffer
  view:begin_run(cancel, explain, text)
  self:add(view, index)
  self:select(view, focus)
  core.add_thread(function()
    while view.cancel_query and not view.closed do
      core.redraw = true
      coroutine.yield(tab.spinner_delay(system.get_time()))
    end
    core.redraw = true
  end)
  return view
end

-- Each result of the run gets its own Tab, after the run's Tab, which shows the first result.
function ResultTabs:complete(view, data)
  local index = index_of(self.tabs, view)
  if not index then return end
  view:complete(data)
  for result = 2, data.results and #data.results or 0 do
    local more = Results(view.connection_name)
    more.source_buffer, more.kind, more.run_text = view.source_buffer, view.kind, view.run_text
    more:complete(data, result)
    self:add(more, index + result - 1)
  end
end

-- The Tab strip is as tall as a row of interface text.
function ResultTabs:strip_height()
  return math.floor(style.font:get_height() + style.padding.y * 2)
end

function ResultTabs:in_strip(x, y)
  return x >= self.position.x and x < self.position.x + self.size.x
    and y >= self.position.y and y < self.position.y + self:strip_height()
end

function ResultTabs:tab_at(x, y)
  if not self:in_strip(x, y) then return nil end
  for i, rect in ipairs(self.tab_rects) do
    if contains(rect, x, y) then return i end
  end
end

function ResultTabs:update()
  local h = self:strip_height()
  local total = 0
  for i, view in ipairs(self.tabs) do
    local rect = self.tab_rects[i] or {}
    self.tab_rects[i] = rect
    rect.w = tab.bar_width(view:tab_item(), h)
    rect.x, rect.y, rect.h = total, self.position.y, h
    total = total + rect.w
  end
  for i = #self.tabs + 1, #self.tab_rects do self.tab_rects[i] = nil end
  -- A newly shown Tab scrolls into view.
  local shown = index_of(self.tabs, self.shown)
  if shown and self.scrolled_to ~= self.shown then
    self.scrolled_to = self.shown
    local rect = self.tab_rects[shown]
    self.tab_scroll = common.clamp(self.tab_scroll, rect.x + rect.w - self.size.x, rect.x)
  end
  self.tab_scroll = common.clamp(self.tab_scroll, 0, math.max(0, total - self.size.x))
  for _, rect in ipairs(self.tab_rects) do rect.x = self.position.x + rect.x - self.tab_scroll end
  local view = self.shown
  if view then
    view.position.x, view.position.y = self.position.x, self.position.y + h
    view.size.x, view.size.y = self.size.x, math.max(0, self.size.y - h)
    view:update()
  end
  ResultTabs.super.update(self)
end

-- A running Tab turns its spinner.
local spun = {}
local function shown_item(item, clock)
  local name = tab.spinner_title(item.name, clock)
  if not name then return item end
  spun.number, spun.icon, spun.name = item.number, item.icon, name
  return spun
end

local function draw_label(item, rect, color)
  local opts = tab.bar_fonts()
  opts.name_color, opts.clock = color, system.get_time()
  tab.draw(shown_item(item, opts.clock), rect.x + style.padding.x, rect.y, math.max(0, rect.w - style.padding.x * 2),
    rect.h, opts)
end

-- While a Tab moves, its tile follows the pointer above all Panes, and the place where it would go shows.
local function draw_drag(self)
  local drag = self.drag
  if not drag then return end
  local rect = drag.target and drag.target.rect
  if rect then
    renderer.draw_rect(rect.x, rect.y, rect.w, rect.h, drag.target.line and style.drag_overlay_tab or style.drag_overlay)
  end
  local h = self:strip_height()
  local item = drag.view:tab_item()
  local tile = { w = tab.bar_width(item, h), h = h }
  local root = core.root_panel
  tile.x = common.clamp(drag.x - tile.w / 2, root.position.x, math.max(root.position.x, root.position.x + root.size.x - tile.w))
  tile.y = common.clamp(drag.y - h / 2, root.position.y, math.max(root.position.y, root.position.y + root.size.y - h))
  core.push_clip_rect(tile.x, tile.y, tile.w, tile.h)
  tab.draw_tile(tile.x, tile.y, tile.w, tile.h, style.titlebar)
  tab.draw_tile(tile.x, tile.y, tile.w, tile.h, style.titlebar_tab_hover)
  draw_label(item, tile, style.text)
  core.pop_clip_rect()
end

function ResultTabs:draw()
  local x, y, h = self.position.x, self.position.y, self:strip_height()
  renderer.draw_rect(x, y, self.size.x, h, style.titlebar)
  core.push_clip_rect(x, y, self.size.x, h)
  for i, view in ipairs(self.tabs) do
    local rect = self.tab_rects[i]
    if rect then
      local shown, hovered = view == self.shown, self.hovered == i and not self.drag
      if shown then tab.draw_tile(rect.x, rect.y, rect.w, rect.h, style.titlebar_tab_active) end
      if hovered then
        tab.draw_tile(rect.x, rect.y, rect.w, rect.h,
          self.pressed == view and style.titlebar_control_pressed or style.titlebar_tab_hover)
      end
      draw_label(view:tab_item(), rect, (shown or hovered) and style.text or style.dim)
    end
  end
  core.pop_clip_rect()
  local view = self.shown
  if view then
    core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
    view:draw()
    core.pop_clip_rect()
  else
    renderer.draw_rect(x, y + h, self.size.x, math.max(0, self.size.y - h), style.background)
  end
  if self.drag then core.root_panel:defer_draw(draw_drag, self) end
end

-- Where a dragged Tab goes at a point: `tabs` in the Tabs of `host` before `index`, `split` beside `pane`, or `new`
-- for a new Pane over the Title Bar. Nil leaves it where it is. `rect` shows the place.
function ResultTabs:insert_index(x)
  for i, rect in ipairs(self.tab_rects) do
    if x < rect.x + rect.w / 2 then return i end
  end
  return #self.tabs + 1
end

function ResultTabs:insert_rect(index)
  local rect = self.tab_rects[index]
  local last = self.tab_rects[#self.tab_rects]
  local x = rect and rect.x or last and last.x + last.w or self.position.x
  local width = math.max(2, math.floor(2 * SCALE))
  return { x = x - width / 2, y = self.position.y + tab.TOP_INSET, w = width,
    h = math.max(1, self:strip_height() - tab.TOP_INSET) }
end

function ResultTabs:drop_target(view, x, y)
  local bar = core.title_bar
  if bar and bar.size.y > 0 and y >= bar.position.y and y < bar.position.y + bar.size.y then
    if #self.tabs == 1 then return nil end
    return { kind = "new", rect = { x = bar.position.x, y = bar.position.y, w = bar.size.x, h = bar.size.y } }
  end
  local pane, direction = panes.drop_target_at(x, y)
  if not pane then return nil end
  local host = pane.current_view
  if host:is(ResultTabs) and host:in_strip(x, y) then
    local index = host:insert_index(x)
    local from = host == self and index_of(self.tabs, view)
    if from and (index == from or index == from + 1) then return nil end
    return { kind = "tabs", host = host, index = index, rect = host:insert_rect(index), line = true }
  end
  if host:is(ResultTabs) and direction == "center" then
    if host == self then return nil end
    return { kind = "tabs", host = host, index = #host.tabs + 1,
      rect = { x = host.position.x, y = host.position.y, w = host.size.x, h = host.size.y } }
  end
  if direction == "center" or (pane == panes.pane_for_view(self) and #self.tabs == 1) then return nil end
  local rect = { x = pane.position.x, y = pane.position.y, w = pane.size.x, h = pane.size.y }
  if direction == "left" then rect.w = rect.w * 0.3
  elseif direction == "right" then rect.x, rect.w = rect.x + rect.w * 0.7, rect.w * 0.3
  elseif direction == "up" then rect.h = rect.h * 0.3
  else rect.y, rect.h = rect.y + rect.h * 0.7, rect.h * 0.3 end
  return { kind = "split", pane = pane, direction = direction, rect = rect }
end

-- Moves a Tab to the target. A Tab that leaves its results is kept, so a later run does not replace it there.
function ResultTabs:move(view, target)
  if target.kind == "tabs" and target.host == self then
    local from = index_of(self.tabs, view)
    table.remove(self.tabs, from)
    table.insert(self.tabs, target.index > from and target.index - 1 or target.index, view)
    core.redraw = true
    return true
  end
  local focus = self:has_focus()
  local index = self:take(view)
  if not index then return false end
  view:keep()
  if not self.shown then self:select(self.tabs[index] or self.tabs[index - 1], false) end
  if target.kind == "tabs" then
    target.host:add(view, target.index)
    target.host:select(view, true)
  else
    local host = ResultTabs(view.connection_name)
    host:add(view)
    host:select(view)
    local placed = panes.place(function() return host end, target.kind == "new" and { placement = "new", focus = true }
      or { pane = target.pane, placement = "split", direction = target.direction, focus = true })
    if not placed then
      host:take(view)
      self:add(view, index)
      self:select(view, focus)
      return false
    end
  end
  core.log_quiet("SQL Server: moved a result Tab to %s", target.kind)
  self:close_if_empty()
  return true
end

-- A results Pane that the Title Bar drags over the Tabs joins them.
function ResultTabs:pane_drop_target(source, x, y)
  local from = source.current_view
  if from == self or not from:is(ResultTabs) or not self:in_strip(x, y) then return nil end
  for _, view in ipairs(from.tabs) do
    if view.cancel_query then return nil end
  end
  local index = self:insert_index(x)
  return { index = index, rect = self:insert_rect(index) }
end

function ResultTabs:accept_pane_drop(source, target)
  local from = source.current_view
  local shown, moved = from.shown, {}
  for i, view in ipairs(from.tabs) do moved[i] = view end
  for i, view in ipairs(moved) do
    from:take(view)
    view:keep()
    self:add(view, target.index + i - 1)
  end
  self:select(shown or moved[1], true)
  core.log_quiet("SQL Server: joined %d result Tab(s)", #moved)
  from:close_if_empty()
  return true
end

local icons = require("core.context_menu").icons
local TAB_MENU = {
  { label = "Keep Result", command = "sql_server:keep_result" },
  { label = "Close Result", icon = icons.close, command = "sql_server:close_result" },
  { label = "Close Other Results", icon = icons.close_others, command = "sql_server:close_other_results" },
  "-",
  { label = "Move to Split Right", icon = icons.split_right, command = "sql_server:move_result_to_split_right" },
  { label = "Move to Split Down", icon = icons.split_down, command = "sql_server:move_result_to_split_down" },
}

function ResultTabs:on_mouse_pressed(button, x, y, clicks)
  if self:in_strip(x, y) then
    local view = self.tabs[self:tab_at(x, y) or 0]
    if not view then return true end
    if button == "middle" then return self:close_tab(view) end
    self:select(view, true)
    if button == "right" then
      require("core.context_menu").open(x, y, TAB_MENU, { button = "right" })
    elseif button == "left" then
      self.pressed, self.press_x, self.press_y = view, x, y
    end
    return true
  end
  local view = self.shown
  return view and view:on_mouse_pressed(button, x, y, clicks)
end

function ResultTabs:on_mouse_moved(x, y, dx, dy)
  self.mouse_x, self.mouse_y = x, y
  if self.pressed then
    if not self.drag and not self.pressed.cancel_query
        and common.distance(x, y, self.press_x, self.press_y) >= DRAG_THRESHOLD * SCALE then
      self.drag = { view = self.pressed }
      core.log_quiet("SQL Server: result Tab drag started")
    end
    if self.drag then
      self.drag.x, self.drag.y = x, y
      self.drag.target = self:drop_target(self.drag.view, x, y)
      self.cursor = "hand"
      core.redraw = true
    end
    return true
  end
  local hovered = self:tab_at(x, y)
  if hovered ~= self.hovered then self.hovered = hovered; core.redraw = true end
  local view = self.shown
  if self:in_strip(x, y) then
    if view and self.child_hovered then view:on_mouse_left() end
    self.child_hovered, self.cursor = false, "arrow"
    return true
  end
  if not view then return end
  self.child_hovered = true
  local result = view:on_mouse_moved(x, y, dx, dy)
  self.cursor = view.cursor
  return result
end

function ResultTabs:on_mouse_released(button, x, y)
  if self.pressed then
    local drag = self.drag
    self.pressed, self.drag, self.cursor = nil, nil, "arrow"
    core.redraw = true
    if drag and drag.target then self:move(drag.view, drag.target) end
    return true
  end
  local view = self.shown
  return view and view:on_mouse_released(button, x, y)
end

function ResultTabs:on_mouse_left()
  self.hovered, self.child_hovered = nil, false
  core.redraw = true
  if self.shown then return self.shown:on_mouse_left() end
end

function ResultTabs:on_mouse_wheel(y, x)
  if self.mouse_x and self:in_strip(self.mouse_x, self.mouse_y) then
    local delta = x and x ~= 0 and x or y
    self.tab_scroll = self.tab_scroll - (delta or 0) * 60 * SCALE
    core.redraw = true
    return true
  end
  return self.shown and self.shown:on_mouse_wheel(y, x)
end

function ResultTabs:scrollbar_overlaps_point(x, y)
  return self.shown ~= nil and self.shown:scrollbar_overlaps_point(x, y)
end
function ResultTabs:scrollbar_dragging() return self.shown ~= nil and self.shown:scrollbar_dragging() end
function ResultTabs:supports_text_input() return self.shown ~= nil and self.shown:supports_text_input() end
function ResultTabs:on_text_input(...) return self.shown and self.shown:on_text_input(...) end
function ResultTabs:on_key_pressed(...) return self.shown and self.shown:on_key_pressed(...) end

-- Copy View copies each Tab as a kept result.
function ResultTabs:duplicate()
  local copy = ResultTabs(self.connection_name)
  for _, view in ipairs(self.tabs) do
    local tab_copy = view.data and view:copy()
    if tab_copy then
      copy:add(tab_copy)
      if view == self.shown or not copy.shown then copy:select(tab_copy) end
    end
  end
  return copy
end

function ResultTabs:on_close()
  self.closed = true
  for _, view in ipairs(self.tabs) do view:on_close() end
end

-- Commands act on the focused Tab.
local function focused()
  local view = core.active_view
  return view and view:is(Results) and view.host ~= nil and view.host:has_focus(), view
end

local function step(view, delta)
  local host = view.host
  local index = index_of(host.tabs, view) + delta
  if not host.tabs[index] then return false end
  host:select(host.tabs[index], true)
  return true
end

command.add(focused, {
  ["sql_server:next_result"] = function(view) return step(view, 1) end,
  ["sql_server:previous_result"] = function(view) return step(view, -1) end,
  ["sql_server:close_result"] = function(view) return view.host:close_tab(view) end,
})
command.add(function()
  local ok, view = focused()
  return ok and #view.host.tabs > 1, view
end, {
  ["sql_server:close_other_results"] = function(view)
    local host, others = view.host, {}
    for _, other in ipairs(view.host.tabs) do
      if other ~= view then others[#others + 1] = other end
    end
    for _, other in ipairs(others) do host:close_tab(other) end
    return true
  end,
})
command.add(function()
  local ok, view = focused()
  return ok and #view.host.tabs > 1 and not view.cancel_query, view
end, {
  ["sql_server:move_result_to_split_right"] = function(view)
    return view.host:move(view, { kind = "split", pane = panes.pane_for_view(view.host), direction = "right" })
  end,
  ["sql_server:move_result_to_split_down"] = function(view)
    return view.host:move(view, { kind = "split", pane = panes.pane_for_view(view.host), direction = "down" })
  end,
})

return ResultTabs
