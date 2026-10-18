-- Margin notes: CriticMarkup notes shown as cards in Markdown Live Preview.
--
-- `{==anchor==}{>>note<<}` attaches a note to its anchor text and `{>>note<<}`
-- marks a point. The native extension scanner finds both. A card sits in the
-- free space right of the text column, beside its anchor line. When that
-- space is too narrow, cards show inline below the anchor's block. Notes
-- never change the text column's width. Each card edits its note in place.
local core = require "core"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local file_context = require "core.file_context"
local markdown_model = require "core.markdown.model"
local markdown_parser = require "core.markdown.parser"
local panes = require "core.panes"

local margin_notes = {}

local NOTE_FONT_SCALE = 0.875
local CARD_RADIUS = 5
-- Margin cards point left at their anchor line.
local CARD_WIDTH = 200
local MIN_CARD_WIDTH = 160
local MARGIN_GAP = 30
local EDGE_GAP = 12
local CARD_SPACING = 8
local MARGIN_PAD_X, MARGIN_PAD_Y = 9, 7
local MARGIN_POINTER_LENGTH, MARGIN_POINTER_HALF = 8, 7
-- Inline cards point up at the block above them.
local INLINE_PAD_X, INLINE_PAD_Y = 8, 5
local INLINE_POINTER_LENGTH, INLINE_POINTER_HALF = 14, 10
local INLINE_POINTER_X = 40
local INLINE_TOP = INLINE_POINTER_LENGTH + 3
local INLINE_BOTTOM = 4
local MAX_BLOCK_LINES = 200
local MAX_DISPLAYS = 64
local ROW_PROVIDER = "markdown.margin-notes"
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

-- Note text: inline Markdown ----------------------------------------------
--
-- A note shows inline Markdown as Live Preview does: styled text without its
-- syntax. While a note is edited, the syntax of the span at the caret shows.

local NOTE_FORMAT_PROVIDER = "markdown.margin-note-format"
local SPAN_FONTS = {
  strong = "prose_strong_font",
  emphasis = "prose_emphasis_font",
  strong_emphasis = "prose_strong_emphasis_font",
  code = "code_font",
}
local styled_fonts = setmetatable({}, { __mode = "k" })

-- An inline style's font at the note font's size.
local function styled_font(base, span_type)
  local source = style[SPAN_FONTS[span_type]]
  local fonts = styled_fonts[base]
  if not fonts then
    fonts = setmetatable({}, { __mode = "k" })
    styled_fonts[base] = fonts
  end
  local font = fonts[source]
  if not font then
    local size = base:get_size()
    -- Code keeps the size it has beside prose in the document.
    if span_type == "code" then
      size = size * source:get_size() / style.markdown_body_font:get_size()
    end
    font = source:copy(size)
    fonts[source] = font
  end
  return font
end

local function reveal_col(view)
  if core.active_view ~= view then return nil end
  local _, col = view.buffer:get_selection()
  return col
end

-- The shown text of a link span: its label, or a wiki link's alias or target.
local function link_text_cols(source, span)
  local range = span.link.link_text_range
  if range then return range.col1, range.col2 end
  local open = span.link.is_embed and 3 or 2
  local inner = source:sub(span.col1 + open, span.col2 - 3)
  local pipe = inner:find("|", 1, true)
  return span.col1 + open + (pipe or 0), span.col2 - 2
end

local function note_render(view, source)
  local base = view:get_font()
  local caret = reveal_col(view)
  local bounds = { [1] = true, [#source + 1] = true }
  local hidden, styled = {}, {}
  local function mark(col1, col2, kind, revealed)
    if col2 <= col1 then return end
    bounds[col1], bounds[col2] = true, true
    if kind == "syntax" and not revealed then
      hidden[#hidden + 1] = { col1, col2 }
    else
      styled[#styled + 1] = { col1, col2, kind }
    end
  end
  for _, span in ipairs(markdown_parser.parse_inline(source)) do
    local revealed = caret ~= nil and caret >= span.col1 and caret <= span.col2
    if span.link then
      local col1, col2 = link_text_cols(source, span)
      mark(span.col1, col1, "syntax", revealed)
      mark(col1, col2, "link")
      mark(col2, span.col2, "syntax", revealed)
    else
      for _, marker in ipairs(span.marker_ranges) do
        mark(marker.col1, marker.col2, "syntax", revealed)
      end
      local content = span.content_ranges[1]
      mark(content.col1, content.col2, span.type)
    end
  end
  local cols = {}
  for col in pairs(bounds) do cols[#cols + 1] = col end
  table.sort(cols)
  local fragments = {}
  for i = 1, #cols - 1 do
    local col1, col2 = cols[i], cols[i + 1]
    local is_hidden = false
    for _, range in ipairs(hidden) do
      if range[1] <= col1 and range[2] >= col2 then is_hidden = true break end
    end
    if is_hidden then
      fragments[#fragments + 1] = { source_col1 = col1, source_col2 = col2, hidden = true }
    else
      local kinds = {}
      for _, range in ipairs(styled) do
        if range[1] <= col1 and range[2] >= col2 then kinds[range[3]] = true end
      end
      local bold = kinds.strong or kinds.strong_emphasis
      local italic = kinds.emphasis or kinds.strong_emphasis
      local font = kinds.code and styled_font(base, "code")
        or bold and italic and styled_font(base, "strong_emphasis")
        or bold and styled_font(base, "strong")
        or italic and styled_font(base, "emphasis")
        or base
      fragments[#fragments + 1] = {
        source_col1 = col1, source_col2 = col2,
        text = source:sub(col1, col2 - 1),
        font = font,
        color = kinds.syntax and style.markdown_live_hidden_syntax
          or kinds.link and style.markdown_live_link or style.text,
        background = kinds.code and style.markdown_live_inline_code_bg
          or kinds.highlight and style.markdown_live_highlight_bg or nil,
        underline = kinds.link or nil,
        strikethrough = kinds.strikethrough or nil,
      }
    end
  end
  return { fragments = fragments }
end

local note_format_provider = {
  line_generation = function(_, view)
    return tostring(view:get_font()) .. ":" .. tostring(reveal_col(view) or 0)
  end,
  render_line = function(_, view, _, context)
    return note_render(view, context.source_text)
  end,
}

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
  self:add_line_render_provider(NOTE_FORMAT_PROVIDER, note_format_provider)
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

-- Notes read a step smaller than the prose they annotate.
local note_fonts = setmetatable({}, { __mode = "k" })

function NoteInput:get_font()
  local base = style.markdown_body_font
  local font = note_fonts[base]
  if not font then
    font = base:copy(base:get_size() * NOTE_FONT_SCALE)
    note_fonts[base] = font
  end
  return font
end

-- Cards show and edit a note in the same wrapped shape.
function NoteInput:compute_wrap_width()
  return math.max(1, self.size.x)
end

---Wrap the text to `width` and return its height. The view stays in place.
function NoteInput:measure(width)
  if self.size.x ~= width then self.size.x = width end
  self:update_wrap_cache()
  return math.max(1, self:get_total_visual_lines()) * self:get_line_height()
end

---Place the text with its first row at (`x`, `top`), wrapped to `width`.
function NoteInput:fit_card(x, top, width)
  local height = self:measure(width)
  -- The text view draws its first row one padding below its top.
  self.position.x, self.position.y = x, top - style.padding.y
  self.size.y = height + style.padding.y * 2
  self.scroll.x, self.scroll.y, self.scroll.to.x, self.scroll.to.y = 0, 0, 0, 0
  return height
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
  local lines = view.buffer.lines
  for line = math.max(1, line1), math.min(line2, #lines) do
    -- Every note body opens on its own line, so most lines skip the parse.
    if lines[line]:find("{>>", 1, true) then
      for _, node in ipairs(nodes_for_line(view, line) or {}) do
        if node.type == "margin_note" and node.source.line1 == line then
          local note = note_from_node(view.buffer, node)
          if note then notes[#notes + 1] = note end
        end
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

-- The scanner finds no notes in these nodes, so a note added there never renders.
local NOTELESS_NODES = {
  code = true, code_fenced = true, code_indented = true, comment = true,
  frontmatter = true, html = true, math = true,
}

local function before(line1, col1, line2, col2)
  return line1 < line2 or (line1 == line2 and col1 < col2)
end

-- The noteless node that a note source at `col1`..`col2` on `line` would enter.
local function noteless_node_at(view, line, col1, col2)
  local nodes_for_line = margin_notes.nodes_for_line
  for _, node in ipairs(nodes_for_line and nodes_for_line(view, line) or {}) do
    local source = node.source
    if NOTELESS_NODES[node.type]
      and before(source.line1, source.col1, line, col2)
      and before(line, col1, source.line2 or source.line1, source.col2)
    then
      return node
    end
  end
end

---Add a note on the selection, the word at the caret, or the caret point,
---then open its editor. A caret inside a note edits that note instead.
---Code and other places that show no notes take no new note.
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
  local noteless = noteless_node_at(view, line, col1, col2)
  if noteless then
    core.log_quiet("Margin note refused at %s:%d inside %s", buffer:get_name(), line, noteless.type)
    core.status_bar:show_message("i", style.text, "Margin notes cannot go inside code")
    return nil
  end
  local source =anchor ~= "" and ("{==" .. anchor .. "==}{>><<}") or "{>><<}"
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

-- Cards stay clear of the view's scrollbar at its widest.
local function scrollbar_width(view)
  return view.v_scrollbar and view.v_scrollbar.expanded_size or style.expanded_scrollbar_size
end

-- The wrapped text column of the reading lane. Notes never change it.
local function text_column(view)
  local centered = core.centered_editor
  local lane_x, lane_width = view.position.x, view.size.x
  if centered and centered.should_center(view) then
    lane_x, lane_width = centered.get_lane_rect(view)
  end
  local gutter = view:get_gutter_width()
  local wrap = view.wrapped_settings and view.wrapped_settings.width
  local width = (wrap and wrap ~= math.huge) and wrap or (lane_width - gutter - scrollbar_width(view))
  return lane_x + gutter, math.max(0, width)
end

---The margin column in the free space right of the text column, or nil
---when that space cannot hold a card. Notes then show inline.
function margin_notes.column_rect(view)
  local text_x, text_width = text_column(view)
  local x = text_x + text_width + scaled(MARGIN_GAP)
  local right = view.position.x + view.size.x - scrollbar_width(view) - scaled(EDGE_GAP)
  local width = math.min(scaled(CARD_WIDTH), right - x)
  if width < scaled(MIN_CARD_WIDTH) then return nil end
  return x, width
end

-- Notes with the same text share one display view.
local function display_for(view, text)
  local displays = view.__margin_note_displays
  if not displays or displays.count > MAX_DISPLAYS then
    displays = { count = 0, views = {} }
    view.__margin_note_displays = displays
  end
  local display = displays.views[text]
  if not display then
    display = NoteInput(view)
    display:set_text(text)
    displays.views[text] = display
    displays.count = displays.count + 1
  end
  return display
end

local function text_view_for(view, note)
  local edit = edit_state(view)
  if edit and same_note(note, edit.note) then return edit.input, true end
  return display_for(view, note.text), false
end

-- Wrap a note's text inside a card at (`x`, `y`); returns the card height.
local function place_text(text_view, x, y, width, pad_x, pad_y)
  return text_view:fit_card(x + scaled(pad_x), y + scaled(pad_y), width - scaled(pad_x) * 2)
    + scaled(pad_y) * 2
end

local function new_card(view, note, x, y, width, height, pointer, caret_note)
  local text_view, editing = text_view_for(view, note)
  local text_x, text_y = text_view:get_line_screen_position(1, 1)
  return {
    note = note, x = x, y = y, w = width, h = height, pointer = pointer,
    text_view = text_view, text_left = text_view.position.x, text_top = text_view.position.y,
    text_x = text_x, text_y = text_y, editing = editing,
    current = same_note(note, caret_note),
  }
end

local function notes_with_edit(view, notes, line1, line2)
  local edit = edit_state(view)
  if not edit then return notes end
  local found = false
  for i, note in ipairs(notes) do
    if same_note(note, edit.note) then notes[i], found = edit.note, true end
  end
  -- A note added a moment ago can precede the model's next parse.
  if not found and edit.note.line >= line1 and edit.note.line <= line2 then
    notes[#notes + 1] = edit.note
  end
  return notes
end

-- Margin cards are centered on their anchor line and stacked so none overlap.
local function margin_layout(view, column_x, column_width, caret_note)
  local minline, maxline = view:get_visible_line_range()
  local line1 = minline - LOOKBEHIND_LINES
  local notes = notes_with_edit(view, margin_notes.notes_for_lines(view, line1, maxline), line1, maxline)
  local cards, bottom = {}, -math.huge
  local half_line = math.floor(view:get_line_height() / 2)
  for _, note in ipairs(notes) do
    local _, anchor_y = view:get_line_screen_position(note.line, note.anchor_col1 or note.col1)
    local text_view = text_view_for(view, note)
    local height = place_text(text_view, column_x, 0, column_width, MARGIN_PAD_X, MARGIN_PAD_Y)
    local anchor_mid = anchor_y + half_line
    local y = math.max(anchor_mid - math.floor(height / 2), bottom + scaled(CARD_SPACING))
    place_text(text_view, column_x, y, column_width, MARGIN_PAD_X, MARGIN_PAD_Y)
    local card = new_card(view, note, column_x, y, column_width, height, "left", caret_note)
    card.anchor_y, card.anchor_mid = anchor_y, anchor_mid
    cards[#cards + 1] = card
    bottom = y + height
  end
  return cards
end

-- Inline cards fill the rows that the row provider adds below each block.
local function inline_layout(view, caret_note)
  local cards = {}
  local x, width = text_column(view)
  local edit = edit_state(view)
  for entry in view:iter_visible_visual_rows() do
    local row = entry.provider_row
    if row and row.margin_note then
      local note = edit and same_note(row.margin_note, edit.note) and edit.note or row.margin_note
      local y = entry.y + scaled(INLINE_TOP)
      local height = place_text(text_view_for(view, note), x, y, width, INLINE_PAD_X, INLINE_PAD_Y)
      cards[#cards + 1] = new_card(view, note, x, y, width, height, "up", caret_note)
    end
  end
  return cards
end

-- Inline rows -------------------------------------------------------------

local function is_blank(text) return not text:find("%S") end
local function is_heading(text) return text:find("^%s*#") ~= nil end

-- A block is a run of non-blank lines. A heading is a block of its own.
local function is_block_end(buffer, line)
  local text = line_text(buffer, line)
  if is_blank(text) then return false end
  if line >= #buffer.lines or is_heading(text) then return true end
  local next_text = line_text(buffer, line + 1)
  return is_blank(next_text) or is_heading(next_text)
end

local function block_start(buffer, line)
  if is_heading(line_text(buffer, line)) then return line end
  local first = line
  while first > 1 and line - first < MAX_BLOCK_LINES do
    local text = line_text(buffer, first - 1)
    if is_blank(text) or is_heading(text) then break end
    first = first - 1
  end
  return first
end

local function inline_rows(view, line)
  local buffer = view.buffer
  if not is_block_end(buffer, line) then return nil end
  local first = block_start(buffer, line)
  local notes = notes_with_edit(view, margin_notes.notes_for_lines(view, first, line), first, line)
  if #notes == 0 then return nil end
  local _, width = text_column(view)
  local rows = {}
  for _, note in ipairs(notes) do
    local text_height = text_view_for(view, note):measure(width - scaled(INLINE_PAD_X) * 2)
    rows[#rows + 1] = {
      id = note.line .. ":" .. note.col1,
      margin_note = note,
      height = scaled(INLINE_TOP) + text_height + scaled(INLINE_PAD_Y) * 2 + scaled(INLINE_BOTTOM),
    }
  end
  return rows
end

local function inline_generation(_, view)
  local _, width = text_column(view)
  local edit = edit_state(view)
  local instance = markdown_model.peek(view.buffer)
  return table.concat({
    width, view:get_line_height(), instance and instance.published_revision or 0,
    edit and (edit.note.line .. ":" .. edit.note.col1 .. ":" .. edit.input:get_total_visual_lines()) or "",
  }, ":")
end

local inline_row_provider = {
  generation = inline_generation,
  visual_rows = function(_, view, line, placement)
    if placement == "after" then return inline_rows(view, line) end
  end,
}

local inline_metric_provider = {
  -- Note rows own their height, regardless of the source line's presentation.
  priority = 100,
  generation = inline_generation,
  line_height = function(_, _, _, entry)
    local row = entry.provider_row
    if row and row.margin_note then return row.height end
  end,
}

local function wants_notes(view)
  return (document_has_notes(view) or edit_state(view) ~= nil)
    and margin_notes.presents_formatting(view)
end

-- Inline rows exist only while a view without margin space shows notes.
local function sync_inline_rows(view)
  local inline = wants_notes(view) and not margin_notes.column_rect(view)
  if inline == (view.__margin_note_inline or false) then return inline end
  view.__margin_note_inline = inline or nil
  if inline then
    view:add_visual_row_provider(ROW_PROVIDER, inline_row_provider)
    view:add_visual_metric_provider(ROW_PROVIDER, inline_metric_provider)
  else
    view:remove_visual_row_provider(ROW_PROVIDER)
    view:remove_visual_metric_provider(ROW_PROVIDER)
  end
  core.log_quiet("Margin notes %s for %s", inline and "inline" or "in the margin", view.buffer:get_name())
  core.redraw = true
  return inline
end

---Cards for the notes near the viewport: in the margin when it has room,
---otherwise inline below each note's block.
function margin_notes.layout(view)
  if not wants_notes(view) then
    sync_inline_rows(view)
    return nil
  end
  local caret_note = margin_notes.note_at_caret(view)
  if sync_inline_rows(view) then
    return { mode = "inline", cards = inline_layout(view, caret_note) }
  end
  local column_x, column_width = margin_notes.column_rect(view)
  return { mode = "margin", cards = margin_layout(view, column_x, column_width, caret_note) }
end

-- Drawing -----------------------------------------------------------------

local function draw_pointer(card, color)
  local x, y = card.x, card.y
  if card.pointer == "up" then
    local half, length = scaled(INLINE_POINTER_HALF), scaled(INLINE_POINTER_LENGTH)
    local cx = x + scaled(INLINE_POINTER_X) + half
    renderer.draw_poly({ { cx - half, y + 1 }, { cx, y - length }, { cx + half, y + 1 } }, color)
    return
  end
  -- The pointer stays within the flat part of the card's edge.
  local radius = scaled(CARD_RADIUS)
  local half = math.min(scaled(MARGIN_POINTER_HALF), math.floor(card.h / 2) - radius)
  local length = math.floor(scaled(MARGIN_POINTER_LENGTH) * half / scaled(MARGIN_POINTER_HALF))
  local low, high = y + radius + half, y + card.h - radius - half
  local tip_y = low <= high and math.max(low, math.min(high, card.anchor_mid)) or y + math.floor(card.h / 2)
  renderer.draw_poly({ { x + 1, tip_y - half }, { x - length, tip_y }, { x + 1, tip_y + half } }, color)
end

local function draw_card(card, hovered)
  local emphasized = card.editing or card.current or hovered
  local color = emphasized and style.markdown_margin_note_card_active_bg
    or style.markdown_margin_note_card_bg
  draw_pointer(card, color)
  renderer.draw_rounded_rect(card.x, card.y, card.w, card.h, scaled(CARD_RADIUS), color)
  local text_view = card.text_view
  -- Cards that share a display view each place it before drawing.
  text_view.position.x, text_view.position.y = card.text_left, card.text_top
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
      draw_card(card, same_note(card.note, view.__margin_note_hover))
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

-- Returns whether the margin layer owns the press, and the press result.
-- A press in the note editor returns the editor's own result, so an
-- unhandled press reaches the mouse bindings that place its caret.
local function on_mouse_pressed(view, button, x, y, clicks)
  local card = card_at(view, x, y)
  local edit = edit_state(view)
  if card and card.editing and edit then
    core.set_active_view(edit.input)
    return true, edit.input:on_mouse_pressed(button, x, y, clicks)
  end
  if card and button == "left" then
    local input = margin_notes.begin_edit(view, card.note)
    -- The editor takes the card's text geometry, so this same press places its caret.
    input:fit_card(card.text_left, card.text_top + style.padding.y, card.text_view.size.x)
    return true, input:on_mouse_pressed(button, x, y, clicks)
  end
  if edit then end_edit(view, true) end
  return false
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
  sync_inline_rows(view)
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
    local owned, result = on_mouse_pressed(self, button, x, y, clicks)
    if owned then return result end
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
  if view.__margin_note_inline then
    view.__margin_note_inline = nil
    view:remove_visual_row_provider(ROW_PROVIDER)
    view:remove_visual_metric_provider(ROW_PROVIDER)
  end
  return true
end

---The Live Preview view that owns the focused note editor.
function margin_notes.input_owner(view)
  return view and view.margin_note_input and view.margin_note_owner or nil
end

return margin_notes
