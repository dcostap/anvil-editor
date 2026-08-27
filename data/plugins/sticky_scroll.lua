-- mod-version:3
local core = require "core"
local TextView = require "core.textview"
local Editor = require "core.editor"
local style = require "core.style"
local common = require "core.common"
local command = require "core.command"
local linewrapping = require "core.linewrapping"

local SS = {}

local function perf_scope_begin(name)
  if not core.perf_draw_scope_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.scope_begin and perf.scope_begin(name) or nil
end

local function perf_scope_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.scope_end then perf.scope_end(token) end
end

local function get_buffer_line_text(buffer, line)
  if buffer.get_utf8_line then return buffer:get_utf8_line(line) end
  return buffer.lines[line] or ""
end

-- Ignore lines with only the opening bracket
function SS.get_level_ignore_open_bracket(buffer, line)
  if get_buffer_line_text(buffer, line):match("^%s*{%s*$") then
    return -1
  end
  return SS.get_level_default(buffer, line)
end

local filetype_overrides = {
  ["Markdown"] = function(buffer, line)
    -- Use the markdown heading level only
    local indent = string.match(get_buffer_line_text(buffer, line), "^#+() .+")
    return indent or math.huge
  end,
  ["C"] = SS.get_level_ignore_open_bracket,
  ["C++"] = SS.get_level_ignore_open_bracket,
}

local sticky_scroll = {
  enabled = true,
  max_sticky_lines = 5,
  min_scope_lines = 10,
  rebuild_debounce = 0.5,
  -- The key is the syntax name, the value is a function that receives the buffer
  -- and the line, and returns the level [-1; math.huge]. Use `false` to disable
  -- the plugin for that filetype.
  filetype_overrides = filetype_overrides,
}

local function markdown_live_mode(view)
  local live_render = package.loaded["core.markdown.live_render"]
  return live_render and live_render.is_live_mode
    and live_render.is_live_mode(view)
end

-- Automatically remove textview (keys) when not needed anymore
-- Automatically create a textview entry on access
SS.managed_textviews = setmetatable({}, {
  __mode = "k",
  __index = function(t, k)
      local v = {enabled = true, sticky_lines = {}, reference_line = 1, syntax = nil}
      rawset(t, k, v)
      return v
    end
})

local regex_pattern = regex.compile([[(\s*)\S]])
---Return the indent level of a string.
---The indent level is counted as the number of spaces and tabs in the string.
---A tab is counted as a space, so mixed tab types can cause issues.
---
---TODO: maybe only consider the indent type of the file,
---      or even only consider valid the type of the first character in the line.
---
---@param buffer core.buffer
---@param line integer
---@return integer #>0 for lines with indents and text, 0 for lines with no indent, -1 for lines without any non-whitespace characters
function SS.get_level_from_indent(buffer, line)
  local text = get_buffer_line_text(buffer, line)
  local s, e = regex.find_offsets(regex_pattern --[[@as regex]], text)
  return s and e - s or -1
end

---Same as SS.get_level_from_indent, but ignores lines with only comments.
---@param buffer core.buffer
---@param line integer
---@return integer #>0 for lines with indents and text, 0 for lines with no indent, -1 for lines without any non-whitespace characters
function SS.get_level_default(buffer, line)
  for _, type, text in buffer.highlighter:each_token(line) do
    if type ~= "comment" then
      return SS.get_level_from_indent(buffer, line)
    end
  end
  return -1
end

---Return the function to use to get the level.
---
---@param buffer core.buffer
---@param line integer
---@return function
function SS.get_level_getter(buffer)
  local get_level = SS.get_level_default
  if buffer.syntax.name
   and sticky_scroll.filetype_overrides[buffer.syntax.name] ~= nil then
    get_level = sticky_scroll.filetype_overrides[buffer.syntax.name]
    if get_level == false then
      get_level = nil
    end
  end
  return get_level
end

---Returns whether the plugin is enabled.
---If `dv` is provided, returns if the textview is enabled.
---The "global" check has priority over the textview check.
---
---@param dv core.textview?
---return boolean
function SS.should_run(dv)
  if dv and not (dv:is(TextView) or dv:is(Editor)) then return false end
  if dv and dv.buffer and dv.buffer.binary then return false end
  if dv and markdown_live_mode(dv) then return false end
  if dv and not SS.managed_textviews[dv].enabled then return false end
  if not sticky_scroll.enabled then return false end
  return true
end

local function get_visible_line_range(dv)
  return dv:get_visible_line_range()
end

local function sticky_line_height(textview, line)
  if textview.get_visual_row and textview.get_visual_row_height then
    local first_row = textview:get_visual_row(line, 1)
    local row_count = textview.get_visual_row_count_for_line
      and textview:get_visual_row_count_for_line(line) or 1
    local height = 0
    for row = first_row, first_row + math.max(1, row_count) - 1 do
      height = height + textview:get_visual_row_height(row)
    end
    return height
  elseif textview.get_position_visual_row_height then
    return textview:get_position_visual_row_height(line, 1)
  end
  return textview:get_line_height()
end

function SS.get_sticky_stack_height(textview, sticky_lines)
  local height = 0
  for _, line in ipairs(sticky_lines or {}) do
    height = height + sticky_line_height(textview, line)
  end
  return height
end

function SS.get_sticky_layout(textview, sticky_lines, reference_line)
  local layout = {}
  local y = textview.position.y
  local reference_y
  if reference_line then
    local _reference_x
    _reference_x, reference_y = textview:get_line_screen_position(reference_line)
  end
  for i = #(sticky_lines or {}), 1, -1 do
    local line = sticky_lines[i]
    local height = sticky_line_height(textview, line)
    layout[#layout + 1] = {
      line = line,
      y = reference_y and math.min(y, reference_y) or y,
      height = height,
    }
    y = y + height
  end
  return layout
end

local function sticky_entry_at_y(layout, y)
  for i = #layout, 1, -1 do
    local entry = layout[i]
    if y >= entry.y and y < entry.y + entry.height then return entry end
  end
end

local function sticky_horizontal_bounds(textview)
  local width = textview.get_presentation_viewport_width
    and textview:get_presentation_viewport_width() or textview.size.x
  local x = textview.position.x
  if width ~= textview.size.x and textview.get_content_offset then
    x = select(1, textview:get_content_offset()) + (textview.scroll.x or 0)
  end
  return x, width
end

local function intersect_rect(x1, y1, w1, h1, x2, y2, w2, h2)
  local x = math.max(x1, x2)
  local y = math.max(y1, y2)
  local right = math.min(x1 + w1, x2 + w2)
  local bottom = math.min(y1 + h1, y2 + h2)
  return x, y, math.max(0, right - x), math.max(0, bottom - y)
end

local function draw_sticky_shadow(x, y, width)
  local height = math.max(2, math.ceil(style.sticky_scroll_shadow_height))
  local source = style.sticky_scroll_shadow
  local color = { source[1], source[2], source[3], source[4] or 255 }
  core.push_clip_rect(x, y, width, height)
  for offset = 0, height - 1 do
    local fade = 1 - offset / (height - 1)
    color[4] = math.floor((source[4] or 255) * fade * fade + 0.5)
    renderer.draw_rect(x, y + offset, width, 1, color)
  end
  core.pop_clip_rect()
end

local function start_model_build(textview, buffer)
  textview.sticky_scroll_model_generation = (textview.sticky_scroll_model_generation or 0) + 1
  local generation = textview.sticky_scroll_model_generation
  textview.sticky_scroll_model_building = true
  textview.sticky_scroll_model_pending_time = nil
  local change_id = buffer:get_change_id()

  local get_level = SS.get_level_getter(buffer)
  if not get_level then
    textview.sticky_scroll_model_scopes = {}
    textview.sticky_scroll_model_line_scope = {}
    textview.sticky_scroll_cache = {}
    textview.sticky_scroll_model_change_id = change_id
    textview.sticky_scroll_model_building = false
    textview.sticky_scroll_model_ready = true
    core.log_quiet(
      "Sticky scroll model: published empty model for %s at change %s",
      buffer:get_name(), tostring(change_id)
    )
    return
  end

  core.add_thread(function()
    local scopes = {}
    local line_scope = {}
    local stack = {}
    local slice_start = system.get_time()
    local slice_lines = 0
    local slice_budget = 0.001

    for line = 1, #buffer.lines do
      if buffer:get_change_id() ~= change_id then break end
      local level = get_level(buffer, line)
      if level >= 0 then
        while #stack > 0 and scopes[stack[#stack]].level >= level do
          scopes[stack[#stack]].last_line = line - 1
          stack[#stack] = nil
        end
        local parent = stack[#stack]
        local idx = #scopes + 1
        scopes[idx] = { line = line, level = level, parent = parent, last_line = #buffer.lines, has_child = false }
        if parent then scopes[parent].has_child = true end
        stack[#stack + 1] = idx
      end
      line_scope[line] = stack[#stack]
      slice_lines = slice_lines + 1
      if slice_lines >= 50 or (slice_lines % 10 == 0 and system.get_time() - slice_start >= slice_budget) then
        coroutine.yield()
        slice_start = system.get_time()
        slice_lines = 0
      end
    end

    if textview.sticky_scroll_model_generation == generation then
      if buffer:get_change_id() == change_id then
        textview.sticky_scroll_model_scopes = scopes
        textview.sticky_scroll_model_line_scope = line_scope
        textview.sticky_scroll_cache = {}
        textview.sticky_scroll_model_change_id = change_id
        textview.sticky_scroll_model_ready = true
        core.log_quiet(
          "Sticky scroll model: published %d scopes for %s at change %s",
          #scopes, buffer:get_name(), tostring(change_id)
        )
      end
      textview.sticky_scroll_model_building = false
    end
    core.redraw = true
  end, buffer)
end

local function get_model_sticky_lines(textview, start_line, max_sticky_lines)
  if not textview.sticky_scroll_model_ready then return {} end
  local scopes = textview.sticky_scroll_model_scopes or {}
  local line_scope = textview.sticky_scroll_model_line_scope or {}
  local res = {}
  local idx = line_scope[common.clamp(start_line, 1, #line_scope)]
  while idx and #res < max_sticky_lines do
    local scope = scopes[idx]
    if not scope then break end
    if scope.line < start_line
    and start_line <= scope.last_line
    and scope.has_child
    and scope.last_line - scope.line + 1 >= (sticky_scroll.min_scope_lines or 1) then
      res[#res + 1] = scope.line
    end
    idx = scope.parent
  end
  return res
end

local function schedule_model_build(textview)
  textview.sticky_scroll_model_generation = (textview.sticky_scroll_model_generation or 0) + 1
  textview.sticky_scroll_model_pending_time = system.get_time() + (sticky_scroll.rebuild_debounce or 0)
  textview.sticky_scroll_model_building = false
end

local last_max_sticky_lines
local old_dv_update = TextView.update
function TextView:update(...)
  local res = old_dv_update(self, ...)
  if not SS.should_run(self) then return res end

  -- The cache belongs to the last atomically published scope model. Buffer
  -- changes schedule its replacement without exposing a half-built model.
  local textview = SS.managed_textviews[self]
  local current_change_id = self.buffer:get_change_id()
  local settings_changed = last_max_sticky_lines ~= sticky_scroll.max_sticky_lines
    or textview.syntax ~= self.buffer.syntax
  if settings_changed then
    textview.sticky_scroll_cache = {}
    textview.sticky_scroll_model_scopes = {}
    textview.sticky_scroll_model_line_scope = {}
    textview.sticky_scroll_model_ready = false
    textview.sticky_lines = {}
    textview.reference_line = 1
    textview.syntax = self.buffer.syntax
    textview.sticky_scroll_last_change_id = current_change_id
    last_max_sticky_lines = sticky_scroll.max_sticky_lines
    start_model_build(textview, self.buffer)
  elseif textview.sticky_scroll_last_change_id ~= current_change_id then
    textview.sticky_scroll_last_change_id = current_change_id
    schedule_model_build(textview)
  elseif textview.sticky_scroll_model_pending_time
     and system.get_time() >= textview.sticky_scroll_model_pending_time
     and not textview.sticky_scroll_model_building then
    start_model_build(textview, self.buffer)
  end

  -- Scope models are published atomically. While a replacement is pending or
  -- building, retain the last settled sticky stack instead of substituting a
  -- different hierarchy heuristic whose candidates can flicker during typing.
  if not textview.sticky_scroll_model_ready
  or textview.sticky_scroll_model_change_id ~= current_change_id then
    return res
  end

  local minline, _ = get_visible_line_range(self)

  -- We need to find the first line that'll be visible
  -- even after the sticky lines are drawn.
  local from = math.max(1, minline)
  local to = math.min(minline + sticky_scroll.max_sticky_lines, #self.buffer.lines)
  local new_sticky_lines = {}
  local new_reference_line = to
  for i = from, to do
    -- Simple cache
    if not textview.sticky_scroll_cache[i] then
      textview.sticky_scroll_cache[i] = get_model_sticky_lines(
        textview, i, sticky_scroll.max_sticky_lines
      )
    end
    local scroll_lines = textview.sticky_scroll_cache[i]
    local _, nl_y = self:get_line_screen_position(i)
    if nl_y >= self.position.y + SS.get_sticky_stack_height(self, scroll_lines) then
      break
    end
    new_sticky_lines = scroll_lines
    new_reference_line = i
  end

  textview.sticky_lines = new_sticky_lines
  textview.reference_line = new_reference_line
  return res
end

local old_dv_draw_overlay = TextView.draw_overlay
function TextView:draw_overlay(...)
  local scope = perf_scope_begin("sticky_scroll_overlay")
  local res = old_dv_draw_overlay(self, ...)
  if not SS.should_run(self) then
    perf_scope_end(scope)
    return res
  end

  local minline, _ = get_visible_line_range(self)

  -- Ignore the horizontal scroll position when drawing sticky lines
  local scroll_x = self.scroll.x
  self.scroll.x = 0
  local x = self:get_line_screen_position(minline)
  self.scroll.x = scroll_x

  local gw, gpad = self:get_gutter_width()
  local data = SS.managed_textviews[self]
  local layout = SS.get_sticky_layout(self, data.sticky_lines, data.reference_line)

  -- TextView narrows the active clip to exclude the gutter before drawing its
  -- overlay. Widen it to the whole view, but retain the enclosing clip because
  -- a sticky row being pushed out can temporarily have a y above the view.
  local clip_index = #core.clip_rect_stack
  local old_clip_rect = core.clip_rect_stack[clip_index]
  local enclosing_clip_rect = core.clip_rect_stack[clip_index - 1] or old_clip_rect
  local clip_x, clip_y, clip_w, clip_h = intersect_rect(
    self.position.x, self.position.y, self.size.x, self.size.y,
    table.unpack(enclosing_clip_rect)
  )
  core.clip_rect_stack[clip_index] = { clip_x, clip_y, clip_w, clip_h }
  renderer.set_clip_rect(clip_x, clip_y, clip_w, clip_h)

  local drawn = false
  local max_y = 0
  for _, entry in ipairs(layout) do
    local l, y, height = entry.line, entry.y, entry.height
    max_y = math.max(y + height, max_y)
    drawn = true
    core.push_clip_rect(self.position.x, y, self.size.x, height)
    renderer.draw_rect(self.position.x, y, self.size.x, height, style.background)
    self:draw_line_gutter(l, self.position.x, y, gpad and gw - gpad or gw)
    self:draw_line_text(l, x, y)
    if data.hovered_sticky_scroll_line == l then
      renderer.draw_rect(self.position.x, y, self.size.x, height, style.drag_overlay)
    end
    core.pop_clip_rect()
  end
  if drawn then
    renderer.draw_rect(self.position.x, max_y, self.size.x, style.divider_size, style.divider)
    draw_sticky_shadow(
      self.position.x, max_y + style.divider_size, self.size.x
    )
  end

  -- Restore clip rect
  core.clip_rect_stack[clip_index] = old_clip_rect
  renderer.set_clip_rect(table.unpack(old_clip_rect))
  perf_scope_end(scope)
  return res
end

local old_mouse_pressed = TextView.on_mouse_pressed
function TextView:on_mouse_pressed(button, x, y, clicks, ...)
  if not SS.should_run(self) then return old_mouse_pressed(self, button, x, y, clicks, ...) end

  local data = SS.managed_textviews[self]
  data.sticky_lines_mouse_pressed = false
  if #data.sticky_lines == 0 then
    return old_mouse_pressed(self, button, x, y, clicks, ...)
  end

  local layout = SS.get_sticky_layout(self, data.sticky_lines, data.reference_line)
  local entry = sticky_entry_at_y(layout, y)
  local bounds_x, bounds_width = sticky_horizontal_bounds(self)
  if not entry
   or y < self.position.y
   or x < bounds_x
   or x >= bounds_x + bounds_width then
    data.sticky_lines_mouse_pressed = true
    return old_mouse_pressed(self, button, x, y, clicks, ...)
  end

  local scroll_x = self.scroll.x
  self.scroll.x = 0
  local sticky_x = self:get_line_screen_position(entry.line)
  self.scroll.x = scroll_x
  local col
  local row_count = self.get_visual_row_count_for_line
    and self:get_visual_row_count_for_line(entry.line) or 1
  if self.wrapped_settings and row_count > 1 then
    local first_row = self:get_visual_row(entry.line, 1)
    local relative_y = math.max(0, y - entry.y)
    local row_in_line, consumed = 1, 0
    for index = 1, row_count do
      local height = self:get_visual_row_height(first_row + index - 1)
      row_in_line = index
      if relative_y < consumed + height then break end
      consumed = consumed + height
    end
    local first_idx = self.wrapped_line_to_idx and self.wrapped_line_to_idx[entry.line]
    if not first_idx then
      first_idx = linewrapping.get_line_idx_col_count(self, entry.line)
    end
    local _, resolved_col = linewrapping.get_line_col_from_index_and_x(
      self, first_idx + row_in_line - 1, x - sticky_x
    )
    col = resolved_col
  else
    col = self:get_x_offset_col(entry.line, x - sticky_x)
  end
  self:scroll_to_make_visible(entry.line, col)
  self.buffer:set_selection(entry.line, col)
  return true
end

local old_mouse_moved = TextView.on_mouse_moved
function TextView:on_mouse_moved(x, y, ...)
  if not SS.should_run(self) then return old_mouse_moved(self, x, y, ...) end

  local data = SS.managed_textviews[self]
  data.hovered_sticky_scroll_line = nil
  if #data.sticky_lines == 0 then
    return old_mouse_moved(self, x, y, ...)
  end

  local layout = SS.get_sticky_layout(self, data.sticky_lines, data.reference_line)
  local entry = sticky_entry_at_y(layout, y)
  local bounds_x, bounds_width = sticky_horizontal_bounds(self)
  if self.mouse_selecting
   or not entry
   or y < self.position.y
   or x < bounds_x
   or x >= bounds_x + bounds_width
   or self.v_scrollbar:overlaps(x, y)
   then
    return old_mouse_moved(self, x, y, ...)
  end

  self.cursor = "hand"
  data.hovered_sticky_scroll_line = entry.line
  return true
end

local old_scroll_to_make_visible = TextView.scroll_to_make_visible
function TextView:scroll_to_make_visible(line, col, ...)
  old_scroll_to_make_visible(self, line, col, ...)
  if not SS.should_run(self) then return end

  -- We need to scroll the view to account for the sticky lines.

  local before_scroll = self.scroll.y
  local _, ly = self:get_line_screen_position(line, col)
  ly = ly - self.position.y + (before_scroll - self.scroll.to.y)
  local data = SS.managed_textviews[self]
  -- Avoid moving the caret under the sticky lines.
  local sticky_height
  if data.sticky_lines_mouse_pressed or self.mouse_selecting then
    data.sticky_lines_mouse_pressed = false
    sticky_height = SS.get_sticky_stack_height(self, data.sticky_lines)
  else
    sticky_height = SS.get_sticky_stack_height(self, data.sticky_lines)
    if sticky_height == 0 then
      sticky_height = sticky_scroll.max_sticky_lines * self:get_line_height()
    end
  end
  if ly < sticky_height then
    self.scroll.to.y = self.scroll.to.y - (sticky_height - ly)
    if self.notify_scroll_listeners then self:notify_scroll_listeners("sticky_scroll_adjust") end
  end
end

-- Generic commands
command.add_toggle("editor:toggle_sticky_lines", {
  palette = true,
  get = function()
    return sticky_scroll.enabled
  end,
  set = function(enabled)
    sticky_scroll.enabled = enabled
  end,
})

-- Per-textview commands
command.add_toggle("editor:toggle_buffer_sticky_lines", {
  palette = true,
  predicate = SS.should_run,
  get = function(dv)
    dv = dv or core.active_view
    return dv and SS.managed_textviews[dv].enabled
  end,
  set = function(enabled, dv)
    dv = dv or core.active_view
    if dv then SS.managed_textviews[dv].enabled = enabled end
  end,
})

return SS
