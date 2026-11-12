-- A Code Tour presents selected ranges of real Buffers. Folds and notes belong
-- to its Editors, not to other Views of those Buffers.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local config = require "core.config"
local command = require "core.command"
local file_context = require "core.file_context"
local View = require "core.view"
local Editor = require "core.editor"
local Buffer = require "core.buffer"
local panes = require "core.panes"
local MouseRouter = require "core.mouse_router"
local notes = require "plugins.diff.notes"

local CodeTour = View:extend()
CodeTour.context = "workspace"
local EntryList = View:extend()

function EntryList:new(tour)
  EntryList.super.new(self)
  self.tour, self.scrollable = tour, true
end

function EntryList:row_height() return style.font:get_height() + style.padding.y * 2 end
function EntryList:get_focus_view() return self.tour:get_focus_view() end
function EntryList:get_scrollable_size() return #self.tour.entries * self:row_height() end
function EntryList:on_mouse_wheel(y)
  self.scroll.to.y = self.scroll.to.y - y * config.mouse_wheel_scroll
  self:clamp_scroll_position()
  return true
end
function EntryList:entry_at(x, y)
  if x < self.position.x or x >= self.position.x + self.size.x
    or y < self.position.y or y >= self.position.y + self.size.y then return end
  local index = math.floor((y - self.position.y + self.scroll.y) / self:row_height()) + 1
  if self.tour.entries[index] then return index end
end

function EntryList:on_mouse_pressed(button, x, y, clicks)
  if EntryList.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button == "left" then self.pressed = self:entry_at(x, y); return true end
end

function EntryList:on_mouse_released(button, x, y)
  EntryList.super.on_mouse_released(self, button, x, y)
  local index = self.pressed
  self.pressed = nil
  if button == "left" and index and index == self:entry_at(x, y) then
    self.tour:select_entry(index, true)
    return true
  end
end

function EntryList:draw()
  self:draw_background(style.background2)
  local height = self:row_height()
  local first = math.max(1, math.floor(self.scroll.y / height) + 1)
  local last = math.min(#self.tour.entries, math.ceil((self.scroll.y + self.size.y) / height))
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  for i = first, last do
    local y = self.position.y + (i - 1) * height - self.scroll.y
    if i == self.tour.selected then
      renderer.draw_rect(self.position.x, y, self.size.x, height, style.line_highlight)
    end
    common.draw_text(style.font, i == self.tour.selected and style.text or style.dim,
      self.tour.entries[i].label, "left", self.position.x + style.padding.x, y,
      self.size.x - style.padding.x * 2, height)
  end
  self:draw_scrollbar()
  core.pop_clip_rect()
end

local function target_at(self, x, y)
  if x < self.position.x or x >= self.position.x + self.size.x
    or y < self.position.y or y >= self.position.y + self.size.y then return end
  local editor = self:get_focus_view()
  if not editor then return self.list end
  if x < editor.position.x then return self.list end
  if y >= editor.position.y then return editor end
end

function CodeTour:new(state, done)
  CodeTour.super.new(self)
  self.title, self.entries, self.files = state.title or "Code Tour", {}, {}
  self.selected, self.loading = state.selected or 1, true
  self.list = EntryList(self)
  self.mouse = MouseRouter(self, target_at)
  self.targets = {self.list}
  local by_path = {}
  for _, spec in ipairs(state.entries) do
    local path = common.normalize_path(spec.path)
    local key = PLATFORM == "Windows" and path:lower() or path
    local file = by_path[key]
    if not file then
      file = {path = path, label = common.relative_path(core.root_project().path, path), specs = {}, entries = {}}
      by_path[key], self.files[#self.files + 1] = file, file
    end
    local entry = {path = path, line = spec.line, end_line = spec.end_line or spec.line,
      text = spec.text, side = 1, removed = spec.removed, file = file}
    self.entries[#self.entries + 1], file.entries[#file.entries + 1] = entry, entry
    file.specs[#file.specs + 1] = entry
    entry.label = file.label .. ":" .. entry.line .. "–" .. entry.end_line
  end
  core.add_thread(function()
    if self.closed then return end
    local ok, err = pcall(function() self:load() end)
    if self.closed then return end
    self.loading, self.error = nil, not ok and tostring(err) or nil
    if ok then self:select_entry(self.selected, core.active_view == self) end
    core.log_quiet("Code Tour: %s, %d entries, %s", self.title, #self.entries, self.error or "ready")
    if done then done(ok and self or nil, self.error) end
    core.redraw = true
  end)
end

-- Retain pending Buffers so registry collection cannot cancel their loads.
-- Reuse open Buffers, including unsaved edits. New loads run in the file worker.
function CodeTour:load()
  for _, file in ipairs(self.files) do
    local buffer = core.buffer_registry:find(file.path)
    if not buffer then
      buffer = Buffer(file.path, file.path, true)
      assert(core.buffer_registry:register(buffer, file.path))
      buffer:load_async(file.path, nil, {backup_prompt = false, recheck = false})
    end
    file.buffer = buffer
    core.buffer_registry:retain(buffer, self)
  end
  for _, file in ipairs(self.files) do
    local buffer = file.buffer
    while buffer:is_loading() and not self.closed do coroutine.yield(0.01) end
    if self.closed then return end
    assert(not buffer.load_error, file.path .. ": " .. tostring(buffer.load_error))
    assert(not buffer.new_file, "File does not exist: " .. file.path)
    local binary, remaining = buffer.binary, 8000
    for _, line in ipairs(buffer.lines) do
      if remaining <= 0 then break end
      if line:sub(1, remaining):find("%z") then binary = true; break end
      remaining = remaining - #line
    end
    assert(not binary, "Code Tours need text files: " .. file.path)
    for _, entry in ipairs(file.entries) do
      assert(entry.removed or entry.line >= 1 and entry.end_line >= entry.line and entry.end_line <= #buffer.lines,
        "Code Tour range is outside " .. file.path)
    end
    local editor = Editor(buffer)
    file.editor = editor
    editor.code_tour = self
    editor.next_point_of_interest = function() return nil, "boundary" end
    editor.continue_point_of_interest = function(_, direction) return self:move_entry(direction) end
    file.notes = notes.create({buffer}, file.specs)
    for i, note in ipairs(file.notes) do file.entries[i].note = note end
    self:refresh_file(file)
    notes.install(editor, function(placement, line)
      if placement == "after" then return file.rows[line] end
    end, function() return file.revision end)
    -- The existing fold markers follow edits. Do not replace folds on each edit:
    -- a range that the user expanded must stay expanded.
    local sorted = {}
    for _, entry in ipairs(file.entries) do
      if not entry.removed then sorted[#sorted + 1] = entry end
    end
    table.sort(sorted, function(a, b) return a.line < b.line end)
    local start = 1
    local function fold(stop)
      if stop > start then
        editor:add_fold_region {line1 = start, line2 = stop, col1 = 1,
          col2 = #buffer.lines[stop], kind = "code-tour", collapsed = true,
          placeholder = string.format("⋯ %d lines folded ⋯", stop - start + 1)}
      end
    end
    for _, entry in ipairs(sorted) do
      fold(entry.line - 1)
      start = math.max(start, entry.end_line + 1)
    end
    fold(#buffer.lines)
    core.buffer_registry:release(buffer, self)
  end
end

function CodeTour:refresh_file(file)
  if not file.notes or file.revision == file.buffer.text_revision then return end
  notes.refresh_lines(file.notes)
  file.rows = {}
  for _, entry in ipairs(file.entries) do
    local note = entry.note
    if not note.marker:is_valid() then entry.removed = true end
    entry.label = file.label .. ":" .. entry.line .. "–" .. entry.end_line
      .. (entry.removed and " (range removed)" or "")
    if entry.text and not entry.removed then
      local rows = file.rows[note.line2] or {}
      file.rows[note.line2] = rows
      rows[#rows + 1] = notes.row(note, file.editor)
    end
  end
  file.revision = file.buffer.text_revision
  file.editor:invalidate_visual_metrics("code-tour-notes")
end

function CodeTour:get_name() return self.title end
function CodeTour:get_focus_view()
  local entry = self.entries[self.selected]
  return not self.loading and not self.error and entry and entry.file.editor or nil
end
function CodeTour:get_surface_focus_targets() return self.targets end
function CodeTour:get_path_target()
  local editor = self:get_focus_view()
  return editor and file_context.view_path_target(editor)
end

function CodeTour:select_entry(index, focus)
  local entry = self.entries[index]
  if not entry or self.loading or self.error then return false end
  self:refresh_file(entry.file)
  if entry.removed then return false end
  self.selected = index
  local editor = entry.file.editor
  if panes.pane_for_view(self) then panes.register_focus_target(self, editor) end
  self.targets[2] = editor
  editor:expand_folds_covering_range(entry.line, 1, entry.end_line, #editor.buffer.lines[entry.end_line], "code-tour")
  editor:with_selection_state(function() editor.buffer:set_selection(entry.line, 1) end)
  self.reveal = entry.line
  local top, height = (index - 1) * self.list:row_height(), self.list.size.y
  if top < self.list.scroll.to.y then self.list.scroll.to.y = top
  elseif top + self.list:row_height() > self.list.scroll.to.y + height then
    self.list.scroll.to.y = math.max(0, top + self.list:row_height() - height)
  end
  if focus then core.set_active_view(editor) end
  core.redraw = true
  return true
end

function CodeTour:move_entry(direction)
  local index = self.selected + direction
  while self.entries[index] do
    if self:select_entry(index, true) then return true end
    index = index + direction
  end
  return false
end

function CodeTour:update()
  CodeTour.super.update(self)
  local width = math.min(320 * SCALE, self.size.x * 0.30)
  self.list.position.x, self.list.position.y = self.position.x, self.position.y
  self.list.size.x, self.list.size.y = width, self.size.y
  self.list:update()
  local editor = self:get_focus_view()
  if not editor then return end
  self:refresh_file(self.entries[self.selected].file)
  local header = style.font:get_height() + style.padding.y * 2
  editor.position.x, editor.position.y = self.position.x + width, self.position.y + header
  editor.size.x, editor.size.y = self.size.x - width, math.max(0, self.size.y - header)
  editor:update()
  if self.reveal and editor.size.y > 0 then
    editor:scroll_to_line(self.reveal, true, false)
    self.reveal = nil
  end
end

function CodeTour:draw()
  self:draw_background(style.background)
  self.list:draw()
  local x = self.position.x + self.list.size.x
  core.push_clip_rect(x, self.position.y, self.size.x - self.list.size.x, self.size.y)
  local editor = self:get_focus_view()
  common.draw_text(style.font, style.dim, self.error or (editor and self.entries[self.selected].file.label or "Loading code…"),
    "left", x + style.padding.x, self.position.y, self.size.x - self.list.size.x - style.padding.x * 2,
    style.font:get_height() + style.padding.y * 2)
  if editor then
    core.push_clip_rect(editor.position.x, editor.position.y, editor.size.x, editor.size.y)
    editor:draw()
    core.pop_clip_rect()
  end
  core.pop_clip_rect()
end

function CodeTour:on_mouse_pressed(button, x, y, clicks)
  local target = self.mouse:press_target(x, y)
  if not target then return end
  if panes.pane_for_view(self) then panes.register_focus_target(self, target) end
  core.set_active_view(target)
  self.mouse:capture(target)
  return self.mouse:call(target, "on_mouse_pressed", button, x, y, clicks)
end
function CodeTour:on_mouse_moved(...) return self.mouse:move(...) end
function CodeTour:on_mouse_released(...) return self.mouse:release(...) end
function CodeTour:on_mouse_left() return self.mouse:leave() end
function CodeTour:on_mouse_wheel(y, x)
  return self.mouse:call(self.mouse:wheel_target() or self:get_focus_view() or self.list, "on_mouse_wheel", y, x)
end

function CodeTour:can_close(approve)
  local index = 0
  local function next_file()
    index = index + 1
    local file = self.files[index]
    if not file then return approve() end
    if file.editor then file.editor:can_close(next_file) else next_file() end
  end
  next_file()
end

function CodeTour:on_close()
  if self.closed then return end
  self.closed = true
  for _, file in ipairs(self.files) do
    notes.dispose(file.notes)
    if file.editor then
      panes.unregister_focus_target(file.editor)
      file.editor:on_close()
    end
    if file.buffer then core.buffer_registry:release(file.buffer, self) end
  end
  panes.unregister_focus_target(self.list)
end
CodeTour.on_history_discarded = CodeTour.on_close

function CodeTour:get_state()
  local entries = {}
  for _, file in ipairs(self.files) do self:refresh_file(file) end
  for i, entry in ipairs(self.entries) do
    entries[i] = {path = entry.file.buffer and entry.file.buffer.abs_filename or entry.path,
      line = entry.line, end_line = entry.end_line, text = entry.text, removed = entry.removed}
  end
  return {title = self.title, entries = entries, selected = self.selected}
end
function CodeTour.from_state(state, opts)
  -- Pane transfer saves and verifies top-level Buffers only. Refuse the move
  -- until it can carry this View's child Buffers without losing their edits.
  if opts and opts.transfer then return nil end
  return CodeTour(state)
end
function CodeTour:duplicate() return CodeTour.from_state(self:get_state()) end

function CodeTour.open(state, place, done)
  local tour
  tour = CodeTour(state, function(view, err)
    if view then
      view, err = panes.place(function() return view end, place)
      if view then err = nil end
    end
    if not view then tour:on_close() end
    done(view, err)
  end)
  return tour
end

command.add(function()
  local view = core.active_view
  local tour = view and (view.code_tour or view.tour or view:is(CodeTour) and view)
  return tour ~= nil, tour
end, {
  ["code_tour:next_section"] = command.palette(function(tour) return tour:move_entry(1) end),
  ["code_tour:previous_section"] = command.palette(function(tour) return tour:move_entry(-1) end),
})
return CodeTour
