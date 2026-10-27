-- The Terminal View's find card. It looks and acts like the find card of a text file.
-- The native session searches the live screen and scrollback, so the matches follow new output.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local Buffer = require "core.buffer"
local Highlighter = require "core.buffer.highlighter"
local Object = require "core.object"
local TextView = require "core.textview"
local card = require "core.card"
local file_context = require "core.file_context"
local panes = require "core.panes"
local prompt_bar_renderer = require "core.prompt_bar_renderer"
local translate = require "core.buffer.translate"

local CARD_MAX_WIDTH = 440
local INFO_SAMPLES = { "8888 / 10000+", "No results", "Searching…" }

local last_query = ""

local PlainHighlighter = Highlighter:extend()
function PlainHighlighter:get_line()
  return { text = self.buffer.lines[1], tokens = { "normal", self.buffer.lines[1] } }
end
function PlainHighlighter:start() end

local QueryBuffer = Buffer:extend()
function QueryBuffer:reset()
  QueryBuffer.super.reset(self)
  self.highlighter = PlainHighlighter(self)
  self:reset_syntax()
end
function QueryBuffer:normalize_edit_text(text)
  return tostring(text or ""):gsub("[\r\n]", "")
end
function QueryBuffer:insert(line, col, text)
  QueryBuffer.super.insert(self, line, col, self:normalize_edit_text(text))
end

local QueryInput = TextView:extend()
function QueryInput:__tostring() return "TerminalFindInput" end

function QueryInput:new(find)
  QueryInput.super.new(self, QueryBuffer())
  self.terminal_find = find
  -- Find searches content, not a one-line field.
  self.local_find_disabled = true
  self.scrollable = false
  self.hide_scrollbars = true
  self.font = "font"
  self.size.y = 0
  function self.buffer:on_text_change() find:on_query_change() end
end

function QueryInput:get_text() return self.buffer:get_text(1, 1, 1, math.huge) end

function QueryInput:set_text(text)
  self.buffer:remove(1, 1, math.huge, math.huge)
  self.buffer:text_input(text or "")
end

function QueryInput:select_all() self.buffer:set_selection(math.huge, math.huge, 1, 1) end
function QueryInput:get_gutter_width() return 0, 0 end
function QueryInput:get_line_height() return prompt_bar_renderer.line_height(self:get_font()) end
function QueryInput:get_scrollable_size() return self:get_line_height() end
function QueryInput:get_h_scrollable_size() return math.huge end
function QueryInput:draw_scrollbar() end
function QueryInput:draw_line_highlight() end
function QueryInput:draw_line_gutter() return self:get_line_height() end
-- The card draws the field behind the input.
function QueryInput:draw_background() end

function QueryInput:get_line_screen_position(_, col)
  local x = QueryInput.super.get_line_screen_position(self, 1, col)
  local _, y = self:get_content_offset()
  return x, prompt_bar_renderer.line_y(y, self.size.y, self:get_font())
end

function QueryInput:draw_overlay()
  if core.active_view == self then QueryInput.super.draw_overlay(self) end
end

local Find = Object:extend()

function Find:new(view)
  self.view = view
  self.input = QueryInput(self)
  file_context.exclude_content_view(self.input)
  self.visible = false
  self.case_sensitive = config.find_case_sensitive or false
  self:clear()
end

function Find:clear()
  self.matches, self.shift, self.current = {}, 0, 0
  self.delivered, self.stale, self.marks = false, false, nil
end

function Find:query() return self.input:get_text() end

function Find:focused() return core.active_view == self.input end

function Find:focus()
  panes.register_focus_target(self.view, self.input)
  core.set_active_view(self.input)
  core.blink_reset()
  core.redraw = true
end

-- A one-line terminal selection becomes the query, as in a text file. Otherwise the last query stays.
function Find:open()
  if not self.visible then
    self.visible = true
    self:clear()
    self.origin, self.reveal = nil, true
    core.log_quiet("Terminal session %s find opened", tostring(self.view.log_id))
  end
  local session = self.view.session
  local selected = session and session:selected_text()
  if selected and selected ~= "" and not selected:find("[\r\n]") then
    if selected ~= self:query() then self.input:set_text(selected) end
  elseif self:query() == "" and last_query ~= "" then
    self.input:set_text(last_query)
  end
  self.input:select_all()
  self:focus()
end

-- A View that closes passes `closing`. Its Pane then moves the focus.
function Find:close(closing)
  if not self.visible then return end
  self.visible = false
  self:clear()
  local session = self.view.session
  if session then session:find("", false) end
  if self:focused() and not closing then core.set_active_view(self.view) end
  panes.unregister_focus_target(self.input)
  core.log_quiet("Terminal session %s find closed", tostring(self.view.log_id))
  core.redraw = true
end

-- Matches keep their rows from the scan that found them. `shift` counts the rows that output pruned since then.
function Find:row(match) return match.row - self.shift end

function Find:position()
  local match = self.matches[self.current]
  return match and { row = self:row(match), col = match.col1 }
end

function Find:on_query_change()
  last_query = self:query()
  self.origin = self:position() or self.origin
  self:clear()
  self.reveal = true
  core.redraw = true
end

function Find:toggle_case()
  self.case_sensitive = not self.case_sensitive
  self.origin = self:position() or self.origin
  self:clear()
  self.reveal = true
  core.log_quiet("Terminal find: case sensitive %s", self.case_sensitive and "on" or "off")
  core.redraw = true
end

-- After a new scan, the current match is the first match at or after the old one.
-- With no old match, it is the last match at or above the bottom of the screen.
function Find:choose_current(position)
  local matches = self.matches
  if #matches == 0 then return 0 end
  if position then
    for index, match in ipairs(matches) do
      local row = self:row(match)
      if row > position.row or row == position.row and match.col1 >= position.col then return index end
    end
    return #matches
  end
  local scrollbar = self.view.snapshot and self.view.snapshot.scrollbar
  local bottom = scrollbar and scrollbar.offset + scrollbar.len - 1 or math.huge
  for index = #matches, 1, -1 do
    if self:row(matches[index]) <= bottom then return index end
  end
  return 1
end

-- Scrolls only when the current match is outside the screen, and then centres it.
function Find:reveal_current()
  local match = self.matches[self.current]
  local view = self.view
  local scrollbar = view.snapshot and view.snapshot.scrollbar
  if not (match and scrollbar and view.session) then return end
  local row = self:row(match)
  if row >= scrollbar.offset and row < scrollbar.offset + scrollbar.len then return end
  if view.session:scroll("row", math.max(0, row - math.floor(scrollbar.len / 2))) then view:refresh_snapshot() end
end

function Find:navigate(reverse)
  local count = #self.matches
  if count == 0 then return false end
  self.current = reverse and (self.current - 2) % count + 1 or self.current % count + 1
  self:reveal_current()
  core.redraw = true
  return true
end

function Find:poll()
  local session = self.view.session
  if session ~= self.session then
    self.session = session
    self:clear()
  end
  local query = self:query()
  if not session or query == "" then
    if self.delivered then self:clear() end
    return
  end
  local matches, stale, shift = session:find(query, self.case_sensitive)
  if matches then
    local position = self:position() or self.origin
    self.matches, self.shift, self.delivered, self.marks = matches, shift or 0, true, nil
    self.current = self:choose_current(position)
    self.origin = nil
    if self.reveal then
      self.reveal = false
      self:reveal_current()
    end
    core.log_quiet("Terminal find: %d match(es)%s", #matches, matches.limited and " (limited)" or "")
    core.redraw = true
  elseif not shift then
    -- Output pruned the rows of these matches. The next scan finds them again.
    if #self.matches > 0 then
      self.origin = self:position()
      self.matches, self.current, self.marks = {}, 0, nil
      core.redraw = true
    end
  elseif shift ~= self.shift then
    self.shift = shift
    core.redraw = true
  end
  self.stale = stale
  if stale then core.redraw = true end
end

function Find:info()
  if self:query() == "" then return "" end
  if not self.delivered then return "Searching…" end
  if #self.matches == 0 then return "No results", true end
  return string.format("%d / %d%s", self.current, #self.matches, self.matches.limited and "+" or "")
end

function Find:layout()
  local view = self.view
  local font, info_font = style.font, style.view_text_font
  local margin, pad = 8 * SCALE, 6 * SCALE
  local field_h = math.floor(font:get_height() + 10 * SCALE)
  local info_w = 0
  for _, sample in ipairs(INFO_SAMPLES) do info_w = math.max(info_w, info_font:get_width(sample)) end
  local right = view.position.x + view.size.x - style.scrollbar_size - margin
  local w = math.max(1, math.min(CARD_MAX_WIDTH * SCALE, right - view.position.x - margin))
  local layout = {
    x = right - w, y = view.position.y + margin, w = w, h = pad * 2 + field_h,
    radius = 8 * SCALE, font = font, info_font = info_font,
  }
  local field_w = math.max(1, w - pad * 3 - info_w)
  layout.field = { x = layout.x + pad, y = layout.y + pad, w = field_w, h = field_h }
  layout.info = { x = layout.field.x + field_w + pad, y = layout.field.y, w = info_w, h = field_h }
  local toggle_h = field_h - 8 * SCALE
  local toggle_w = math.max(toggle_h, font:get_width("Aa") + 8 * SCALE)
  layout.toggle = {
    x = layout.field.x + field_w - 4 * SCALE - toggle_w, y = layout.field.y + 4 * SCALE, w = toggle_w, h = toggle_h,
  }
  local text_pad = 7 * SCALE
  local input = self.input
  input.position.x, input.position.y = layout.field.x + text_pad, layout.field.y
  input.size.x = math.max(1, layout.toggle.x - 2 * SCALE - input.position.x)
  input.size.y = field_h
  return layout
end

function Find:update()
  self:layout()
  self.input:update()
  self:poll()
end

local function inside(x, y, rect)
  return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h
end

function Find:contains(x, y)
  return self.visible and inside(x, y, self:layout())
end

function Find:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" or not self:contains(x, y) then return false end
  local layout = self:layout()
  self:focus()
  if inside(x, y, layout.toggle) then
    self:toggle_case()
    return true
  end
  local input = self.input
  local line, col = input:resolve_screen_position(x, y)
  if keymap.modkeys["shift"] then
    local l1, c1 = input.buffer:get_selection()
    input.buffer:set_selection(l1, c1, line, col)
  else
    input.buffer:set_selection(line, col, line, col)
  end
  if clicks == 2 then
    local line1, col1 = translate.start_of_word(input.buffer, line, col)
    local line2, col2 = translate.end_of_word(input.buffer, line1, col1)
    input.buffer:set_selection(line2, col2, line1, col1)
  elseif clicks == 3 then
    input:select_all()
  end
  return true
end

-- Calls fn(match, x, y, w, h, current) for each match on the screen.
function Find:each_visible(origin_x, origin_y, fn)
  local view = self.view
  local scrollbar = view.snapshot and view.snapshot.scrollbar
  local matches = self.matches
  if not scrollbar or #matches == 0 then return end
  local top, bottom = scrollbar.offset, scrollbar.offset + view.rows
  local lo, hi = 1, #matches + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if self:row(matches[mid]) < top then lo = mid + 1 else hi = mid end
  end
  for index = lo, #matches do
    local match = matches[index]
    local row = self:row(match)
    if row >= bottom then break end
    fn(origin_x + match.col1 * view.cell_width, origin_y + (row - top) * view.cell_height,
      (match.col2 - match.col1) * view.cell_width, view.cell_height, index == self.current)
  end
end

function Find:draw_matches(origin_x, origin_y)
  if not self.visible then return end
  self:each_visible(origin_x, origin_y, function(x, y, w, h, current)
    renderer.draw_rect(x, y, w, h, current and style.search_selection or style.search_selection_secondary)
  end)
end

function Find:draw_current_outline(origin_x, origin_y)
  local outline = style.search_selection_outline
  if not self.visible or not outline then return end
  local t = math.max(1, common.round(SCALE))
  self:each_visible(origin_x, origin_y, function(x, y, w, h, current)
    if not current then return end
    renderer.draw_rect(x, y, w, t, outline)
    renderer.draw_rect(x, y + h - t, w, t, outline)
    renderer.draw_rect(x, y, t, h, outline)
    renderer.draw_rect(x + w - t, y, t, h, outline)
  end)
end

-- Marks each match on the scrollbar track, as a text file does.
function Find:draw_marks()
  local view = self.view
  local scrollbar = view.snapshot and view.snapshot.scrollbar
  if not self.visible or not scrollbar or #self.matches == 0 then return end
  local x, y, w, h = view.v_scrollbar:get_track_rect()
  if w <= 0 or h <= 0 then return end
  local key = table.concat({ self.shift, scrollbar.total, x, y, w, h }, ":")
  local marks = self.marks
  if not marks or marks.key ~= key then
    marks = { key = key }
    local total, last_y = math.max(1, scrollbar.total), nil
    for _, match in ipairs(self.matches) do
      local row = self:row(match)
      local _, mark_y, _, mark_h = view.v_scrollbar:get_overview_marker_rect(row / total, (row + 1) / total)
      mark_y = mark_y and math.floor(mark_y)
      if mark_y and mark_y ~= last_y then
        marks[#marks + 1] = { mark_y, math.max(1, math.floor(mark_h)) }
        last_y = mark_y
      end
    end
    self.marks = marks
  end
  for _, mark in ipairs(marks) do renderer.draw_rect(x, mark[1], w, mark[2], style.search_overview_secondary) end
  local current = self.matches[self.current]
  if current then
    local total, row = math.max(1, scrollbar.total), self:row(current)
    local mark_x, mark_y, mark_w, mark_h = view.v_scrollbar:get_overview_marker_rect(row / total, (row + 1) / total)
    if mark_x then renderer.draw_rect(mark_x, mark_y, mark_w, mark_h, style.search_overview) end
  end
  view.v_scrollbar:draw_thumb()
end

function Find:draw_card()
  if not self.visible then return end
  local view = self.view
  local layout = self:layout()
  core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
  card.draw(layout.x, layout.y, layout.w, layout.h, layout.radius)
  local field, input = layout.field, self.input
  local radius = 6 * SCALE
  if self:focused() then
    local ring = math.max(1, math.floor(SCALE + 0.5))
    renderer.draw_rounded_rect(field.x, field.y, field.w, field.h, radius, style.accent)
    renderer.draw_rounded_rect(field.x + ring, field.y + ring, field.w - 2 * ring, field.h - 2 * ring,
      radius - ring, style.card)
  end
  renderer.draw_rounded_rect(field.x, field.y, field.w, field.h, radius, style.card_field)
  core.push_clip_rect(input.position.x, input.position.y, input.size.x, input.size.y)
  input:draw()
  if self:query() == "" then
    local text_x = input:get_line_screen_position(1, 1)
    common.draw_text(input:get_font(), style.dim, "Find", "left", text_x, input.position.y, input.size.x,
      input.size.y)
  end
  core.pop_clip_rect()
  local toggle = layout.toggle
  if self.case_sensitive then
    local accent = style.accent
    renderer.draw_rounded_rect(toggle.x, toggle.y, toggle.w, toggle.h, 4 * SCALE, { accent[1], accent[2], accent[3], 64 })
  end
  common.draw_text(layout.font, self.case_sensitive and style.accent or style.dim, "Aa", "center",
    toggle.x, toggle.y, toggle.w, toggle.h)
  local info, failed = self:info()
  if info ~= "" then
    local rect = layout.info
    core.push_clip_rect(rect.x, rect.y, rect.w, rect.h)
    common.draw_text(layout.info_font, failed and style.error or style.card_text, info, "left",
      rect.x, rect.y, rect.w, rect.h)
    core.pop_clip_rect()
  end
  core.pop_clip_rect()
end

return Find
