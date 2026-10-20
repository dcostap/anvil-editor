local core = require "core"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local linewrapping = require "core.linewrapping"
local style = require "core.style"
local TextView = require "core.textview"
local translate = require "core.buffer.translate"

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
      -- Both versions are visible here, so the side-by-side insertion position markers would only add noise.
      local ranges = {}
      for _, range in ipairs(change.inline_ranges or {}) do
        ranges[#ranges + 1] = { col1 = range.col1, col2 = range.col2, color = style["diff_" .. tag .. "_inline"] }
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

-- A Unified Position is `{ line, col }` in the Buffer, or `{ line, col, other = true }`
-- in a line of the other side. Its key orders it by where it is drawn: a group's
-- rows come before the base line at its boundary.
local function position_key(view, pos)
  if pos.other then return view.other_lines[pos.line].group.boundary, 0, pos.line, pos.col end
  local lines = view.buffer.lines
  -- The end of the Buffer includes a group placed after the last line.
  if pos.line == #lines and pos.col >= #lines[#lines] then return #lines + 1, 1, 0, 0 end
  return pos.line, 1, 0, pos.col
end

local function compare_positions(view, a, b)
  local a1, a2, a3, a4 = position_key(view, a)
  local b1, b2, b3, b4 = position_key(view, b)
  if a1 ~= b1 then return a1 < b1 and -1 or 1 end
  if a2 ~= b2 then return a2 < b2 and -1 or 1 end
  if a3 ~= b3 then return a3 < b3 and -1 or 1 end
  if a4 ~= b4 then return a4 < b4 and -1 or 1 end
  return 0
end

local function ordered_positions(view, anchor, caret)
  if compare_positions(view, anchor, caret) > 0 then return caret, anchor end
  return anchor, caret
end

-- Call `fn(group, line1, col1, line2, col2)` with the other-side text of each
-- group between two positions. `col2` past a line's last column includes its newline.
local function each_other_range(view, start, finish, fn)
  local other_lines = view.other_surface.buffer.lines
  for _, boundary in ipairs(view.projection.boundaries) do
    local group = view.projection.groups[boundary]
    local last = group.lines[#group.lines]
    local from = { line = group.lines[1], col = 1, other = true }
    local to = { line = last, col = #other_lines[last] + 1, other = true }
    if compare_positions(view, start, from) > 0 then from = start end
    if compare_positions(view, finish, to) < 0 then to = finish end
    if compare_positions(view, from, to) < 0 then fn(group, from.line, from.col, to.line, to.col) end
  end
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

-- Records the other side's line and column under the pointer, and gives
-- TextView the Buffer position at the group's boundary.
local function hit_other_row(view, row, x, y)
  local surface = view:sync_other_surface()
  local line, col = row.other_line, 1
  if surface.wrapped_settings then
    local idx = linewrapping.get_line_idx_col_count(surface, line)
    local rows = surface:get_visual_row_count_for_line(line)
    local offset = common.clamp(math.floor(y / surface:get_line_height()), 0, rows - 1)
    local hit_line, hit_col = linewrapping.get_line_col_from_index_and_x(surface, idx + offset, x)
    if hit_line == line then col = hit_col end
  else
    col = surface:get_x_offset_col(line, x)
  end
  view.resolved_other_position = { line = line, col = common.clamp(col, 1, #surface.buffer.lines[line]), other = true }
  return boundary_position(view, row.group.boundary)
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
    local selection = self.other_selection
    local selections = state and state.selections or {}
    if selection then
      local base = selection.base
      if not (#selections == 4 and selections[1] == base[1] and selections[2] == base[2]
          and selections[3] == base[3] and selections[4] == base[4]) then
        self.other_selection = nil
      end
    end
    self:refresh_other_selection()
    local reset = parent.request.user_data and parent.request.user_data.on_navigation_state_change
    if reset then reset() end
  end)
  self:add_edit_guard("diff-view", function()
    if self.other_selection then
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
  local focus = self:get_focus_state()
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
        hit_test = hit_other_row,
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
  self.other_selection = nil
  if focus then self:restore_focus_state(focus) end
  self:refresh_other_selection()
  local pending = self.pending_source
  self.pending_source = nil
  if pending and self.diff_view_parent.unified then
    self:select_source(pending.view, pending.state)
  end
end

-- The Buffer position where a selection end in the other side's lines meets
-- the Buffer: the boundary of that end's group.
local function buffer_position(view, pos)
  if pos.other then return boundary_position(view, view.other_lines[pos.line].group.boundary) end
  return pos.line, pos.col
end

---Select from `anchor` to `caret`, Unified Positions that can lie in the
---other side's lines. The Buffer selection keeps the part between them that
---is Buffer text; the other side's lines stay read-only.
function UnifiedView:select_unified(anchor, caret, opts)
  local reveal = opts and opts.reveal
  local function apply(line1, col1, line2, col2)
    self:with_selection_state(function()
      if reveal then
        self:select_and_reveal(line1, col1, line2, col2, { instant = true })
      else
        self.buffer:set_selection(line1, col1, line2, col2)
      end
    end)
  end
  if anchor.other or caret.other then
    local start, finish = ordered_positions(self, anchor, caret)
    local line1, col1 = buffer_position(self, start)
    local line2, col2 = buffer_position(self, finish)
    local base = start == anchor and { line2, col2, line1, col1 } or { line1, col1, line2, col2 }
    self.other_selection = { anchor = anchor, caret = caret, base = base }
    apply(base[1], base[2], base[3], base[4])
  else
    self.other_selection = nil
    apply(caret.line, caret.col, anchor.line, anchor.col)
  end
  if not reveal then self:keep_viewport_for_selection() end
  self:refresh_other_selection()
  core.redraw = true
end

function UnifiedView:get_focus_state()
  local selection = self.other_selection
  return selection and { anchor = selection.anchor, caret = selection.caret } or nil
end

function UnifiedView:restore_focus_state(state)
  if not (state and state.anchor and state.caret) then return false end
  local function valid(pos)
    if pos.other then
      local line = self.other_surface.buffer.lines[pos.line]
      return self.other_lines[pos.line] ~= nil
        and { line = pos.line, col = common.clamp(pos.col, 1, #line + 1), other = true }
    end
    local lines = self.buffer.lines
    local line = common.clamp(pos.line, 1, #lines)
    return { line = line, col = common.clamp(pos.col, 1, #lines[line]) }
  end
  local anchor, caret = valid(state.anchor), valid(state.caret)
  if not (anchor and caret) then return false end
  self:select_unified(anchor, caret)
  return true
end

---Return the inclusive line ranges a patch scope should select when the
---selection reaches the other side's lines, or nil to use the Buffer selection.
function UnifiedView:get_patch_intervals(scope_kind)
  local selection = self.other_selection
  if not selection then return nil end
  local function side(index) return index == 1 and "left" or "right" end
  if scope_kind == "cursor" then
    local caret = selection.caret
    return { { caret.line, caret.line, side = side(caret.other and self.other_index or self.base_index) } }
  end
  local intervals = {}
  local function add(index, line1, line2, col2)
    intervals[#intervals + 1] = { line1, line2 - ((col2 == 1 and line2 > line1) and 1 or 0), side = side(index) }
  end
  local start, finish = ordered_positions(self, selection.anchor, selection.caret)
  each_other_range(self, start, finish, function(_, line1, _, line2, col2) add(self.other_index, line1, line2, col2) end)
  local line1, col1, line2, col2 = sorted_selection(selection.base, 1)
  if line1 ~= line2 or col1 ~= col2 then add(self.base_index, line1, line2, col2) end
  return intervals
end

function UnifiedView:refresh_other_selection()
  local surface = self.other_surface
  local other_lines = surface.buffer.lines
  local selections = {}
  local function add(_, line1, col1, line2, col2)
    -- The surface places a range that includes a line's newline at the next line.
    if col2 > #other_lines[line2] then
      if line2 < #other_lines then line2, col2 = line2 + 1, 1 else col2 = #other_lines[line2] end
    end
    for _, value in ipairs { line1, col1, line2, col2 } do selections[#selections + 1] = value end
  end
  local selection = self.other_selection
  if selection then
    local start, finish = ordered_positions(self, selection.anchor, selection.caret)
    each_other_range(self, start, finish, add)
  else
    local state = self:get_selection_state().selections
    for index = 1, #state, 4 do
      local line1, col1, line2, col2 = sorted_selection(state, index)
      each_other_range(self, { line = line1, col = col1 }, { line = line2, col = col2 }, add)
    end
  end
  if #selections == 0 then selections = { 1, 1, 1, 1 } end
  surface:set_selection_state({ selections = selections, last_selection = 1 })
end

local function other_text(view, line1, col1, line2, col2)
  local lines = view.other_surface.buffer.lines
  if line1 == line2 then return lines[line1]:sub(col1, col2 - 1) end
  local parts = { lines[line1]:sub(col1) }
  for line = line1 + 1, line2 - 1 do parts[#parts + 1] = lines[line] end
  parts[#parts + 1] = lines[line2]:sub(1, col2 - 1)
  return table.concat(parts)
end

-- Return the text between two positions in visual order, and whether it
-- includes lines of the other side.
local function selection_text(view, start, finish)
  local lines = view.buffer.lines
  local parts, crossed = {}, false
  local line, col
  if not start.other then line, col = start.line, start.col end
  each_other_range(view, start, finish, function(group, line1, col1, line2, col2)
    if line then
      local target_line, target_col = boundary_position(view, group.boundary)
      parts[#parts + 1] = view.buffer:get_text(line, col, target_line, target_col)
      if group.boundary > #lines and not table.concat(parts):match("\n$") then parts[#parts + 1] = "\n" end
    end
    parts[#parts + 1] = other_text(view, line1, col1, line2, col2)
    line, col = boundary_position(view, group.boundary)
    crossed = true
  end)
  if not finish.other then parts[#parts + 1] = view.buffer:get_text(line, col, finish.line, finish.col) end
  return table.concat(parts), crossed
end

---Return copied text that includes other-side lines, or nil to copy Buffer text.
function UnifiedView:get_copy_text()
  local selection = self.other_selection
  if selection then
    local start, finish = ordered_positions(self, selection.anchor, selection.caret)
    -- A caret alone copies its whole line, as in the Buffer.
    if compare_positions(self, start, finish) == 0 then return self.other_surface.buffer.lines[start.line] end
    return (selection_text(self, start, finish))
  end
  local selections = self:get_selection_state().selections
  if #selections ~= 4 then return nil end
  local line1, col1, line2, col2 = sorted_selection(selections, 1)
  if line1 == line2 and col1 == col2 then return nil end
  local text, crossed = selection_text(self, { line = line1, col = col1 }, { line = line2, col = col2 })
  return crossed and text or nil
end

-- A caret in the other side's lines is drawn there instead of at the boundary.
function UnifiedView:draw_caret(x, y, line, col, ...)
  local selection = self.other_selection
  local caret = selection and selection.caret
  if caret and caret.other then
    local lines = self.other_surface.buffer.lines
    x, y = self:get_source_screen_position(self.other_index, caret.line, math.min(caret.col, #lines[caret.line]))
    if not x then return end
  end
  return UnifiedView.super.draw_caret(self, x, y, line, col, ...)
end

---Return the Unified Position under a screen point.
function UnifiedView:resolve_unified_position(x, y)
  self.resolved_other_position = nil
  local line, col = self:resolve_screen_position(x, y)
  local other = self.resolved_other_position
  self.resolved_other_position = nil
  self.resolved_provider_row = nil
  return other or { line = line, col = col }
end

local function snap_position(view, pos, snap, at_end)
  local buffer = pos.other and view.other_surface.buffer or view.buffer
  local line, col = pos.line, 1
  if snap == "word" then
    line, col = (at_end and translate.end_of_word or translate.start_of_word)(buffer, pos.line, pos.col)
    if line ~= pos.line then line, col = pos.line, pos.col end
  elseif at_end then
    local group_lines = pos.other and view.other_lines[pos.line].group.lines
    local last = group_lines and group_lines[#group_lines] or #buffer.lines
    if pos.line < last then
      line = pos.line + 1
    else
      col = #buffer.lines[pos.line] + (pos.other and 1 or 0)
    end
  end
  return { line = line, col = col, other = pos.other }
end

-- Widen a pointer selection to whole words or lines, keeping its direction.
local function snap_range(view, anchor, caret, snap)
  if snap ~= "word" and snap ~= "lines" then return anchor, caret end
  local start, finish = ordered_positions(view, anchor, caret)
  start, finish = snap_position(view, start, snap, false), snap_position(view, finish, snap, true)
  if compare_positions(view, anchor, caret) > 0 then return finish, start end
  return start, finish
end

function UnifiedView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" or self.hovering_gutter or self:scrollbar_hovering() then
    return UnifiedView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  local pos = self:resolve_unified_position(x, y)
  local selection = self.other_selection
  local shift = keymap.modkeys["shift"]
  if not pos.other and not (shift and selection) then
    -- A press in Buffer text ends the selection even when the caret stays put.
    self.other_selection = nil
    local handled = UnifiedView.super.on_mouse_pressed(self, button, x, y, clicks)
    if selection then
      self:refresh_other_selection()
      core.redraw = true
    end
    return handled
  end
  self.buffer:clear_search_selections()
  local anchor = pos
  if shift then
    local state = self:get_selection_state().selections
    anchor = selection and selection.anchor or { line = state[3], col = state[4] }
  end
  -- Click counts cycle like the keymap's click bindings.
  local click_number = (clicks - 1) % config.max_clicks + 1
  local snap = not shift and (click_number == 2 and "word" or click_number == 3 and "lines") or nil
  self.unified_drag = { anchor = anchor, snap = snap }
  self:select_unified(snap_range(self, anchor, pos, snap))
  core.blink_reset()
  core.log_quiet("Unified Diff selection started in %s line %d",
    pos.other and (self.other_index == 1 and "removed" or "added") or "Buffer", pos.line)
  return true
end

function UnifiedView:on_mouse_moved(x, y, ...)
  local drag = self.unified_drag
  -- A refreshed comparison can remove the line where the drag started.
  if drag and drag.anchor.other and not self.other_lines[drag.anchor.line] then
    drag, self.unified_drag = nil, nil
  end
  local buffer_drag = self.mouse_selecting
  -- Ctrl adds carets instead, and keeps them in Buffer text.
  if not drag and buffer_drag and not keymap.modkeys["ctrl"] then
    local pos = self:resolve_unified_position(x, y)
    if pos.other then
      -- A drag that started in Buffer text continues into the other side's lines.
      drag = { anchor = { line = buffer_drag[1], col = buffer_drag[2] }, snap = buffer_drag[3] }
      self.unified_drag = drag
      self.mouse_selecting = nil
    end
  end
  local handled = UnifiedView.super.on_mouse_moved(self, x, y, ...)
  if not drag then return handled end
  self:select_unified(snap_range(self, drag.anchor, self:resolve_unified_position(x, y), drag.snap))
  return true
end

function UnifiedView:on_mouse_released(...)
  self.unified_drag = nil
  return UnifiedView.super.on_mouse_released(self, ...)
end

local function position_buffer(view, pos)
  return pos.other and view.other_surface.buffer or view.buffer
end

local function position_lines(view, pos)
  return position_buffer(view, pos).lines
end

local function source_index(view, pos)
  return pos.other and view.other_index or view.base_index
end

-- The line drawn next to `pos`'s line in `direction`, or nil at either end of
-- the Unified Diff.
local function adjacent_line(view, pos, direction)
  local groups = view.projection.groups
  local count = #view.buffer.lines
  if pos.other then
    local group = view.other_lines[pos.line].group
    local lines = group.lines
    if direction > 0 then
      if pos.line < lines[#lines] then return { line = pos.line + 1, other = true } end
      if group.boundary <= count then return { line = group.boundary } end
    else
      if pos.line > lines[1] then return { line = pos.line - 1, other = true } end
      if group.boundary > 1 then return { line = group.boundary - 1 } end
    end
    return nil
  end
  local group = groups[direction > 0 and pos.line + 1 or pos.line]
  if group then return { line = group.lines[direction > 0 and 1 or #group.lines], other = true } end
  local line = pos.line + direction
  if line >= 1 and line <= count then return { line = line } end
end

local function line_edge(view, pos, direction)
  local text = position_lines(view, pos)[pos.line]
  return { line = pos.line, col = direction > 0 and #text or 1, other = pos.other }
end

-- Move by a Buffer translation such as a character or word step. A step that
-- leaves its lines for the other kind stops at the edge of the first line drawn there.
local function translate_step(view, pos, translation, direction)
  local lines = position_lines(view, pos)
  local line, col = translation(position_buffer(view, pos), pos.line, pos.col)
  local moved = line ~= pos.line or col ~= pos.col
  local function enter(neighbor)
    if not neighbor then return line_edge(view, pos, direction) end
    neighbor.col = line_edge(view, neighbor, -direction).col
    return neighbor
  end
  if pos.other then
    local group_lines = view.other_lines[pos.line].group.lines
    if moved and line >= group_lines[1] and line <= group_lines[#group_lines] then
      return { line = line, col = common.clamp(col, 1, #lines[line]), other = true }
    end
    local last = { line = group_lines[direction > 0 and #group_lines or 1], other = true }
    return enter(adjacent_line(view, last, direction))
  end
  local groups = view.projection.groups
  if direction > 0 then
    -- A step that cannot pass the end of the Buffer can still enter lines after it.
    local stop = moved and line or (pos.line == #lines and #lines + 1 or pos.line)
    for boundary = pos.line + 1, stop do
      if groups[boundary] then return enter({ line = groups[boundary].lines[1], other = true }) end
    end
  else
    local stop = moved and line + 1 or (pos.line == 1 and 1 or pos.line + 1)
    for boundary = pos.line, stop, -1 do
      if groups[boundary] then return enter({ line = groups[boundary].lines[#groups[boundary].lines], other = true }) end
    end
  end
  return { line = line, col = col }
end

local function text_origin_x(view)
  local x = view:get_content_offset()
  return x + view:get_gutter_width()
end

-- The text offset vertical moves keep, shared with TextView's own line moves.
local function goal_x(view, pos, x)
  local goal = view.unified_goal
  if goal and goal.line == pos.line and goal.col == pos.col and goal.other == pos.other then return goal.x end
  local xo = view.last_x_offset
  if not pos.other and xo and xo.line == pos.line and xo.col == pos.col and xo.offset then return xo.offset end
  return x - text_origin_x(view)
end

-- Move by `distance` pixels through the drawn rows. Returns the target and the
-- goal offset to keep. A move past the first or last row goes to the start or end of its line.
local function vertical_step(view, pos, distance)
  local x, y = view:get_source_screen_position(source_index(view, pos), pos.line, pos.col)
  if not y then return nil end
  local offset = goal_x(view, pos, x)
  local target = view:resolve_unified_position(text_origin_x(view) + offset, y + distance + view:get_line_height() / 2)
  local _, target_y = view:get_source_screen_position(source_index(view, target), target.line, target.col)
  if not target_y or (distance < 0 and target_y >= y) or (distance > 0 and target_y <= y) then
    target = line_edge(view, pos, distance)
  end
  return target, offset
end

local function step(translation, direction)
  return function(view, pos) return translate_step(view, pos, translation, direction) end
end

local function rows(direction, page)
  return function(view, pos)
    local line_height = view:get_line_height()
    local distance = page and math.max(line_height, view.size.y - line_height * 2) or line_height
    return vertical_step(view, pos, direction * distance)
  end
end

local motions = {
  previous_char = step(translate.previous_char, -1),
  next_char = step(translate.next_char, 1),
  previous_word_start = step(translate.previous_word_start, -1),
  next_word_end = step(translate.next_word_end, 1),
  previous_line = rows(-1),
  next_line = rows(1),
  previous_page = rows(-1, true),
  next_page = rows(1, true),
  start_of_buffer = function(view)
    local group = view.projection.groups[1]
    if group then return { line = group.lines[1], col = 1, other = true } end
    return { line = 1, col = 1 }
  end,
  end_of_buffer = function(view)
    local lines = view.buffer.lines
    local group = view.projection.groups[#lines + 1]
    if group then return line_edge(view, { line = group.lines[#group.lines], other = true }, 1) end
    return { line = #lines, col = #lines[#lines] }
  end,
}

-- Home and End stay within the line the caret is on.
for _, name in ipairs { "start_of_line", "start_of_indentation", "end_of_line" } do
  motions[name] = function(view, pos)
    local _, col = translate[name](position_buffer(view, pos), pos.line, pos.col)
    return { line = pos.line, col = common.clamp(col, 1, #position_lines(view, pos)[pos.line]), other = pos.other }
  end
end

-- Arrow, word, line, page and Buffer-edge moves reach the other side's lines as
-- well. Moves that stay in Buffer text are left to TextView.
function UnifiedView:handle_selection_command(name)
  local kind, target = name:match("^core:(%a+)_to_(.+)$")
  local motion = motions[target]
  if not motion or (kind ~= "move" and kind ~= "select") then return false end
  local selection = self.other_selection
  local caret, anchor
  if selection then
    caret, anchor = selection.caret, selection.anchor
  else
    local state = self:get_selection_state().selections
    -- Several carets keep the Buffer's own moves.
    if #state ~= 4 then return false end
    caret, anchor = { line = state[1], col = state[2] }, { line = state[3], col = state[4] }
  end
  local extend = kind == "select"
  local pos, goal
  if not extend and selection and (target == "previous_char" or target == "next_char")
      and compare_positions(self, caret, anchor) ~= 0 then
    -- A character move collapses a selection to its start or end, as in the Buffer.
    local start, finish = ordered_positions(self, anchor, caret)
    pos = target == "previous_char" and start or finish
  else
    pos, goal = motion(self, caret)
  end
  if not pos or not (selection or pos.other) then return false end
  if goal then
    self.unified_goal = { line = pos.line, col = pos.col, other = pos.other, x = goal }
    if not pos.other then self.last_x_offset = { line = pos.line, col = pos.col, offset = goal } end
  end
  if extend and pos.other and not anchor.other then
    local lines = self.buffer.lines
    local group = self.other_lines[pos.line].group
    if group.boundary > #lines and anchor.line == #lines and anchor.col >= #lines[#lines] then
      -- The end of the Buffer sorts after lines placed below the last line, so
      -- a selection that starts there and moves down starts at those lines.
      anchor = { line = group.lines[1], col = 1, other = true }
    end
  end
  if caret.other ~= pos.other then
    core.log_quiet("Unified Diff caret moved into %s line %d by %s",
      pos.other and (self.other_index == 1 and "removed" or "added") or "Buffer", pos.line, name)
  end
  self:select_unified(extend and anchor or pos, pos)
  self:reveal_unified_position(pos)
  core.blink_reset()
  return true
end

---Scroll so a Unified Position is visible, with the usual context rows.
function UnifiedView:reveal_unified_position(pos)
  local x, y = self:get_source_screen_position(source_index(self, pos), pos.line, pos.col)
  if not y then return end
  local line_height = self:get_line_height()
  local context = line_height * self:get_visible_scroll_context_lines()
  local top = y - self.position.y + self.scroll.y
  local above = top - style.padding.y - context
  local below = top + line_height + context - self.size.y + self:get_horizontal_scrollbar_height()
  self.scroll.to.y = math.max(0, common.clamp(self.scroll.to.y, below, above))
  if not self.wrapping_enabled then
    local text_x = x - text_origin_x(self)
    local _, _, scroll_w = self.v_scrollbar:get_track_rect()
    local width = math.max(0, self.size.x - scroll_w - self:get_gutter_width())
    local margin = self:get_font():get_width(" ") * 4
    self.scroll.to.x = math.max(0, common.clamp(self.scroll.to.x, text_x + margin - width, text_x - margin))
  end
end

---Return the Diff Side index, line and column of the caret.
function UnifiedView:source_position()
  local selection = self.other_selection
  local caret = selection and selection.caret
  if caret and caret.other then
    return self.other_index, caret.line, math.min(caret.col, #self.other_surface.buffer.lines[caret.line])
  end
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
  if self.other_lines[selection[1]] then
    local caret = { line = selection[1], col = selection[2], other = true }
    local anchor = self.other_lines[selection[3]] and { line = selection[3], col = selection[4], other = true } or caret
    self:select_unified(anchor, caret, { reveal = true })
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
  local other_selection = self.other_selection
  local caret = other_selection and other_selection.caret
  local on_other = caret and caret.other
  local source = side_view(parent, on_other and self.other_index or self.base_index)
  local selection = self:get_selection_state().selections
  source:with_selection_state(function()
    if on_other then
      local lines = source.buffer.lines
      -- A range that includes a line's newline ends at the next line.
      local function place(pos)
        if pos.col > #lines[pos.line] and pos.line < #lines then return pos.line + 1, 1 end
        return pos.line, math.min(pos.col, #lines[pos.line])
      end
      local anchor = other_selection.anchor.other and other_selection.anchor or caret
      local line1, col1 = place(caret)
      local line2, col2 = place(anchor)
      source:select_and_reveal(line1, col1, line2, col2, { instant = true })
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
