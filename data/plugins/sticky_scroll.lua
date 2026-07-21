-- mod-version:3
local core = require "core"
local DocView = require "core.docview"
local style = require "core.style"
local common = require "core.common"
local command = require "core.command"

local SS = {}

local function get_doc_line_text(doc, line)
  if doc.get_utf8_line then return doc:get_utf8_line(line) end
  return doc.lines[line] or ""
end

-- Ignore lines with only the opening bracket
function SS.get_level_ignore_open_bracket(doc, line)
  if get_doc_line_text(doc, line):match("^%s*{%s*$") then
    return -1
  end
  return SS.get_level_default(doc, line)
end

local filetype_overrides = {
  ["Markdown"] = function(doc, line)
    -- Use the markdown heading level only
    local indent = string.match(get_doc_line_text(doc, line), "^#+() .+")
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
  -- The key is the syntax name, the value is a function that receives the doc
  -- and the line, and returns the level [-1; math.huge]. Use `false` to disable
  -- the plugin for that filetype.
  filetype_overrides = filetype_overrides,
}


-- Automatically remove docview (keys) when not needed anymore
-- Automatically create a docview entry on access
SS.managed_docviews = setmetatable({}, {
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
---@param doc core.doc
---@param line integer
---@return integer #>0 for lines with indents and text, 0 for lines with no indent, -1 for lines without any non-whitespace characters
function SS.get_level_from_indent(doc, line)
  local text = get_doc_line_text(doc, line)
  local s, e = regex.find_offsets(regex_pattern --[[@as regex]], text)
  return s and e - s or -1
end

---Same as SS.get_level_from_indent, but ignores lines with only comments.
---@param doc core.doc
---@param line integer
---@return integer #>0 for lines with indents and text, 0 for lines with no indent, -1 for lines without any non-whitespace characters
function SS.get_level_default(doc, line)
  for _, type, text in doc.highlighter:each_token(line) do
    if type ~= "comment" then
      return SS.get_level_from_indent(doc, line)
    end
  end
  return -1
end

---Return the function to use to get the level.
---
---@param doc core.doc
---@param line integer
---@return function
function SS.get_level_getter(doc)
  local get_level = SS.get_level_default
  if doc.syntax.name
   and sticky_scroll.filetype_overrides[doc.syntax.name] ~= nil then
    get_level = sticky_scroll.filetype_overrides[doc.syntax.name]
    if get_level == false then
      get_level = nil
    end
  end
  return get_level
end

---Returns whether the plugin is enabled.
---If `dv` is provided, returns if the docview is enabled.
---The "global" check has priority over the docview check.
---
---@param dv core.docview?
---return boolean
function SS.should_run(dv)
  if dv and not dv:is(DocView) then return false end
  if dv and not SS.managed_docviews[dv].enabled then return false end
  if not sticky_scroll.enabled then return false end
  return true
end

---Return an array of the sticly lines that should be shown.
---
---@param doc core.doc
---@param start_line integer #the reference line
---@param max_sticky_lines integer #the maximum allowed sticky lines
---@return table #an ordered list of lines that should be shown as sticky
function SS.get_sticky_lines(doc, start_line, max_sticky_lines, level_cache)
  local res = {}
  local last_level
  local original_start_line = start_line
  start_line = common.clamp(start_line, 1, #doc.lines)

  local raw_get_level = SS.get_level_getter(doc)
  if not raw_get_level then return res end
  local function get_level(doc, line)
    if not level_cache then return raw_get_level(doc, line) end
    local level = level_cache[line]
    if level == nil then
      level = raw_get_level(doc, line)
      level_cache[line] = level
    end
    return level
  end

  -- Find the first usable line
  repeat
    if start_line <= 0 then return res end
    last_level = get_level(doc, start_line)
    start_line = start_line - 1
  until last_level >= 0

  -- If we had to skip some lines, check if we need to stick the usable one
  if original_start_line ~= start_line + 1 then
    local found = false
    -- Check if there are valid lines after the original start line
    for i = original_start_line, #doc.lines do
      local next_indent_level = get_level(doc, i)
      if next_indent_level >= 0 then
        if next_indent_level == 0 and next_indent_level < last_level then
          -- We are at the end of the block,
          -- so there aren't any sticky lines to be shown
          return res
        end
        -- If there is an indent level higher than original start line,
        -- stick the usable line that was found
        if next_indent_level > last_level then
          table.insert(res, start_line + 1)
        end
        found = true
        break
      end
    end
    -- If there are no valid lines, we don't need to show sticky lines.
    if not found then return res end
  end

  -- Find sticky lines to show, starting from the current line,
  -- until we get to one that has level 0.
  for i = start_line, 1, -1 do
    local level = get_level(doc, i)
    if level >= 0 and level < last_level then
      table.insert(res, i)
      last_level = level
    end
    if level == 0 then break end
  end

  -- Only keep the lines we're allowed to show
  common.splice(res, 1, math.max(0, #res - max_sticky_lines))
  return res
end

local function get_visible_line_range(dv)
  return dv:get_visible_line_range()
end

local function sticky_line_height(docview, line)
  if docview.get_position_visual_row_height then
    return docview:get_position_visual_row_height(line, 1)
  end
  return docview:get_line_height()
end

function SS.get_sticky_stack_height(docview, sticky_lines)
  local height = 0
  for _, line in ipairs(sticky_lines or {}) do
    height = height + sticky_line_height(docview, line)
  end
  return height
end

function SS.get_sticky_layout(docview, sticky_lines, reference_line)
  local layout = {}
  local y = docview.position.y
  local reference_y
  if reference_line then
    local _reference_x
    _reference_x, reference_y = docview:get_line_screen_position(reference_line)
  end
  for i = #(sticky_lines or {}), 1, -1 do
    local line = sticky_lines[i]
    local height = sticky_line_height(docview, line)
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

local function start_model_build(docview, doc, max_sticky_lines)
  docview.sticky_scroll_model_generation = (docview.sticky_scroll_model_generation or 0) + 1
  local generation = docview.sticky_scroll_model_generation
  docview.sticky_scroll_model_ready = false
  docview.sticky_scroll_model_building = true
  docview.sticky_scroll_model_pending_time = nil
  docview.sticky_scroll_model_change_id = doc:get_change_id()
  docview.sticky_scroll_model_syntax = doc.syntax
  docview.sticky_scroll_model_max_sticky_lines = max_sticky_lines
  docview.sticky_scroll_model_line_scope = {}
  docview.sticky_scroll_model_scopes = {}

  local get_level = SS.get_level_getter(doc)
  if not get_level then
    docview.sticky_scroll_model_building = false
    docview.sticky_scroll_model_ready = true
    return
  end

  core.add_thread(function()
    local scopes = {}
    local line_scope = {}
    local stack = {}
    local change_id = doc:get_change_id()
    local slice_start = system.get_time()
    local slice_lines = 0
    local slice_budget = 0.001

    for line = 1, #doc.lines do
      if doc:get_change_id() ~= change_id then break end
      local level = get_level(doc, line)
      if level >= 0 then
        while #stack > 0 and scopes[stack[#stack]].level >= level do
          scopes[stack[#stack]].last_line = line - 1
          stack[#stack] = nil
        end
        local parent = stack[#stack]
        local idx = #scopes + 1
        scopes[idx] = { line = line, level = level, parent = parent, last_line = #doc.lines, has_child = false }
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

    if docview.sticky_scroll_model_generation == generation then
      if doc:get_change_id() == change_id then
        docview.sticky_scroll_model_scopes = scopes
        docview.sticky_scroll_model_line_scope = line_scope
        docview.sticky_scroll_cache = {}
        docview.sticky_scroll_model_ready = true
      end
      docview.sticky_scroll_model_building = false
    end
    core.redraw = true
  end, doc)
end

local function get_model_sticky_lines(docview, start_line, max_sticky_lines)
  if not docview.sticky_scroll_model_ready then return {} end
  local scopes = docview.sticky_scroll_model_scopes or {}
  local line_scope = docview.sticky_scroll_model_line_scope or {}
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

local function schedule_model_build(docview, doc)
  docview.sticky_scroll_model_generation = (docview.sticky_scroll_model_generation or 0) + 1
  docview.sticky_scroll_model_pending_time = system.get_time() + (sticky_scroll.rebuild_debounce or 0)
  docview.sticky_scroll_model_pending_change_id = doc:get_change_id()
  docview.sticky_scroll_model_ready = false
  docview.sticky_scroll_model_building = false
  docview.sticky_scroll_cache = {}
  docview.sticky_scroll_level_cache = {}
end

local last_max_sticky_lines
local old_dv_update = DocView.update
function DocView:update(...)
  local res = old_dv_update(self, ...)
  if not SS.should_run(self) then return res end

  -- Simple cache. Gets reset on every doc change.
  -- Could be made smarter, but this will do for now™.
  local docview = SS.managed_docviews[self]
  local current_change_id = self.doc:get_change_id()
  local settings_changed = last_max_sticky_lines ~= sticky_scroll.max_sticky_lines
    or docview.syntax ~= self.doc.syntax
  if settings_changed then
    docview.sticky_scroll_cache = {}
    docview.sticky_scroll_level_cache = {}
    docview.reference_line = 1
    docview.syntax = self.doc.syntax
    docview.sticky_scroll_last_change_id = current_change_id
    last_max_sticky_lines = sticky_scroll.max_sticky_lines
    start_model_build(docview, self.doc, sticky_scroll.max_sticky_lines)
  elseif docview.sticky_scroll_last_change_id ~= current_change_id then
    docview.reference_line = 1
    docview.sticky_scroll_last_change_id = current_change_id
    schedule_model_build(docview, self.doc)
  elseif docview.sticky_scroll_model_pending_time
     and system.get_time() >= docview.sticky_scroll_model_pending_time
     and not docview.sticky_scroll_model_building then
    start_model_build(docview, self.doc, sticky_scroll.max_sticky_lines)
  end

  local minline, _ = get_visible_line_range(self)

  -- We need to find the first line that'll be visible
  -- even after the sticky lines are drawn.
  local from = math.max(1, minline)
  local to = math.min(minline + sticky_scroll.max_sticky_lines, #self.doc.lines)
  local new_sticky_lines = {}
  local new_reference_line = to
  for i = from, to do
    -- Simple cache
    local scroll_lines
    if docview.sticky_scroll_model_ready then
      if not docview.sticky_scroll_cache[i] then
        docview.sticky_scroll_cache[i] = get_model_sticky_lines(docview, i, sticky_scroll.max_sticky_lines)
      end
      scroll_lines = docview.sticky_scroll_cache[i]
    else
      if not docview.sticky_scroll_cache[i] then
        docview.sticky_scroll_cache[i] = SS.get_sticky_lines(
          self.doc, i, sticky_scroll.max_sticky_lines, docview.sticky_scroll_level_cache
        )
      end
      scroll_lines = docview.sticky_scroll_cache[i]
    end
    local _, nl_y = self:get_line_screen_position(i)
    if nl_y >= self.position.y + SS.get_sticky_stack_height(self, scroll_lines) then
      break
    end
    new_sticky_lines = scroll_lines
    new_reference_line = i
  end

  docview.sticky_lines = new_sticky_lines
  docview.reference_line = new_reference_line
  return res
end

local old_dv_draw_overlay = DocView.draw_overlay
function DocView:draw_overlay(...)
  local res = old_dv_draw_overlay(self, ...)
  if not SS.should_run(self) then return res end

  local minline, _ = get_visible_line_range(self)

  -- Ignore the horizontal scroll position when drawing sticky lines
  local scroll_x = self.scroll.x
  self.scroll.x = 0
  local x = self:get_line_screen_position(minline)
  self.scroll.x = scroll_x

  local gw, gpad = self:get_gutter_width()
  local data = SS.managed_docviews[self]
  local layout = SS.get_sticky_layout(self, data.sticky_lines, data.reference_line)

  -- We need to reset the clip, because when DocView:draw_overlay is called
  -- it's too small for us.
  local old_clip_rect = core.clip_rect_stack[#core.clip_rect_stack]
  renderer.set_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  local drawn = false
  local max_y = 0
  for _, entry in ipairs(layout) do
    local l, y, height = entry.line, entry.y, entry.height
    max_y = math.max(y + height, max_y)
    drawn = true
    renderer.draw_rect(self.position.x, y, self.size.x, height, style.background)
    self:draw_line_gutter(l, self.position.x, y, gpad and gw - gpad or gw)
    self:draw_line_text(l, x, y)
    if data.hovered_sticky_scroll_line == l then
      renderer.draw_rect(self.position.x, y, self.size.x, height, style.drag_overlay)
    end
  end
  if drawn then
    renderer.draw_rect(self.position.x, max_y, self.size.x, style.divider_size, style.divider)
  end

  -- Restore clip rect
  renderer.set_clip_rect(table.unpack(old_clip_rect))
  return res
end

local old_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks, ...)
  if not SS.should_run(self) then return old_mouse_pressed(self, button, x, y, clicks, ...) end

  local data = SS.managed_docviews[self]
  data.sticky_lines_mouse_pressed = false
  if #data.sticky_lines == 0 then
    return old_mouse_pressed(self, button, x, y, clicks, ...)
  end

  local layout = SS.get_sticky_layout(self, data.sticky_lines, data.reference_line)
  local entry = sticky_entry_at_y(layout, y)
  if not entry or y < self.position.y then
    data.sticky_lines_mouse_pressed = true
    return old_mouse_pressed(self, button, x, y, clicks, ...)
  end

  local scroll_x = self.scroll.x
  self.scroll.x = 0
  local sticky_x = self:get_line_screen_position(entry.line)
  self.scroll.x = scroll_x
  local col = self:get_x_offset_col(entry.line, x - sticky_x)
  self:scroll_to_make_visible(entry.line, col)
  self.doc:set_selection(entry.line, col)
  return true
end

local old_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  if not SS.should_run(self) then return old_mouse_moved(self, x, y, ...) end

  local data = SS.managed_docviews[self]
  data.hovered_sticky_scroll_line = nil
  if #data.sticky_lines == 0 then
    return old_mouse_moved(self, x, y, ...)
  end

  local layout = SS.get_sticky_layout(self, data.sticky_lines, data.reference_line)
  local entry = sticky_entry_at_y(layout, y)
  if self.mouse_selecting
   or not entry
   or y < self.position.y
   or x < self.position.x
   or x >= self.position.x + self.size.x
   or self.v_scrollbar:overlaps(x, y)
   then
    return old_mouse_moved(self, x, y, ...)
  end

  self.cursor = "hand"
  data.hovered_sticky_scroll_line = entry.line
  return true
end

local old_scroll_to_make_visible = DocView.scroll_to_make_visible
function DocView:scroll_to_make_visible(line, col, ...)
  old_scroll_to_make_visible(self, line, col, ...)
  if not SS.should_run(self) then return end

  -- We need to scroll the view to account for the sticky lines.

  local before_scroll = self.scroll.y
  local _, ly = self:get_line_screen_position(line, col)
  ly = ly - self.position.y + (before_scroll - self.scroll.to.y)
  local data = SS.managed_docviews[self]
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
command.add_toggle("sticky-lines:toggle", {
  get = function()
    return sticky_scroll.enabled
  end,
  set = function(enabled)
    sticky_scroll.enabled = enabled
  end,
})

-- Per-docview commands
command.add_toggle("sticky-lines:toggle-doc", {
  predicate = SS.should_run,
  get = function(dv)
    dv = dv or core.active_view
    return dv and SS.managed_docviews[dv].enabled
  end,
  set = function(enabled, dv)
    dv = dv or core.active_view
    if dv then SS.managed_docviews[dv].enabled = enabled end
  end,
})

return SS
