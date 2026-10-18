-- Footnotes: Pandoc footnotes shown as cards in Markdown Live Preview.
--
-- A `[^label]` reference shows as a small number. Its `[^label]: text`
-- definition line sits below the paragraph and stays folded away. The native
-- extension scanner finds both. A card shows the text in the free space right
-- of the text column, beside the reference's line. When that space is too
-- narrow, cards show inline below the reference's block. Footnotes never
-- change the text column's width. Each card edits its footnote in place.
local core = require "core"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local file_context = require "core.file_context"
local markdown_model = require "core.markdown.model"
local panes = require "core.panes"

local footnotes = {}

local NOTE_FONT_SCALE = 0.875
local CARD_RADIUS = 5
-- Margin cards point left at their reference line.
local CARD_WIDTH = 200
local MIN_CARD_WIDTH = 160
local MARGIN_GAP = 30
local EDGE_GAP = 12
local CARD_SPACING = 8
local LABEL_GAP = 6
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
local ROW_PROVIDER = "markdown.footnotes"
-- References just above the viewport still push visible cards down.
local LOOKBEHIND_LINES = 80
local PLACEHOLDER = "Write a footnote..."

-- Set by Live Preview: the semantic nodes published for one line, and
-- whether a view presents formatted Markdown rather than its source.
footnotes.nodes_for_line = nil
footnotes.presents_formatting = nil

-- Note input --------------------------------------------------------------

local NoteBuffer = Buffer:extend()

function NoteBuffer:__tostring() return "FootnoteBuffer" end

-- A footnote's text stays on its definition line.
function NoteBuffer:normalize_edit_text(text)
  return (tostring(text or ""):gsub("\r?\n", " "))
end

function NoteBuffer:insert(line, col, text)
  NoteBuffer.super.insert(self, line, col, self:normalize_edit_text(text))
end

-- Note text: inline Markdown ----------------------------------------------
--
-- A note shows inline Markdown as Live Preview does: styled text without its
-- syntax. The native Markdown parser reads each note, as it reads documents.
-- While a note is edited, the syntax of the node at the caret shows.

local NOTE_FORMAT_PROVIDER = "markdown.footnote-format"
local NOTE_MODEL_LISTENER = "markdown.footnote-format"
-- A new card parses on the input thread so it never shows raw syntax.
local NOTE_SETTLE_MS = 4
local SPAN_FONTS = {
  strong = "prose_strong_font",
  emphasis = "prose_emphasis_font",
  strong_emphasis = "prose_strong_emphasis_font",
  code = "code_font",
}
local FORMATTING_NODES = {
  strong = true, emphasis = true, strong_emphasis = true,
  strikethrough = true, highlight = true, code = true,
}
local LINK_NODES = { link = true, image = true, wiki_link = true, embed = true }
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

-- The shown text of a link node: its label, or a wiki link's alias or target.
local function link_text_range(source, node)
  local attributes = node.attributes or {}
  local range = attributes.link_text or attributes.image_alt or attributes.alias
    or attributes.target or attributes.link_destination
  if range and range.line1 == 1 and range.line2 == 1 then return range.col1, range.col2 end
  return node.source.col1, node.source.col2
end

local function note_nodes(view)
  local instance = view.note_model
  if not instance then return nil end
  return instance:nodes_for_lines(1, 1, { allow_pending_result = true })
end

local function note_render(view, source)
  local nodes = note_nodes(view)
  if not nodes then return nil end
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
  for _, node in ipairs(nodes) do
    local range = node.source
    if range.line1 == 1 and (range.line2 or 1) == 1
      and (FORMATTING_NODES[node.type] or LINK_NODES[node.type])
    then
      local revealed = caret ~= nil and caret >= range.col1 and caret <= range.col2
      if LINK_NODES[node.type] then
        local col1, col2 = link_text_range(source, node)
        mark(range.col1, col1, "syntax", revealed)
        mark(col1, col2, "link")
        mark(col2, range.col2, "syntax", revealed)
      else
        mark(range.col1, range.col2, node.type)
        for _, marker in ipairs(node.marker_ranges or {}) do
          if marker.line1 == 1 then mark(marker.col1, marker.col2, "syntax", revealed) end
        end
      end
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
      -- Revealed syntax keeps the plain note font.
      local font = kinds.syntax and base
        or kinds.code and styled_font(base, "code")
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
    return table.concat({
      tostring(view:get_font()), tostring(reveal_col(view) or 0),
      tostring(view.note_model and view.note_model.generation or 0),
    }, ":")
  end,
  render_line = function(_, view, _, context)
    return note_render(view, context.source_text)
  end,
}

local NoteInput = TextView:extend()

function NoteInput:__tostring() return "FootnoteInput" end

function NoteInput:new(owner)
  NoteInput.super.new(self, NoteBuffer())
  self.footnote_input = true
  self.footnote_owner = owner
  self.font = "markdown_body_font"
  self.scrollable = false
  self.hide_scrollbars = true
  self.show_current_line_highlight = false
  self.wrap_continuation_flush = true
  self:set_wrapping_enabled(true)
  self:add_line_render_provider(NOTE_FORMAT_PROVIDER, note_format_provider)
  -- A Markdown name makes the note a Markdown Model buffer. It has no file.
  self.buffer.filename = "footnote.md"
  self.note_model = markdown_model.get(self.buffer)
  self.note_model:add_listener(NOTE_MODEL_LISTENER, function()
    self:invalidate_line_render(NOTE_FORMAT_PROVIDER)
    core.redraw = true
  end)
end

function NoteInput:close_model()
  if not self.note_model then return end
  self.note_model = nil
  markdown_model.close(self.buffer, "footnote closed")
end

function NoteInput:get_text()
  return self.buffer:get_text(1, 1, math.huge, math.huge)
end

function NoteInput:set_text(text)
  self.buffer:remove(1, 1, math.huge, math.huge)
  self.buffer:insert(1, 1, text or "")
  self.buffer:clear_undo_redo()
  self.buffer:set_selection(1, math.huge, 1, math.huge)
  self.note_model:settle(NOTE_SETTLE_MS)
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

-- Footnotes ---------------------------------------------------------------

local function scaled(value) return math.floor(value * SCALE + 0.5) end

local function line_text(buffer, line)
  return (buffer.lines[line] or ""):gsub("\n$", "")
end

local DEFINITION_PATTERN = "^( ? ? ?%[%^([^%s%[%]]+)%]:[ \t]*)(.-)%s*$"

-- The label and text columns of a definition line.
local function parse_definition(text)
  local prefix, label, body = text:match(DEFINITION_PATTERN)
  if not prefix then return nil end
  return label, #prefix + 1, #prefix + 1 + #body
end

local function is_definition(text) return text:match(DEFINITION_PATTERN) ~= nil end

-- Definition lines by label, from the published parse.
local function definition_lines(view)
  local instance = markdown_model.peek(view.buffer)
  if not (instance and instance.published_revision) then return nil end
  return instance:footnote_definitions()
end

local function document_has_notes(view)
  local definitions = definition_lines(view)
  return definitions ~= nil and next(definitions) ~= nil
end

local function note_from_node(buffer, node, definitions)
  local range = node.attributes and node.attributes.footnote_label
  if not range then return nil end
  local line = node.source.line1
  local label = line_text(buffer, line):sub(range.col1, range.col2 - 1)
  local definition_line = definitions[label]
  if not definition_line then return nil end
  local definition = line_text(buffer, definition_line)
  local definition_label, body_col1, body_col2 = parse_definition(definition)
  if definition_label ~= label then return nil end
  return {
    label = label,
    line = line,
    col1 = node.source.col1,
    col2 = node.source.col2,
    definition_line = definition_line,
    body_col1 = body_col1,
    body_col2 = body_col2,
    text = definition:sub(body_col1, body_col2 - 1),
  }
end

---Footnotes whose references are on lines `line1` to `line2`. A reference
---without a definition has no footnote.
function footnotes.notes_for_lines(view, line1, line2)
  local notes = {}
  local nodes_for_line = footnotes.nodes_for_line
  local definitions = definition_lines(view)
  if not (nodes_for_line and definitions and next(definitions)) then return notes end
  local buffer = view.buffer
  local lines = buffer.lines
  for line = math.max(1, line1), math.min(line2, #lines) do
    -- Most lines have no reference and skip the parse. References inside a
    -- definition belong to its hidden line.
    if lines[line]:find("[^", 1, true) and not is_definition(lines[line]) then
      for _, node in ipairs(nodes_for_line(view, line) or {}) do
        if node.type == "footnote_reference" and node.source.line1 == line then
          local note = note_from_node(buffer, node, definitions)
          if note then notes[#notes + 1] = note end
        end
      end
    end
  end
  return notes
end

---The footnote whose reference contains the primary caret.
function footnotes.note_at_caret(view)
  local line, col = view.buffer:get_selection()
  for _, note in ipairs(footnotes.notes_for_lines(view, line, line)) do
    if col >= note.col1 and col <= note.col2 then return note end
  end
end

local function same_note(a, b)
  return a and b and a.line == b.line and a.col1 == b.col1
end

-- A definition holds one line of text.
local function sanitize(text)
  text = tostring(text or ""):gsub("[\r\n]+", " ")
  return text:match("^%s*(.-)%s*$")
end

local function note_source_is_current(buffer, note)
  local label, body_col1 = parse_definition(line_text(buffer, note.definition_line))
  return label == note.label and body_col1 == note.body_col1
    and line_text(buffer, note.line):sub(note.col1, note.col2 - 1) == "[^" .. note.label .. "]"
end

---Replace a footnote's text. Empty text removes the footnote.
function footnotes.set_text(view, note, text)
  local buffer = view.buffer
  if not note_source_is_current(buffer, note) then
    core.log_quiet("Footnote %s at %s:%d moved before its edit was saved",
      note.label, buffer:get_name(), note.line)
    return false
  end
  text = sanitize(text)
  if text == "" then return footnotes.remove(view, note) end
  local definition = line_text(buffer, note.definition_line)
  local _, body_col1, body_col2 = parse_definition(definition)
  if text == definition:sub(body_col1, body_col2 - 1) then return true end
  buffer:apply_edits({
    { line1 = note.definition_line, col1 = body_col1,
      line2 = note.definition_line, col2 = body_col2, text = text },
  }, { type = "markdown-footnote", reason = "edit" })
  core.log_quiet("Footnote %s edited at %s:%d (%d bytes)",
    note.label, buffer:get_name(), note.definition_line, #text)
  return true
end

local function is_blank(text) return not text:find("%S") end

---Remove a footnote's reference and its definition line.
function footnotes.remove(view, note)
  local buffer = view.buffer
  local first, last = note.definition_line, note.definition_line
  -- The blank line that set the definition apart goes with it.
  if first > 1 and is_blank(line_text(buffer, first - 1)) then first = first - 1 end
  local removal
  if last < #buffer.lines then
    removal = { line1 = first, col1 = 1, line2 = last + 1, col2 = 1, text = "" }
  else
    local before = math.max(1, first - 1)
    removal = {
      line1 = before, col1 = first > 1 and #line_text(buffer, before) + 1 or 1,
      line2 = last, col2 = #line_text(buffer, last) + 1, text = "",
    }
  end
  buffer:apply_edits({
    { line1 = note.line, col1 = note.col1, line2 = note.line, col2 = note.col2, text = "" },
    removal,
  }, { type = "markdown-footnote", reason = "remove" })
  core.log_quiet("Footnote %s removed at %s:%d", note.label, buffer:get_name(), note.line)
  return true
end

-- Editing -----------------------------------------------------------------

local function edit_state(view) return view.__footnote_edit end

local function end_edit(view, save)
  local edit = edit_state(view)
  if not edit or edit.ending then return false end
  edit.ending = true
  local text = edit.input:get_text()
  view.__footnote_edit = nil
  panes.unregister_focus_target(edit.input)
  edit.input:close_model()
  if core.active_view == edit.input then core.set_active_view(view) end
  if save then
    footnotes.set_text(view, edit.note, text)
  elseif edit.created and note_source_is_current(view.buffer, edit.note) then
    -- Cancelling a footnote that was just added leaves nothing behind.
    footnotes.remove(view, edit.note)
  end
  core.redraw = true
  return true
end

---Open the editor on a footnote's card.
function footnotes.begin_edit(view, note, opts)
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
  view.__footnote_edit = { note = note, input = input, created = opts.created }
  panes.register_focus_target(view, input)
  core.set_active_view(input)
  core.blink_reset()
  core.redraw = true
  core.log_quiet("Footnote %s editing at %s:%d", note.label, view.buffer:get_name(), note.line)
  return input
end

function footnotes.commit_edit(view) return end_edit(view, true) end
function footnotes.cancel_edit(view) return end_edit(view, false) end
function footnotes.editing_input(view)
  local edit = edit_state(view)
  return edit and edit.input or nil
end

-- The scanner finds no footnotes in these nodes, so a footnote added there
-- would never show.
local NOTELESS_NODES = {
  code = true, code_fenced = true, code_indented = true, comment = true,
  frontmatter = true, html = true, math = true,
}

local function noteless_node_at(view, line, col)
  local nodes_for_line = footnotes.nodes_for_line
  for _, node in ipairs(nodes_for_line and nodes_for_line(view, line) or {}) do
    local source = node.source
    local line2 = source.line2 or source.line1
    if NOTELESS_NODES[node.type]
      and (source.line1 < line or source.line1 == line and source.col1 < col)
      and (line2 > line or line2 == line and source.col2 > col)
    then
      return node
    end
  end
end

local function is_heading(text) return text:find("^%s*#") ~= nil end

-- The last line of the block of non-blank lines that holds `line`.
-- A heading is a block of its own.
local function block_end(buffer, line)
  if is_heading(line_text(buffer, line)) then return line end
  local last = line
  while last < #buffer.lines do
    local text = line_text(buffer, last + 1)
    if is_blank(text) or is_heading(text) then break end
    last = last + 1
  end
  return last
end

-- The line after which a new definition for the block at `line` goes: the
-- block's end, or the last of the definitions that already follow it.
local function definition_anchor(buffer, line)
  local last = block_end(buffer, line)
  while last + 2 <= #buffer.lines and is_blank(line_text(buffer, last + 1))
    and is_definition(line_text(buffer, last + 2))
  do
    last = last + 2
  end
  return last
end

local function next_label(view)
  local highest = 0
  for label in pairs(definition_lines(view) or {}) do
    highest = math.max(highest, tonumber(label) or 0)
  end
  return tostring(highest + 1)
end

local function word_end(text, col)
  while col <= #text and text:sub(col, col):match("[%w_\128-\255'-]") do col = col + 1 end
  return col
end

---Add a footnote at the end of the selection, or after the word at the
---caret, with its definition below the paragraph, and open its editor. A
---caret on a reference edits that footnote instead. Code and other places
---that show no footnotes take no new footnote.
function footnotes.add(view)
  local existing = footnotes.note_at_caret(view)
  if existing then return footnotes.begin_edit(view, existing) end
  local buffer = view.buffer
  local _, _, line, col = buffer:get_selection(true)
  local text = line_text(buffer, line)
  col = word_end(text, col)
  local noteless = noteless_node_at(view, line, col)
  if noteless or is_definition(text) then
    local place = noteless and noteless.type or "footnote definition"
    core.log_quiet("Footnote refused at %s:%d inside %s", buffer:get_name(), line, place)
    core.status_bar:show_message("i", style.text,
      noteless and "Footnotes cannot go inside code" or "Footnotes cannot go inside a footnote")
    return nil
  end
  local label = next_label(view)
  local reference = "[^" .. label .. "]"
  local prefix = reference .. ": "
  local anchor = definition_anchor(buffer, line)
  -- A blank line keeps the definition apart from the block that follows.
  local follows = anchor < #buffer.lines and not is_blank(line_text(buffer, anchor + 1))
  local anchor_end = #line_text(buffer, anchor) + 1
  buffer:apply_edits({
    { line1 = line, col1 = col, line2 = line, col2 = col, text = reference },
    { line1 = anchor, col1 = anchor_end, line2 = anchor, col2 = anchor_end,
      text = "\n\n" .. prefix .. (follows and "\n" or "") },
  }, { type = "markdown-footnote", reason = "add" })
  local note = {
    label = label, line = line, col1 = col, col2 = col + #reference,
    definition_line = anchor + 2,
    body_col1 = #prefix + 1, body_col2 = #prefix + 1, text = "",
  }
  buffer:set_selection(line, note.col2, line, note.col2)
  core.log_quiet("Footnote %s added at %s:%d with its definition at line %d",
    label, buffer:get_name(), line, note.definition_line)
  return footnotes.begin_edit(view, note, { created = true })
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
function footnotes.column_rect(view)
  local text_x, text_width = text_column(view)
  local x = text_x + text_width + scaled(MARGIN_GAP)
  local right = view.position.x + view.size.x - scrollbar_width(view) - scaled(EDGE_GAP)
  local width = math.min(scaled(CARD_WIDTH), right - x)
  if width < scaled(MIN_CARD_WIDTH) then return nil end
  return x, width
end

local function close_displays(view)
  local displays = view.__footnote_displays
  if not displays then return end
  view.__footnote_displays = nil
  for _, display in pairs(displays.views) do display:close_model() end
end

-- Notes with the same text share one display view.
local function display_for(view, text)
  local displays = view.__footnote_displays
  if not displays or displays.count > MAX_DISPLAYS then
    close_displays(view)
    displays = { count = 0, views = {} }
    view.__footnote_displays = displays
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

-- A card shows its footnote's label before the text.
local function label_width(text_view, note)
  return text_view:get_font():get_width(note.label) + scaled(LABEL_GAP)
end

-- The width left for a footnote's text in a card of `width`.
local function text_width(text_view, note, width, pad_x)
  return width - scaled(pad_x) * 2 - label_width(text_view, note)
end

-- Wrap a note's text inside a card at (`x`, `y`); returns the card height.
local function place_text(text_view, note, x, y, width, pad_x, pad_y)
  return text_view:fit_card(x + scaled(pad_x) + label_width(text_view, note), y + scaled(pad_y),
    text_width(text_view, note, width, pad_x)) + scaled(pad_y) * 2
end

local function new_card(view, note, x, y, width, height, pointer, caret_note)
  local text_view, editing = text_view_for(view, note)
  local text_x, text_y = text_view:get_line_screen_position(1, 1)
  return {
    note = note, x = x, y = y, w = width, h = height, pointer = pointer,
    text_view = text_view, text_left = text_view.position.x, text_top = text_view.position.y,
    text_x = text_x, text_y = text_y, editing = editing,
    label_x = text_view.position.x - label_width(text_view, note),
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

-- Margin cards are centered on their reference line and stacked so none overlap.
local function margin_layout(view, column_x, column_width, caret_note)
  local minline, maxline = view:get_visible_line_range()
  local line1 = minline - LOOKBEHIND_LINES
  local notes = notes_with_edit(view, footnotes.notes_for_lines(view, line1, maxline), line1, maxline)
  local cards, bottom = {}, -math.huge
  local half_line = math.floor(view:get_line_height() / 2)
  for _, note in ipairs(notes) do
    local _, reference_y = view:get_line_screen_position(note.line, note.col1)
    local text_view = text_view_for(view, note)
    local height = place_text(text_view, note, column_x, 0, column_width, MARGIN_PAD_X, MARGIN_PAD_Y)
    local reference_mid = reference_y + half_line
    local y = math.max(reference_mid - math.floor(height / 2), bottom + scaled(CARD_SPACING))
    place_text(text_view, note, column_x, y, column_width, MARGIN_PAD_X, MARGIN_PAD_Y)
    local card = new_card(view, note, column_x, y, column_width, height, "left", caret_note)
    card.reference_y, card.reference_mid = reference_y, reference_mid
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
    if row and row.footnote then
      local note = edit and same_note(row.footnote, edit.note) and edit.note or row.footnote
      local y = entry.y + scaled(INLINE_TOP)
      local height = place_text(text_view_for(view, note), note, x, y, width, INLINE_PAD_X, INLINE_PAD_Y)
      cards[#cards + 1] = new_card(view, note, x, y, width, height, "up", caret_note)
    end
  end
  return cards
end

-- Inline rows -------------------------------------------------------------

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
  local notes = notes_with_edit(view, footnotes.notes_for_lines(view, first, line), first, line)
  if #notes == 0 then return nil end
  local _, width = text_column(view)
  local rows = {}
  for _, note in ipairs(notes) do
    local text_view = text_view_for(view, note)
    local text_height = text_view:measure(text_width(text_view, note, width, INLINE_PAD_X))
    rows[#rows + 1] = {
      id = note.line .. ":" .. note.col1,
      footnote = note,
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
    if row and row.footnote then return row.height end
  end,
}

local function wants_notes(view)
  return (document_has_notes(view) or edit_state(view) ~= nil)
    and footnotes.presents_formatting(view)
end

-- Inline rows exist only while a view without margin space shows notes.
local function sync_inline_rows(view)
  local inline = wants_notes(view) and not footnotes.column_rect(view)
  if inline == (view.__footnote_inline or false) then return inline end
  view.__footnote_inline = inline or nil
  if inline then
    view:add_visual_row_provider(ROW_PROVIDER, inline_row_provider)
    view:add_visual_metric_provider(ROW_PROVIDER, inline_metric_provider)
  else
    view:remove_visual_row_provider(ROW_PROVIDER)
    view:remove_visual_metric_provider(ROW_PROVIDER)
  end
  core.log_quiet("Footnotes %s for %s", inline and "inline" or "in the margin", view.buffer:get_name())
  core.redraw = true
  return inline
end

-- Hidden definitions ------------------------------------------------------
--
-- Each run of definition lines folds into the line above it, so the cards
-- alone show the text. A fold opens while the caret is inside it, and the
-- definition then reads and edits as source.

local FOLD_KIND = "markdown-footnote"

-- The folds that hide the definitions: from the line above each run of
-- definitions through the run, and the blank line after it when the line
-- above is blank too.
local function definition_folds(view)
  local buffer = view.buffer
  local lines = {}
  for _, line in pairs(definition_lines(view) or {}) do lines[#lines + 1] = line end
  table.sort(lines)
  local folds = {}
  local index = 1
  while index <= #lines do
    local first, last = lines[index], lines[index]
    index = index + 1
    -- Definitions apart by at most one blank line form one run.
    while index <= #lines and (lines[index] == last + 1
      or lines[index] == last + 2 and is_blank(line_text(buffer, last + 1)))
    do
      last = lines[index]
      index = index + 1
    end
    if first > 1 then
      local line1 = first - 1
      if is_blank(line_text(buffer, line1)) and last < #buffer.lines
        and is_blank(line_text(buffer, last + 1))
      then
        last = last + 1
      end
      local previous = folds[#folds]
      if previous and line1 <= previous.line2 then
        previous.line2 = last
      else
        folds[#folds + 1] = { line1 = line1, line2 = last }
      end
    end
  end
  return folds
end

local function clear_definition_folds(view)
  local folds = view.__footnote_folds
  view.__footnote_folds = nil
  for _, fold in pairs(folds and folds.by_range or {}) do
    view:remove_fold_region(fold, "markdown-footnote-clear")
  end
end

local function sync_definition_folds(view)
  local instance = markdown_model.peek(view.buffer)
  if not (instance and wants_notes(view)) then
    clear_definition_folds(view)
    return
  end
  local state = view.__footnote_folds
  if not state then
    state = { by_range = {} }
    view.__footnote_folds = state
  end
  if state.generation ~= instance.generation then
    state.generation = instance.generation
    -- Folds follow edits, so only folds whose ranges changed are replaced.
    local wanted = {}
    for _, range in ipairs(definition_folds(view)) do
      wanted[range.line1 .. ":" .. range.line2] = range
    end
    local by_range = {}
    for _, fold in pairs(state.by_range) do
      local key = view:refresh_fold_region(fold) and (fold.line1 .. ":" .. fold.line2)
      if key and wanted[key] and not by_range[key] then
        by_range[key] = fold
      else
        view:remove_fold_region(fold, "markdown-footnote-stale")
      end
    end
    for key, range in pairs(wanted) do
      if not by_range[key] then
        local fold, err = view:add_fold_region {
          id = FOLD_KIND .. ":" .. key,
          line1 = range.line1,
          line2 = range.line2,
          collapsed = false,
          show_widget = false,
          invalidate_on_edit_overlap = false,
          kind = FOLD_KIND,
        }
        if fold then
          by_range[key] = fold
        else
          core.log_quiet("Footnote definitions at lines %d-%d stay visible: %s",
            range.line1, range.line2, tostring(err))
        end
      end
    end
    state.by_range = by_range
  end
  local line = view.buffer:get_selection()
  for _, fold in pairs(state.by_range) do
    local open = line > fold.line1 and line <= fold.line2
    if open == fold.collapsed then
      if open then
        view:expand_fold_region(fold, "markdown-footnote-caret")
      else
        view:collapse_fold_region(fold, "markdown-footnote-caret")
      end
    end
  end
end

---Cards for the notes near the viewport: in the margin when it has room,
---otherwise inline below each note's block.
function footnotes.layout(view)
  if not wants_notes(view) then
    sync_inline_rows(view)
    return nil
  end
  local caret_note = footnotes.note_at_caret(view)
  if sync_inline_rows(view) then
    return { mode = "inline", cards = inline_layout(view, caret_note) }
  end
  local column_x, column_width = footnotes.column_rect(view)
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
  local tip_y = low <= high and math.max(low, math.min(high, card.reference_mid)) or y + math.floor(card.h / 2)
  renderer.draw_poly({ { x + 1, tip_y - half }, { x - length, tip_y }, { x + 1, tip_y + half } }, color)
end

local function draw_card(card, hovered)
  local emphasized = card.editing or card.current or hovered
  local color = emphasized and style.markdown_footnote_card_active_bg
    or style.markdown_footnote_card_bg
  draw_pointer(card, color)
  renderer.draw_rounded_rect(card.x, card.y, card.w, card.h, scaled(CARD_RADIUS), color)
  local text_view = card.text_view
  -- Cards that share a display view each place it before drawing.
  text_view.position.x, text_view.position.y = card.text_left, card.text_top
  renderer.draw_text(text_view:get_font(), card.note.label, card.label_x, card.text_y,
    style.markdown_live_footnote)
  if text_view:get_text() == "" then
    renderer.draw_text(text_view:get_font(), PLACEHOLDER, card.text_x, card.text_y,
      style.markdown_footnote_placeholder)
  end
  text_view:draw()
  if card.editing then text_view:draw_overlay() end
end

function footnotes.draw(view)
  local layout = footnotes.layout(view)
  view.__footnote_layout = layout
  if not layout then return end
  core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
  for _, card in ipairs(layout.cards) do
    if card.y + card.h >= view.position.y and card.y <= view.position.y + view.size.y then
      draw_card(card, same_note(card.note, view.__footnote_hover))
    end
  end
  core.pop_clip_rect()
end

-- Events ------------------------------------------------------------------

local function card_at(view, x, y)
  local layout = view.__footnote_layout
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
  if not same_note(hovered, view.__footnote_hover) then
    view.__footnote_hover = hovered
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

-- Returns whether the footnote layer owns the press, and the press result.
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
    local input = footnotes.begin_edit(view, card.note)
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
  sync_definition_folds(view)
end

local function call_class(view, name, ...)
  return getmetatable(view)[name](view, ...)
end

---Install the footnote layer on a Live Preview Text View.
function footnotes.attach(view)
  if view.__footnotes_attached then return false end
  view.__footnotes_attached = true
  view.draw = function(self, ...)
    local result = call_class(self, "draw", ...)
    footnotes.draw(self)
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

function footnotes.detach(view)
  if not view.__footnotes_attached then return false end
  end_edit(view, true)
  view.__footnotes_attached = nil
  view.draw, view.update = nil, nil
  view.on_mouse_moved, view.on_mouse_pressed, view.on_mouse_released = nil, nil, nil
  view.__footnote_layout, view.__footnote_hover = nil, nil
  close_displays(view)
  clear_definition_folds(view)
  if view.__footnote_inline then
    view.__footnote_inline = nil
    view:remove_visual_row_provider(ROW_PROVIDER)
    view:remove_visual_metric_provider(ROW_PROVIDER)
  end
  return true
end

---The Live Preview view that owns the focused note editor.
function footnotes.input_owner(view)
  return view and view.footnote_input and view.footnote_owner or nil
end

return footnotes
