-- Note cards: the card that shows a short note in inline Markdown.
--
-- Live Preview Footnotes and Diff Notes use the same card: a rounded card in
-- the Footnote colours with a pointer at the text that it belongs to. The note
-- text is one paragraph of inline Markdown, shown without its syntax.
local core = require "core"
local style = require "core.style"
local syntax = require "core.syntax"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local markdown_model = require "core.markdown.model"

local note_card = {}

local NOTE_FONT_SCALE = 0.875
local CARD_RADIUS = 5
-- Inline cards point up at the line above them.
note_card.INLINE_PAD_X, note_card.INLINE_PAD_Y = 8, 5
local INLINE_POINTER_LENGTH, INLINE_POINTER_HALF = 14, 10
local INLINE_POINTER_X = 40
-- The space above an inline card holds its pointer.
note_card.INLINE_TOP = INLINE_POINTER_LENGTH + 3
note_card.INLINE_BOTTOM = 4
-- Margin cards point left at their reference line.
local MARGIN_POINTER_LENGTH, MARGIN_POINTER_HALF = 8, 7

local function scaled(value) return math.floor(value * SCALE + 0.5) end
note_card.scaled = scaled

-- Note buffer -------------------------------------------------------------

local NoteBuffer = Buffer:extend()

function NoteBuffer:__tostring() return "NoteBuffer" end

-- A note's text stays on one line.
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

local NOTE_FORMAT_PROVIDER = "markdown.note-format"
local NOTE_MODEL_LISTENER = "markdown.note-format"
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
-- An inline style's font at the note font's size.
local function styled_font(base, span_type)
  local source = style[SPAN_FONTS[span_type]]
  local size = base:get_size()
  -- Code keeps the size it has beside prose in the document.
  if span_type == "code" then
    size = size * source:get_size() / style.markdown_body_font:get_size()
  end
  return style.get_scaled_font(source, size)
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

-- Note text ---------------------------------------------------------------
--
-- A wrapped Text View of one note. A card places it, and it can also edit
-- the note in place.

local Text = TextView:extend()
note_card.Text = Text

function Text:__tostring() return "NoteText" end

function Text:new()
  Text.super.new(self, NoteBuffer())
  self.font = "markdown_body_font"
  self.scrollable = false
  self.hide_scrollbars = true
  self.show_current_line_highlight = false
  self.wrap_continuation_flush = true
  self:set_wrapping_enabled(true)
  self:add_line_render_provider(NOTE_FORMAT_PROVIDER, note_format_provider)
  -- Markdown syntax makes the note a Markdown Model buffer. It has no file
  -- name, so autosave never writes it to disk.
  self.buffer:set_syntax(syntax.get("footnote.md"), "footnote")
  self.note_model = markdown_model.get(self.buffer)
  self.note_model:add_listener(NOTE_MODEL_LISTENER, function()
    self:invalidate_line_render(NOTE_FORMAT_PROVIDER)
    core.redraw = true
  end)
end

function Text:close_model()
  if not self.note_model then return end
  self.note_model = nil
  markdown_model.close(self.buffer, "note closed")
end

function Text:get_text()
  return self.buffer:get_text(1, 1, math.huge, math.huge)
end

function Text:set_text(text)
  self.buffer:remove(1, 1, math.huge, math.huge)
  self.buffer:insert(1, 1, text or "")
  self.buffer:clear_undo_redo()
  self.buffer:set_selection(1, math.huge, 1, math.huge)
  self.note_model:settle(NOTE_SETTLE_MS)
end

function Text:get_gutter_width() return 0, 0 end
function Text:draw_line_gutter() return self:get_line_height() end
function Text:draw_line_highlight() end
function Text:draw_scrollbar() end
function Text:draw_background() end
function Text:draw_content_left_edge() end
function Text:draw_soft_wrap_continuation_indicators() end

-- Notes read a step smaller than the prose they annotate.
function Text:get_font()
  local base = style.markdown_body_font
  return style.get_scaled_font(base, base:get_size() * NOTE_FONT_SCALE)
end

-- Cards show and edit a note in the same wrapped shape.
function Text:compute_wrap_width()
  return math.max(1, self.size.x)
end

---Wrap the text to `width` and return its height. The view stays in place.
function Text:measure(width)
  if self.size.x ~= width then self.size.x = width end
  self:update_wrap_cache()
  return math.max(1, self:get_total_visual_lines()) * self:get_line_height()
end

---Place the text with its first row at (`x`, `top`), wrapped to `width`.
function Text:fit_card(x, top, width)
  local height = self:measure(width)
  -- The text view draws its first row one padding below its top.
  self.position.x, self.position.y = x, top - style.padding.y
  self.size.y = height + style.padding.y * 2
  self.scroll.x, self.scroll.y, self.scroll.to.x, self.scroll.to.y = 0, 0, 0, 0
  return height
end

-- Card frame --------------------------------------------------------------

---Draw a card's pointer and its rounded body in `color`. An inline card
---(`pointer = "up"`) points at the line above it. A margin card (`"left"`)
---points at `reference_mid`, inside the flat part of its edge.
function note_card.draw_frame(card, color)
  local x, y = card.x, card.y
  if card.pointer == "up" then
    local half, length = scaled(INLINE_POINTER_HALF), scaled(INLINE_POINTER_LENGTH)
    local cx = x + scaled(INLINE_POINTER_X) + half
    renderer.draw_poly({ { cx - half, y + 1 }, { cx, y - length }, { cx + half, y + 1 } }, color)
  else
    local radius = scaled(CARD_RADIUS)
    local half = math.min(scaled(MARGIN_POINTER_HALF), math.floor(card.h / 2) - radius)
    local length = math.floor(scaled(MARGIN_POINTER_LENGTH) * half / scaled(MARGIN_POINTER_HALF))
    local low, high = y + radius + half, y + card.h - radius - half
    local tip_y = low <= high and math.max(low, math.min(high, card.reference_mid)) or y + math.floor(card.h / 2)
    renderer.draw_poly({ { x + 1, tip_y - half }, { x - length, tip_y }, { x + 1, tip_y + half } }, color)
  end
  renderer.draw_rounded_rect(card.x, card.y, card.w, card.h, scaled(CARD_RADIUS), color)
end

return note_card
