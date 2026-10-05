local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"

local UnifiedView = TextView:extend()

-- Keep source text unchanged. Signs and source line numbers belong to the gutter.
function UnifiedView.project(model, before, after, opts)
  local rows, text, a_rows, b_rows, points = {}, {}, {}, {}, {}
  local function append(pair, tag)
    local a = tag ~= "insert" and pair.a or nil
    local b = tag ~= "delete" and pair.b or nil
    rows[#rows + 1] = { a = a, b = b, tag = tag }
    text[#text + 1] = b and after[b] or before[a]
    if a then a_rows[a] = #rows end
    if b then b_rows[b] = #rows end
    if opts.should_yield and opts.should_yield() then coroutine.yield() end
  end
  local i = 1
  while i <= #model.alignment do
    local pair = model.alignment[i]
    if pair.tag == "equal" then
      append(pair, "equal")
      i = i + 1
    else
      local last = i
      while model.alignment[last + 1] and model.alignment[last + 1].tag ~= "equal" do last = last + 1 end
      points[#points + 1] = { line = #rows + 1, col = 1, kind = "diff", source = "diff-view" }
      for index = i, last do
        if model.alignment[index].a then append(model.alignment[index], "delete") end
      end
      for index = i, last do
        if model.alignment[index].b then append(model.alignment[index], "insert") end
      end
      i = last + 1
    end
  end
  return { rows = rows, text = table.concat(text), a_rows = a_rows, b_rows = b_rows, points = points }
end

function UnifiedView:new(parent)
  UnifiedView.super.new(self, Buffer())
  self.diff_view_parent = parent
  self.rows, self.a_rows, self.b_rows, self.points = {}, {}, {}, {}
  self.show_line_numbers = false
  self.show_current_line_highlight = false
  self.suppress_gitdiff_gutter = true
  self.buffer.display_name = "Unified Diff"
  self.buffer.read_only = true
  self.buffer.read_only_reason = "Unified comparisons are read-only"
  self:add_decoration_provider("diff-view", {
    line_background = function(_, _, line)
      local row = self.rows[line]
      if not row or row.tag == "equal" then return end
      return style["diff_" .. row.tag .. "_background"]
    end,
    inline_ranges = function(_, _, line)
      local row = self.rows[line]
      if not row or row.tag == "equal" then return end
      local changes = row.b and parent.b_changes or parent.a_changes
      local change = changes[row.b or row.a]
      local ranges = {}
      for _, range in ipairs(change and change.inline_ranges or {}) do
        ranges[#ranges + 1] = {
          col1 = range.col1, col2 = range.col2,
          color = style["diff_" .. row.tag .. "_inline"],
        }
      end
      local marker_color = row.b and style.diff_delete_inline or style.diff_insert_inline
      for _, marker in ipairs(change and change.inline_markers or {}) do
        ranges[#ranges + 1] = { col1 = marker.col, col2 = marker.col, marker = true, color = marker_color }
      end
      return ranges
    end,
  })
  self:add_line_render_provider("diff-syntax", {
    generation = function()
      return table.concat({ parent.diff_generation, parent.buffer_view_a.buffer.highlighter.render_generation or 0,
        parent.buffer_view_b.buffer.highlighter.render_generation or 0, tostring(config.plugins.diffview.plain_text) }, ":")
    end,
    render_line = function(_, _, line)
      local row = self.rows[line]
      if not row then return end
      local source = row.b and parent.buffer_view_b.buffer or parent.buffer_view_a.buffer
      local fragments, col = {}, 1
      local plain = row.tag ~= "equal" and config.plugins.diffview.plain_text
      for _, kind, text in source.highlighter:each_token(row.b or row.a) do
        fragments[#fragments + 1] = { text = text, source_col1 = col, source_col2 = col + #text,
          color = plain and config.plugins.diffview.plain_text_color or style.syntax[kind],
          font = not plain and style.syntax_fonts[kind] or nil }
        col = col + #text
      end
      return { fragments = fragments }
    end,
  })
  self:add_poi_provider("diff-view", { points_of_interest = function() return self.points end })
  self:add_fold_listener("diff-view", function(_, event, fold)
    if event == "expand" and fold.metadata then parent:expand_fold(fold.metadata.diff_fold) end
  end)
  self:add_selection_listener("diff-view", function()
    local reset = parent.request.user_data and parent.request.user_data.on_navigation_state_change
    if reset then reset() end
  end)
end

function UnifiedView:source_position(line, col)
  local row = self.rows[line or self:get_selection_state().selections[1]]
  if not row then return 2, 1, col or 1 end
  return row.b and 2 or 1, row.b or row.a, col or 1
end

function UnifiedView:set_projection(projection)
  local selection = self:get_selection_state().selections
  local side, line, col = self:source_position(selection[1], selection[2])
  self.rows, self.a_rows, self.b_rows, self.points = projection.rows, projection.a_rows, projection.b_rows, projection.points
  self.buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = #self.buffer.lines, col2 = math.huge,
    text = projection.text:gsub("\n$", "") } }, { record_undo = false, type = "unified-diff" })
  self.buffer:clean()
  self:invalidate_line_render("diff-syntax")
  local pending = self.pending_source
  self.pending_source = nil
  if pending and self.diff_view_parent.unified then
    self:select_source(pending.view, pending.state)
    return
  end
  if self.diff_view_parent.unified then
    local mapped = (side == 1 and self.a_rows or self.b_rows)[line] or 1
    self:with_selection_state(function() self.buffer:set_selection(mapped, col) end)
  end
end

function UnifiedView:select_source(source, state)
  state = state or source:get_selection_state()
  if not self.diff_view_parent.diff_model then
    self.pending_source = { view = source, state = state }
    return
  end
  local mapping = source == self.diff_view_parent.buffer_view_a and self.a_rows or self.b_rows
  local selection = state.selections
  self:with_selection_state(function()
    self:select_and_reveal(mapping[selection[1]] or 1, selection[2],
      mapping[selection[3]] or 1, selection[4], { instant = true })
  end)
end

function UnifiedView:select_side()
  if self.pending_source then
    local pending = self.pending_source
    self.pending_source = nil
    pending.view:set_selection_state(pending.state)
    return pending.view
  end
  local selection = self:get_selection_state().selections
  local index, line, col = self:source_position(selection[1], selection[2])
  local end_index, end_line, end_col = self:source_position(selection[3], selection[4])
  local parent = self.diff_view_parent
  local source = index == 1 and parent.buffer_view_a or parent.buffer_view_b
  source:with_selection_state(function()
    source:select_and_reveal(line, col, end_index == index and end_line or line,
      end_index == index and end_col or col, { instant = true })
  end)
  return source
end

function UnifiedView:get_path_target()
  local parent = self.diff_view_parent
  local index = self:source_position()
  return parent:get_side_path_target(index, self)
end

function UnifiedView:refresh_folds()
  for i = #self.fold_regions, 1, -1 do self:remove_fold_region(self.fold_regions[i], "diff-rebuild") end
  for _, fold in ipairs(self.diff_view_parent.diff_folds_a or {}) do
    local first, last = self.a_rows[fold.hidden_start], self.a_rows[fold.hidden_end]
    if first and last then
      self:add_fold_region { line1 = first, col1 = 1, line2 = last, col2 = #self.buffer.lines[last] + 1,
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

function UnifiedView:get_gutter_width()
  local parent = self.diff_view_parent
  local font = self:get_font()
  local width = font:get_width(tostring(math.max(#parent.buffer_view_a.buffer.lines, #parent.buffer_view_b.buffer.lines)))
  return width * 2 + font:get_width("  +  ") + style.padding.x * 2, style.padding.x
end

function UnifiedView:draw_line_gutter(line, x, y, width)
  local height = UnifiedView.super.draw_line_gutter(self, line, x, y, width)
  local row = self.rows[line]
  if not row then return height end
  local font = self:get_font()
  local number_width = (width - font:get_width("  +  ") - style.padding.x * 2) / 2
  x = x + style.padding.x
  local row_height = self:get_position_visual_row_height(line, 1)
  common.draw_text(font, style.line_number, row.a or "", "right", x, y, number_width, row_height)
  x = x + number_width + font:get_width(" ")
  common.draw_text(font, style.line_number, row.b or "", "right", x, y, number_width, row_height)
  x = x + number_width + font:get_width("  ")
  local sign = row.tag == "delete" and "−" or row.tag == "insert" and "+" or ""
  common.draw_text(font, style.text, sign, "left", x, y, font:get_width("+"), row_height)
  return height
end

return UnifiedView
