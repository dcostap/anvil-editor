-- Margin notes: CriticMarkup notes shown as cards beside Markdown Live Preview.
--
-- `{==anchor==}{>>note<<}` attaches a note to its anchor text and `{>>note<<}`
-- marks a point. The native extension scanner finds both. This module lays
-- out one card per note in the right margin, beside its anchor line, and
-- edits the note body in an inline editor inside the card.
local core = require "core"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local file_context = require "core.file_context"
local markdown_model = require "core.markdown.model"
local panes = require "core.panes"

local margin_notes = {}

local CARD_WIDTH = 210
local MIN_CARD_WIDTH = 140
local LANE_GAP = 14
local EDGE_GAP = 12
local CARD_SPACING = 8
local CARD_RADIUS = 6
-- Notes anchored just above the viewport still push visible cards down.
local LOOKBEHIND_LINES = 80
local PLACEHOLDER = "Write a note..."

-- Set by Live Preview: the semantic nodes published for one line, and
-- whether a view presents formatted Markdown rather than its source.
margin_notes.nodes_for_line = nil
margin_notes.presents_formatting = nil

-- Note input --------------------------------------------------------------

local NoteBuffer = Buffer:extend()

function NoteBuffer:__tostring() return "MarginNoteBuffer" end

-- A note body stays on its anchor's source line.
function NoteBuffer:normalize_edit_text(text)
  return (tostring(text or ""):gsub("\r?\n", " "))
end

function NoteBuffer:insert(line, col, text)
  NoteBuffer.super.insert(self, line, col, self:normalize_edit_text(text))
end

local NoteInput = TextView:extend()

function NoteInput:__tostring() return "MarginNoteInput" end

function NoteInput:new(owner)
  NoteInput.super.new(self, NoteBuffer())
  self.margin_note_input = true
  self.margin_note_owner = owner
  self.font = "markdown_body_font"
  self.scrollable = false
  self.hide_scrollbars = true
  self.show_current_line_highlight = false
  self.wrap_continuation_flush = true
  self:set_wrapping_enabled(true)
end

function NoteInput:get_text()
  return self.buffer:get_text(1, 1, math.huge, math.huge)
end

function NoteInput:set_text(text)
  self.buffer:remove(1, 1, math.huge, math.huge)
  self.buffer:insert(1, 1, text or "")
  self.buffer:clear_undo_redo()
  self.buffer:set_selection(1, math.huge, 1, math.huge)
end

function NoteInput:get_gutter_width() return 0, 0 end
function NoteInput:draw_line_gutter() return self:get_line_height() end
function NoteInput:draw_line_highlight() end
function NoteInput:draw_scrollbar() end
function NoteInput:draw_background() end
function NoteInput:draw_content_left_edge() end
function NoteInput:draw_soft_wrap_continuation_indicators() end

-- Cards show and edit a note in the same wrapped shape.
function NoteInput:compute_wrap_width()
  return math.max(1, self.size.x)
end

---Place the text inside a card and wrap it to the card's text width.
function NoteInput:fit_card(x, y, width)
  self.position.x, self.position.y = x, y
  if self.size.x ~= width then self.size.x = width end
  self:update_wrap_cache()
  self.size.y = self:content_height()
  self.scroll.x, self.scroll.y, self.scroll.to.x, self.scroll.to.y = 0, 0, 0, 0
  return self.size.y
end

function NoteInput:content_height()
  local rows = math.max(1, self:get_total_visual_lines())
  return rows * self:get_line_height() + style.padding.y * 2
end

-- Notes -------------------------------------------------------------------

local function scaled(value) return math.floor(value * SCALE + 0.5) end

local function line_text(buffer, line)
  return (buffer.lines[line] or ""):gsub("\n$", "")
end

local function note_from_node(buffer, node)
  local attributes = node.attributes or {}
  local body_open = attributes.margin_note_body_open
  local body_close = attributes.margin_note_body_close
  if not (body_open and body_close) then return nil end
  local line = node.source.line1
  local anchor = attributes.margin_note_anchor
  return {
    id = node.id,
    line = line,
    col1 = node.source.col1,
    col2 = node.source.col2,
    anchor_col1 = anchor and anchor.col1 or nil,
    anchor_col2 = anchor and anchor.col2 or nil,
    body_col1 = body_open.col2,
    body_col2 = body_close.col1,
    text = line_text(buffer, line):sub(body_open.col2, body_close.col1 - 1),
  }
end

local function document_has_notes(view)
  local instance = markdown_model.peek(view.buffer)
  return instance and instance.published_revision ~= nil and instance:margin_note_count() > 0
end

---Margin notes whose anchors start on lines `line1` to `line2`.
function margin_notes.notes_for_lines(view, line1, line2)
  local notes = {}
  local nodes_for_line = margin_notes.nodes_for_line
  if not nodes_for_line then return notes end
  for line = math.max(1, line1), math.min(line2, #view.buffer.lines) do
    for _, node in ipairs(nodes_for_line(view, line) or {}) do
      if node.type == "margin_note" and node.source.line1 == line then
        local note = note_from_node(view.buffer, node)
        if note then notes[#notes + 1] = note end
      end
    end
  end
  return notes
end

---The margin note whose source contains the primary caret.
function margin_notes.note_at_caret(view)
  local line, col = view.buffer:get_selection()
  for _, note in ipairs(margin_notes.notes_for_lines(view, line, line)) do
    if col >= note.col1 and col <= note.col2 then return note end
  end
end

local function same_note(a, b)
  return a and b and a.line == b.line and a.col1 == b.col1
end

-- Body text is raw CriticMarkup. It cannot hold a line break or the closing
-- delimiter, so both become harmless near-equivalents.
local function sanitize(text)
  text = tostring(text or ""):gsub("[\r\n]+", " "):gsub("<<}", "<< }")
  return text:match("^%s*(.-)%s*$")
end

local function note_source_is_current(buffer, note)
  local text = line_text(buffer, note.line)
  return text:sub(note.body_col1 - 3, note.body_col1 - 1) == "{>>"
    and text:sub(note.body_col2, note.body_col2 + 2) == "<<}"
end

---Replace a note's body. An empty body removes the note and keeps its anchor.
function margin_notes.set_text(view, note, text)
  local buffer = view.buffer
  if not note_source_is_current(buffer, note) then
    core.log_quiet("Margin note at %s:%d moved before its edit was saved", buffer:get_name(), note.line)
    return false
  end
  text = sanitize(text)
  if text == "" then return margin_notes.remove(view, note) end
  if text == line_text(buffer, note.line):sub(note.body_col1, note.body_col2 - 1) then return true end
  buffer:apply_edits({
    { line1 = note.line, col1 = note.body_col1, line2 = note.line, col2 = note.body_col2, text = text },
  }, { type = "markdown-margin-note", reason = "edit" })
  core.log_quiet("Margin note edited at %s:%d (%d bytes)", buffer:get_name(), note.line, #text)
  return true
end

---Remove a note's CriticMarkup and keep its anchor text.
function margin_notes.remove(view, note)
  local buffer = view.buffer
  local text = line_text(buffer, note.line)
  local anchor = note.anchor_col1 and text:sub(note.anchor_col1, note.anchor_col2 - 1) or ""
  buffer:apply_edits({
    { line1 = note.line, col1 = note.col1, line2 = note.line, col2 = note.col2, text = anchor },
  }, { type = "markdown-margin-note", reason = "remove" })
  core.log_quiet("Margin note removed at %s:%d", buffer:get_name(), note.line)
  return true
end

-- Editing -----------------------------------------------------------------

local function edit_state(view) return view.__margin_note_edit end

local function end_edit(view, save)
  local edit = edit_state(view)
  if not edit or edit.ending then return false end
  edit.ending = true
  local text = edit.input:get_text()
  view.__margin_note_edit = nil
  panes.unregister_focus_target(edit.input)
  if core.active_view == edit.input then core.set_active_view(view) end
  if save then
    margin_notes.set_text(view, edit.note, text)
  elseif edit.created and note_source_is_current(view.buffer, edit.note) then
    -- Cancelling a note that was just added leaves no empty note behind.
    margin_notes.remove(view, edit.note)
  end
  core.redraw = true
  return true
end

---Open the inline editor on a note's card.
function margin_notes.begin_edit(view, note, opts)
  opts = opts or {}
  local current = edit_state(view)
  if current and same_note(current.note, note) then
    core.set_active_view(current.input)
    return current.input
  end
  if current then end_edit(view, true) end
  local input = NoteInput(view)
  file_context.exclude_content_view(input)
  input:set_text(note.text)
  view.__margin_note_edit = { note = note, input = input, created = opts.created }
  panes.register_focus_target(view, input)
  core.set_active_view(input)
  core.blink_reset()
  core.redraw = true
  core.log_quiet("Margin note editing at %s:%d", view.buffer:get_name(), note.line)
  return input
end

function margin_notes.commit_edit(view) return end_edit(view, true) end
function margin_notes.cancel_edit(view) return end_edit(view, false) end
function margin_notes.editing_input(view)
  local edit = edit_state(view)
  return edit and edit.input or nil
end

local function word_bounds(text, col)
  local col1, col2 = col, col
  while col1 > 1 and text:sub(col1 - 1, col1 - 1):match("[%w_\128-\255'-]") do col1 = col1 - 1 end
  while col2 <= #text and text:sub(col2, col2):match("[%w_\128-\255'-]") do col2 = col2 + 1 end
  return col1, col2
end

---Add a note on the selection, the word at the caret, or the caret point,
---then open its editor. A caret inside a note edits that note instead.
function margin_notes.add(view)
  local existing = margin_notes.note_at_caret(view)
  if existing then return margin_notes.begin_edit(view, existing) end
  local buffer = view.buffer
  local line, col1, line2, col2 = buffer:get_selection(true)
  local text = line_text(buffer, line)
  if line2 ~= line then col2 = #text + 1 end
  if col1 == col2 then col1, col2 = word_bounds(text, col1) end
  local anchor = text:sub(col1, col2 - 1)
  local anchor_text = anchor:match("^%s*(.-)%s*$")
  if anchor_text ~= "" then
    local leading = #anchor:match("^%s*")
    col1 = col1 + leading
    col2 = col1 + #anchor_text
    anchor = anchor_text
  else
    col2, anchor = col1, ""
  end
  local source = anchor ~= "" and ("{==" .. anchor .. "==}{>><<}") or "{>><<}"
  buffer:apply_edits({
    { line1 = line, col1 = col1, line2 = line, col2 = col2, text = source },
  }, { type = "markdown-margin-note", reason = "add" })
  local body_col1 = col1 + #source - 3
  local note = {
    line = line, col1 = col1, col2 = col1 + #source,
    anchor_col1 = anchor ~= "" and col1 + 3 or nil,
    anchor_col2 = anchor ~= "" and col1 + 3 + #anchor or nil,
    body_col1 = body_col1, body_col2 = body_col1, text = "",
  }
  buffer:set_selection(line, note.col2, line, note.col2)
  core.log_quiet("Margin note added at %s:%d (%s)", buffer:get_name(), line,
    anchor ~= "" and "anchored" or "point")
  return margin_notes.begin_edit(view, note, { created = true })
end

-- Layout ------------------------------------------------------------------

---The margin column beside the reading lane, or nil without enough room.
function margin_notes.column_rect(view)
  local centered = core.centered_editor
  if not (centered and centered.should_center(view)) then return nil end
  local lane_x, lane_width = centered.get_lane_rect(view)
  local x = lane_x + lane_width + scaled(LANE_GAP)
  local right = view.position.x + view.size.x - scaled(EDGE_GAP)
  local width = math.min(scaled(CARD_WIDTH), right - x)
  if width < scaled(MIN_CARD_WIDTH) then return nil end
  return x, width
end

local function reserve_width()
  return scaled(CARD_WIDTH + LANE_GAP + EDGE_GAP)
end

---Cards for the notes near the viewport, stacked so none overlap.
function margin_notes.layout(view)
  if not document_has_notes(view) and not edit_state(view) then return nil end
  if not margin_notes.presents_formatting(view) then return nil end
  local column_x, column_width = margin_notes.column_rect(view)
  if not column_x then return nil end
  local pad_x = style.padding.x
  local text_width = column_width - pad_x * 2
  local minline, maxline = view:get_visible_line_range()
  local notes = margin_notes.notes_for_lines(view, minline - LOOKBEHIND_LINES, maxline)
  local edit = edit_state(view)
  if edit then
    local found = false
    for i, note in ipairs(notes) do
      if same_note(note, edit.note) then notes[i], found = edit.note, true end
    end
    if not found and edit.note.line >= minline - LOOKBEHIND_LINES and edit.note.line <= maxline then
      notes[#notes + 1] = edit.note
    end
  end
  local caret_note = margin_notes.note_at_caret(view)
  -- Notes with the same text share one display view.
  local displays, used = view.__margin_note_displays or {}, {}
  local cards, bottom = {}, -math.huge
  for _, note in ipairs(notes) do
    local anchor_col = note.anchor_col1 or note.col1
    local _, anchor_y = view:get_line_screen_position(note.line, anchor_col)
    local editing = edit and same_note(note, edit.note)
    local text_view
    if editing then
      text_view = edit.input
    else
      text_view = displays[note.text]
      if not text_view then
        text_view = NoteInput(view)
        text_view:set_text(note.text)
      end
      used[note.text] = text_view
    end
    local y = math.max(anchor_y, bottom + scaled(CARD_SPACING))
    local height = text_view:fit_card(column_x + pad_x, y, text_width)
    local text_x, text_y = text_view:get_line_screen_position(1, 1)
    cards[#cards + 1] = {
      note = note, x = column_x, y = y, w = column_width, h = height,
      text_view = text_view, text_x = text_x, text_y = text_y,
      anchor_y = anchor_y, editing = editing,
      current = same_note(note, caret_note),
    }
    bottom = y + height
  end
  view.__margin_note_displays = used
  return { cards = cards }
end

-- Drawing -----------------------------------------------------------------

local function draw_dashed_hline(x1, x2, y, color)
  local dash, gap = scaled(4), scaled(3)
  local x = x1
  while x < x2 do
    renderer.draw_rect(x, y, math.min(dash, x2 - x), math.max(1, scaled(1)), color)
    x = x + dash + gap
  end
end

local function draw_card(view, card, hovered)
  local emphasized = card.editing or card.current or hovered
  local border = emphasized and style.markdown_margin_note_card_active_border
    or style.markdown_margin_note_card_border
  local radius = scaled(CARD_RADIUS)
  if emphasized then
    local note = card.note
    local end_col = note.anchor_col2 or note.col1
    local anchor_x = view:get_line_screen_position(note.line, end_col)
    local y = card.anchor_y + math.floor(view:get_line_height() / 2)
    draw_dashed_hline(anchor_x + scaled(4), card.x, y, style.markdown_margin_note_connector)
  end
  renderer.draw_rounded_rect(card.x - 1, card.y - 1, card.w + 2, card.h + 2, radius + 1, border)
  renderer.draw_rounded_rect(card.x, card.y, card.w, card.h, radius, style.markdown_margin_note_card_bg)
  local text_view = card.text_view
  -- The card's layout already placed and wrapped its text view.
  text_view.position.x, text_view.position.y = card.x + style.padding.x, card.y
  if text_view:get_text() == "" then
    renderer.draw_text(text_view:get_font(), PLACEHOLDER, card.text_x, card.text_y,
      style.markdown_margin_note_placeholder)
  end
  text_view:draw()
  if card.editing then text_view:draw_overlay() end
end

function margin_notes.draw(view)
  local layout = margin_notes.layout(view)
  view.__margin_note_layout = layout
  if not layout then return end
  core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
  for _, card in ipairs(layout.cards) do
    if card.y + card.h >= view.position.y and card.y <= view.position.y + view.size.y then
      draw_card(view, card, same_note(card.note, view.__margin_note_hover))
    end
  end
  core.pop_clip_rect()
end

-- Events ------------------------------------------------------------------

local function card_at(view, x, y)
  local layout = view.__margin_note_layout
  for _, card in ipairs(layout and layout.cards or {}) do
    if x >= card.x and x < card.x + card.w and y >= card.y and y < card.y + card.h then
      return card
    end
  end
end

local function on_mouse_moved(view, x, y, ...)
  local edit = edit_state(view)
  local card = card_at(view, x, y)
  local hovered = card and card.note or nil
  if not same_note(hovered, view.__margin_note_hover) then
    view.__margin_note_hover = hovered
    core.redraw = true
  end
  if card then
    if edit and card.editing then
      edit.input:on_mouse_moved(x, y, ...)
      view.cursor = "ibeam"
    else
      view.cursor = "hand"
    end
    return true
  end
  if edit and edit.input.mouse_selecting then
    return edit.input:on_mouse_moved(x, y, ...)
  end
end

local function on_mouse_pressed(view, button, x, y, clicks)
  local card = card_at(view, x, y)
  local edit = edit_state(view)
  if card and card.editing and edit then
    core.set_active_view(edit.input)
    edit.input:on_mouse_pressed(button, x, y, clicks)
    return true
  end
  if card and button == "left" then
    margin_notes.begin_edit(view, card.note)
    return true
  end
  if edit then end_edit(view, true) end
end

local function on_mouse_released(view, ...)
  local edit = edit_state(view)
  if edit and edit.input.mouse_selecting then
    edit.input:on_mouse_released(...)
    return true
  end
end

local function update(view)
  local edit = edit_state(view)
  if edit then
    if core.active_view ~= edit.input and not core.next_active_view then
      -- Focus left the note editor, such as a click in another Pane.
      end_edit(view, true)
    else
      edit.input:update()
    end
  end
  local centered = core.centered_editor
  if centered then
    local reserve = document_has_notes(view) and margin_notes.presents_formatting(view)
      and reserve_width() or 0
    centered.set_right_reserve(view, reserve)
  end
end

local function call_class(view, name, ...)
  return getmetatable(view)[name](view, ...)
end

---Install the margin layer on a Live Preview Text View.
function margin_notes.attach(view)
  if view.__margin_notes_attached then return false end
  view.__margin_notes_attached = true
  view.draw = function(self, ...)
    local result = call_class(self, "draw", ...)
    margin_notes.draw(self)
    return result
  end
  view.update = function(self, ...)
    update(self)
    return call_class(self, "update", ...)
  end
  view.on_mouse_moved = function(self, x, y, ...)
    if on_mouse_moved(self, x, y, ...) then return true end
    return call_class(self, "on_mouse_moved", x, y, ...)
  end
  view.on_mouse_pressed = function(self, button, x, y, clicks)
    if on_mouse_pressed(self, button, x, y, clicks) then return true end
    return call_class(self, "on_mouse_pressed", button, x, y, clicks)
  end
  view.on_mouse_released = function(self, ...)
    if on_mouse_released(self, ...) then return true end
    return call_class(self, "on_mouse_released", ...)
  end
  return true
end

function margin_notes.detach(view)
  if not view.__margin_notes_attached then return false end
  end_edit(view, true)
  view.__margin_notes_attached = nil
  view.draw, view.update = nil, nil
  view.on_mouse_moved, view.on_mouse_pressed, view.on_mouse_released = nil, nil, nil
  view.__margin_note_layout, view.__margin_note_hover = nil, nil
  view.__margin_note_displays = nil
  local centered = core.centered_editor
  if centered then centered.set_right_reserve(view, 0) end
  return true
end

---The Live Preview view that owns the focused note editor.
function margin_notes.input_owner(view)
  return view and view.margin_note_input and view.margin_note_owner or nil
end

return margin_notes
