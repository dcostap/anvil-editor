local core = require "core"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local TextView = require "core.textview"

-- The Unified Diff edits one Diff Side's own Buffer. Changed lines of the
-- other side appear as rows between its lines; they are not Buffer text.
local UnifiedView = TextView:extend()

local OTHER_ROWS = "diff-other-side"

local function side_tag(index)
  return index == 1 and "delete" or "insert"
end

local function side_key(index)
  return index == 1 and "a" or "b"
end

local function side_changes(parent, index)
  return index == 1 and parent.a_changes or parent.b_changes
end

local function change_decorations(parent, index)
  local tag = side_tag(index)
  local function change_at(line)
    local change = side_changes(parent, index)[line]
    if change and change.tag ~= "equal" then return change end
  end
  return {
    line_background = function(_, _, line)
      if change_at(line) then return style["diff_" .. tag .. "_background"] end
    end,
    inline_ranges = function(_, _, line)
      local change = change_at(line)
      if not change then return end
      local ranges = {}
      for _, range in ipairs(change.inline_ranges or {}) do
        ranges[#ranges + 1] = { col1 = range.col1, col2 = range.col2, color = style["diff_" .. tag .. "_inline"] }
      end
      -- A marker shows where the other side has text that this side lacks.
      local marker_color = index == 2 and style.diff_inline_marker_delete or style.diff_inline_marker_insert
      for _, marker in ipairs(change.inline_markers or {}) do
        ranges[#ranges + 1] = { col1 = marker.col, col2 = marker.col, marker = true, color = marker_color }
      end
      return ranges
    end,
    text_color = function(_, _, line)
      if change_at(line) and config.plugins.diffview.plain_text then
        return config.plugins.diffview.plain_text_color
      end
    end,
  }
end

-- Draws the other side's lines with its own syntax, decorations and selection.
local SideSurface = TextView:extend()

function SideSurface:new(buffer, owner)
  SideSurface.super.new(self, buffer)
  self.owner = owner
  self.show_line_numbers = false
  self.show_current_line_highlight = false
  self.suppress_gitdiff_gutter = true
end

-- Rows share the unified surface's text origin and wrap width.
function SideSurface:get_gutter_width()
  return self.owner:get_gutter_width()
end

local function empty_projection(base)
  return { base = base, groups = {}, boundaries = {}, base_other = {}, blocks = {}, points = {} }
end

---Place the other side's changed lines between the lines of the base side.
---A group at boundary `k` sits before base line `k`; `k` past the last line
---places it after the last line.
function UnifiedView.project(model, base, opts)
  opts = opts or {}
  local projection = empty_projection(base)
  local base_key, other_key = side_key(base), side_key(3 - base)
  -- Removed lines come before added lines in each change block.
  local other_first = other_key == "a"
  local alignment = model.alignment
  local next_base = 1
  local i = 1
  while i <= #alignment do
    local pair = alignment[i]
    if pair.tag == "equal" then
      projection.base_other[pair[base_key]] = pair[other_key]
      next_base = pair[base_key] + 1
      i = i + 1
    else
      local last = i
      while alignment[last + 1] and alignment[last + 1].tag ~= "equal" do last = last + 1 end
      local block = { first_base = next_base }
      local other_lines, has_a, has_b = {}, false, false
      for index = i, last do
        local item = alignment[index]
        if item[other_key] then other_lines[#other_lines + 1] = item[other_key] end
        if item[base_key] then
          block.line1 = block.line1 or item[base_key]
          block.line2 = item[base_key]
          next_base = item[base_key] + 1
        end
        has_a = has_a or item.a ~= nil
        has_b = has_b or item.b ~= nil
      end
      block.tag = has_a and has_b and "modify" or has_a and "delete" or "insert"
      if #other_lines > 0 then
        local boundary = other_first and block.first_base or next_base
        local group = { boundary = boundary, lines = other_lines, block = block }
        projection.groups[boundary] = group
        projection.boundaries[#projection.boundaries + 1] = boundary
        block.group = group
      end
      projection.blocks[#projection.blocks + 1] = block
      i = last + 1
    end
    if opts.should_yield and opts.should_yield() then coroutine.yield() end
  end
  return projection
end

local function sorted_selection(selections, index)
  local line1, col1, line2, col2 = selections[index], selections[index + 1],
    selections[index + 2], selections[index + 3]
  if line1 > line2 or (line1 == line2 and col1 > col2) then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end

-- A selection includes a group when it spans the boundary between two lines,
-- or reaches the end of the Buffer for a group after the last line.
local function selection_crosses(lines, boundary, line1, col1, line2, col2)
  if line1 == line2 and col1 == col2 then return false end
  if boundary <= #lines then return line1 < boundary and line2 >= boundary end
  return line2 == #lines and col2 >= #lines[#lines]
end

local function group_first_row(view, group)
  local count = #view.buffer.lines
  if group.boundary <= count then
    return view:get_visual_row(group.boundary, 1, false) - #group.rows
  end
  return view:get_visual_row(count, 1, false) + view:get_visual_row_count_for_line(count)
end

local function draw_gutter_numbers(view, x, y, height, numbers, tag)
  local font = view:get_font()
  local gutter_width = view:get_gutter_width()
  if tag then
    renderer.draw_rect(x, y, gutter_width, height, style["diff_" .. tag .. "_background"])
  end
  local number_width = (gutter_width - font:get_width(" ") - style.padding.x * 2) / 2
  local row_height = view:get_line_height()
  x = x + style.padding.x
  common.draw_text(font, style.line_number, numbers[1] or "", "right", x, y, number_width, row_height)
  x = x + number_width + font:get_width(" ")
  common.draw_text(font, style.line_number, numbers[2] or "", "right", x, y, number_width, row_height)
end

local function draw_other_row(view, row, x, y)
  local surface = view:sync_other_surface()
  surface:with_selection_state(function()
    surface:draw_line_body(row.other_line, x, y)
  end)
end

local function draw_other_row_gutter(view, row, x, y, _, height)
  local index = view.other_index
  local numbers = {}
  numbers[index] = row.other_line
  draw_gutter_numbers(view, x, y, height, numbers, side_tag(index))
end

local function boundary_position(view, boundary)
  local lines = view.buffer.lines
  if boundary <= #lines then return boundary, 1 end
  return #lines, #lines[#lines]
end

local function hit_other_row(view, row)
  return boundary_position(view, row.group.boundary)
end

local function click_other_row(view, row, button)
  if button ~= "left" then return end
  local previous = view.__pressed_other_focus
  local extend = keymap.modkeys["shift"] and previous and previous.group == row.group
  view:focus_other_lines(row.group, extend and previous.anchor or row.other_line, row.other_line)
  view:keep_viewport_for_selection()
end

function UnifiedView:new(parent)
  local base = parent:get_unified_base_index()
  UnifiedView.super.new(self, parent.side_buffers[base])
  self.diff_view_parent = parent
  self.base_index, self.other_index = base, 3 - base
  self.projection = empty_projection(base)
  self.projection_generation = 0
  self.other_lines = {}
  self.points = {}
  self.other_surface = SideSurface(parent.side_buffers[3 - base], self)
  self.show_line_numbers = false
  self.show_current_line_highlight = false
  self.suppress_gitdiff_gutter = true
  self:add_decoration_provider("diff-view", change_decorations(parent, base))
  self.other_surface:add_decoration_provider("diff-view", change_decorations(parent, 3 - base))
  self:add_visual_row_provider(OTHER_ROWS, {
    visual_rows = function(_, _, line, placement)
      local groups = self.projection.groups
      local group
      if placement == "before" then
        group = groups[line]
      elseif line == #self.buffer.lines then
        group = groups[line + 1]
      end
      return group and group.rows
    end,
  }, { priority = 50 })
  self:add_poi_provider("diff-view", { points_of_interest = function() return self.points end })
  self:add_fold_listener("diff-view", function(_, event, fold)
    if event == "expand" and fold.metadata then parent:expand_fold(fold.metadata.diff_fold) end
  end)
  self:add_selection_listener("diff-view", function(_, state)
    local focus = self.other_focus
    local selections = state and state.selections or {}
    if focus and not (#selections == 4 and selections[1] == focus.line and selections[2] == focus.col
        and selections[3] == focus.line and selections[4] == focus.col) then
      self.other_focus = nil
    end
    self:refresh_other_selection()
    local reset = parent.request.user_data and parent.request.user_data.on_navigation_state_change
    if reset then reset() end
  end)
  self:add_edit_guard("diff-view", function()
    if self.other_focus then
      return false, self.other_index == 1 and "Removed lines are read-only" or "Added lines are read-only"
    end
    return parent:side_edit_permission(self.base_index)
  end)
end

function UnifiedView:on_close()
  UnifiedView.super.on_close(self)
  self.other_surface:on_close()
end

---Keep the other side's surface aligned with this view before it measures or draws.
function UnifiedView:sync_other_surface()
  local surface = self.other_surface
  surface.position.x, surface.position.y = self.position.x, self.position.y
  surface.size.x, surface.size.y = self.size.x, self.size.y
  local wrapping = self:is_wrapping_enabled()
  if surface:is_wrapping_enabled() ~= wrapping then surface:set_wrapping_enabled(wrapping) end
  if wrapping and surface.size.x > 0 then surface:update_wrap_cache() end
  surface.scroll.x, surface.scroll.to.x = self.scroll.x, self.scroll.x
  return surface
end

function UnifiedView:get_other_row_height(line)
  local surface = self:sync_other_surface()
  if not surface.wrapped_settings then return nil end
  return surface:get_visual_row_count_for_line(line) * surface:get_line_height()
end

-- Wrapped rows of the other side can take several lines of height.
function UnifiedView:refresh_other_row_metrics()
  local wrapping = self:is_wrapping_enabled()
  if wrapping == (self.__other_row_metrics == true) then return end
  self.__other_row_metrics = wrapping
  if not wrapping then
    self:remove_visual_metric_provider(OTHER_ROWS)
    return
  end
  self:add_visual_metric_provider(OTHER_ROWS, {
    priority = 100,
    generation = function()
      local surface = self.other_surface
      return table.concat({
        self.projection_generation, surface.buffer.text_revision or 0,
        surface.wrapped_settings and surface.wrapped_settings.width or 0,
      }, ":")
    end,
    line_height = function(_, _, _, entry)
      local row = entry.provider_row
      if row and row.group then return self:get_other_row_height(row.other_line) end
    end,
  })
end

function UnifiedView:update()
  self:sync_other_surface()
  self:refresh_other_row_metrics()
  return UnifiedView.super.update(self)
end

function UnifiedView:set_projection(projection)
  local focus = self.other_focus
  self.projection = projection
  self.projection_generation = self.projection_generation + 1
  self.other_lines = {}
  for _, boundary in ipairs(projection.boundaries) do
    local group = projection.groups[boundary]
    group.rows = {}
    for _, line in ipairs(group.lines) do
      local row = {
        id = tostring(line), other_line = line, group = group,
        draw = draw_other_row, draw_gutter = draw_other_row_gutter,
        hit_test = hit_other_row, on_click = click_other_row,
      }
      group.rows[#group.rows + 1] = row
      self.other_lines[line] = row
    end
  end
  local line_count = #self.buffer.lines
  self.points = {}
  for _, block in ipairs(projection.blocks) do
    self.points[#self.points + 1] = {
      line = math.min(block.first_base, line_count), col = 1, kind = "diff", source = "diff-view",
    }
  end
  self.__overview_geometry = nil
  self:invalidate_visual_rows(OTHER_ROWS)
  self:invalidate_visual_metrics(OTHER_ROWS)
  self.other_focus = nil
  if focus then self:restore_focus_state(focus) end
  self:refresh_other_selection()
  local pending = self.pending_source
  self.pending_source = nil
  if pending and self.diff_view_parent.unified then
    self:select_source(pending.view, pending.state)
  end
end

---Focus lines of the other side. They are read-only, so the hidden caret
---waits at their boundary until the selection moves.
function UnifiedView:focus_other_lines(group, anchor, line, opts)
  local caret_line, caret_col = boundary_position(self, group.boundary)
  self.other_focus = {
    group = group, anchor = anchor,
    line1 = math.min(anchor, line), line2 = math.max(anchor, line),
    line = caret_line, col = caret_col,
  }
  self:with_selection_state(function()
    if opts and opts.reveal then
      self:select_and_reveal(caret_line, caret_col, caret_line, caret_col, { instant = true })
    else
      self.buffer:set_selection(caret_line, caret_col)
    end
  end)
  self:refresh_other_selection()
  core.redraw = true
  core.log_quiet("Unified Diff focused %s lines %d-%d",
    self.other_index == 1 and "removed" or "added", self.other_focus.line1, self.other_focus.line2)
end

function UnifiedView:get_focus_state()
  local focus = self.other_focus
  return focus and { anchor = focus.anchor, line1 = focus.line1, line2 = focus.line2 } or nil
end

function UnifiedView:restore_focus_state(state)
  local row = state and self.other_lines[state.anchor]
  if not row then return false end
  local last = state.anchor == state.line1 and state.line2 or state.line1
  local last_row = self.other_lines[last]
  self:focus_other_lines(row.group, state.anchor, last_row and last_row.group == row.group and last or state.anchor)
  return true
end

---Return the inclusive other-side line range a patch scope should select.
function UnifiedView:get_other_focus_interval()
  local focus = self.other_focus
  if not focus then return nil end
  return { focus.line1, focus.line2, side = self.other_index == 1 and "left" or "right" }
end

function UnifiedView:refresh_other_selection()
  local surface = self.other_surface
  local other_lines = surface.buffer.lines
  local selections = {}
  local function add(line1, line2)
    local end_line, end_col = line2 + 1, 1
    if line2 >= #other_lines then end_line, end_col = line2, #other_lines[line2] end
    for _, value in ipairs { line1, 1, end_line, end_col } do selections[#selections + 1] = value end
  end
  local focus = self.other_focus
  if focus then
    add(focus.line1, focus.line2)
  else
    local state = self:get_selection_state().selections
    for index = 1, #state, 4 do
      local line1, col1, line2, col2 = sorted_selection(state, index)
      for _, boundary in ipairs(self.projection.boundaries) do
        if selection_crosses(self.buffer.lines, boundary, line1, col1, line2, col2) then
          local group = self.projection.groups[boundary]
          add(group.lines[1], group.lines[#group.lines])
        end
      end
    end
  end
  if #selections == 0 then selections = { 1, 1, 1, 1 } end
  surface:set_selection_state({ selections = selections, last_selection = 1 })
end

local function group_text(view, group, line1, line2)
  local lines = view.other_surface.buffer.lines
  local text = {}
  for line = line1 or group.lines[1], line2 or group.lines[#group.lines] do
    text[#text + 1] = lines[line]
  end
  return table.concat(text)
end

---Return copied text that includes other-side lines, or nil to copy Buffer text.
function UnifiedView:get_copy_text()
  local focus = self.other_focus
  if focus then return group_text(self, focus.group, focus.line1, focus.line2) end
  local selections = self:get_selection_state().selections
  if #selections ~= 4 then return nil end
  local line1, col1, line2, col2 = sorted_selection(selections, 1)
  local lines = self.buffer.lines
  local parts, line, col, crossed = {}, line1, col1, false
  for _, boundary in ipairs(self.projection.boundaries) do
    if selection_crosses(lines, boundary, line1, col1, line2, col2) then
      local target_line, target_col = boundary_position(self, boundary)
      if boundary > #lines then target_line, target_col = line2, col2 end
      parts[#parts + 1] = self.buffer:get_text(line, col, target_line, target_col)
      line, col = target_line, target_col
      if boundary > #lines and not table.concat(parts):match("\n$") then parts[#parts + 1] = "\n" end
      parts[#parts + 1] = group_text(self, self.projection.groups[boundary])
      crossed = true
    end
  end
  if not crossed then return nil end
  parts[#parts + 1] = self.buffer:get_text(line, col, line2, col2)
  return table.concat(parts)
end

function UnifiedView:draw_caret(...)
  if self.other_focus then return end
  return UnifiedView.super.draw_caret(self, ...)
end

function UnifiedView:on_mouse_pressed(button, x, y, clicks)
  local focus = self.other_focus
  if button == "left" and focus then
    -- A press elsewhere ends the focus even when the caret stays put.
    self.other_focus = nil
    self.__pressed_other_focus = focus
  end
  local handled = UnifiedView.super.on_mouse_pressed(self, button, x, y, clicks)
  self.__pressed_other_focus = nil
  if focus and not self.other_focus then
    self:refresh_other_selection()
    core.redraw = true
  end
  return handled
end

---Return the Diff Side index, line and column of the caret or focused line.
function UnifiedView:source_position()
  local focus = self.other_focus
  if focus then return self.other_index, focus.line1, 1 end
  local selections = self:get_selection_state().selections
  return self.base_index, selections[1], selections[2]
end

---Return where a line of either Diff Side is drawn, or nil when it has no row.
function UnifiedView:get_source_screen_position(index, line, col)
  col = col or 1
  if index == self.base_index then return self:get_line_screen_position(line, col) end
  local row = self.other_lines[line]
  if not row then return nil end
  local visual_row = group_first_row(self, row.group) + line - row.group.lines[1]
  local _, content_y = self:get_content_offset()
  local row_y = content_y + style.padding.y + self:get_visual_row_y_offset(visual_row)
  local surface = self:sync_other_surface()
  local x, y = surface:get_line_screen_position(line, col)
  local _, first_y = surface:get_line_screen_position(line, 1)
  return x, row_y + y - first_y
end

local function side_view(parent, index)
  return index == 1 and parent.buffer_view_a or parent.buffer_view_b
end

function UnifiedView:select_source(source, state)
  state = state or source:get_selection_state()
  local selection = state.selections
  if source.buffer == self.buffer then
    self:with_selection_state(function()
      self:select_and_reveal(selection[1], selection[2], selection[3], selection[4], { instant = true })
    end)
    return
  end
  local parent = self.diff_view_parent
  if not parent.diff_model then
    self.pending_source = { view = source, state = state }
    return
  end
  local row = self.other_lines[selection[1]]
  if row then
    self:focus_other_lines(row.group, selection[1], selection[1], { reveal = true })
    return
  end
  local line = parent.diff_model:map_line(side_key(self.other_index), selection[1])
  self:with_selection_state(function()
    self:select_and_reveal(line, selection[2], line, selection[2], { instant = true })
  end)
end

function UnifiedView:select_side()
  if self.pending_source then
    local pending = self.pending_source
    self.pending_source = nil
    pending.view:set_selection_state(pending.state)
    return pending.view
  end
  local parent = self.diff_view_parent
  local focus = self.other_focus
  local source = side_view(parent, focus and self.other_index or self.base_index)
  local selection = self:get_selection_state().selections
  source:with_selection_state(function()
    if focus then
      source:select_and_reveal(focus.line1, 1, focus.line1, 1, { instant = true })
    else
      source:select_and_reveal(selection[1], selection[2], selection[3], selection[4], { instant = true })
    end
  end)
  return source
end

function UnifiedView:get_path_target()
  local index, line = self:source_position()
  return self.diff_view_parent:get_side_path_target(index, self, line)
end

function UnifiedView:refresh_folds()
  for i = #self.fold_regions, 1, -1 do self:remove_fold_region(self.fold_regions[i], "diff-rebuild") end
  local folds = self.base_index == 1 and self.diff_view_parent.diff_folds_a or self.diff_view_parent.diff_folds_b
  for _, fold in ipairs(folds or {}) do
    local last = self.buffer.lines[fold.hidden_end]
    if last then
      self:add_fold_region { line1 = fold.hidden_start, col1 = 1, line2 = fold.hidden_end, col2 = #last + 1,
        kind = "diff-view", metadata = { diff_fold = fold },
        placeholder = string.format("⋯ %d unchanged lines folded ⋯", fold.hidden_count) }
    end
  end
end

function UnifiedView:reveal_change(direction)
  local point = self.points[direction == -1 and #self.points or 1]
  if not point then return false end
  self:with_selection_state(function() self:select_and_reveal(point.line, 1) end)
  return true
end

function UnifiedView:get_h_content_size()
  local width = UnifiedView.super.get_h_content_size(self)
  if self.wrapping_enabled or #self.projection.boundaries == 0 then return width end
  return math.max(width, self:sync_other_surface():get_h_content_size())
end

function UnifiedView:get_gutter_width()
  local parent = self.diff_view_parent
  local font = self:get_font()
  local width = font:get_width(tostring(math.max(#parent.buffer_view_a.buffer.lines, #parent.buffer_view_b.buffer.lines)))
  return width * 2 + font:get_width(" ") + style.padding.x * 2, style.padding.x
end

function UnifiedView:draw_line_gutter(line, x, y, width)
  local height = UnifiedView.super.draw_line_gutter(self, line, x, y, width)
  local change = side_changes(self.diff_view_parent, self.base_index)[line]
  local changed = change and change.tag ~= "equal"
  local numbers = {}
  numbers[self.base_index] = line
  if not changed then numbers[self.other_index] = self.projection.base_other[line] end
  draw_gutter_numbers(self, x, y, height, numbers, changed and side_tag(self.base_index) or nil)
  return height
end

local function overview_geometry(view)
  local signature = view:get_visual_metric_signature() .. ":" .. view.projection_generation
  local full_h = math.max(1, view:get_scrollable_size())
  local cache = view.__overview_geometry
  if cache and cache.signature == signature and cache.full_h == full_h then return cache.entries end
  local entries = {}
  local line_count = #view.buffer.lines
  for _, block in ipairs(view.projection.blocks) do
    local first_row, end_row
    if block.line1 and block.line2 <= line_count then
      first_row = view:get_visual_row(block.line1, 1, false)
      end_row = view:get_visual_row(block.line2, 1, false) + view:get_visual_row_count_for_line(block.line2)
    end
    if block.group and block.group.rows then
      local group_row = group_first_row(view, block.group)
      first_row = math.min(first_row or group_row, group_row)
      end_row = math.max(end_row or 0, group_row + #block.group.rows)
    end
    if first_row then
      local first = common.clamp(view:get_visual_row_y_offset(first_row) / full_h, 0, 1)
      entries[#entries + 1] = { tag = block.tag, first = first,
        last = common.clamp(view:get_visual_row_y_offset(end_row) / full_h, first, 1) }
    end
  end
  view.__overview_geometry = { signature = signature, full_h = full_h, entries = entries }
  return entries
end

function UnifiedView:draw_scrollbar()
  UnifiedView.super.draw_scrollbar(self)
  local scrollbar = self.v_scrollbar
  for _, marker in ipairs(overview_geometry(self)) do
    local x, y, w, h = scrollbar:get_overview_marker_rect(marker.first, marker.last)
    if x then
      local marker_w = math.min(w, math.max(1, common.round(5 * SCALE)))
      renderer.draw_rect(x + w - marker_w, y, marker_w, h, style["diff_overview_" .. marker.tag])
    end
  end
  scrollbar:draw_thumb()
end

return UnifiedView
