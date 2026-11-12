-- Diff Notes: short notes on lines of a Diff Side, shown as note cards.
--
-- An agent writes them when it opens a diff for the user. Each note belongs
-- to a range of lines on one Diff Side and shows below the range's last line.
-- In the side-by-side layout, the other side shows an empty row of the same
-- height, so both sides stay level. A range marker keeps each note on its
-- lines through edits.
local core = require "core"
local style = require "core.style"
local range_marker = require "core.range_marker"
local note_card = require "core.markdown.note_card"

local notes = {}

notes.ROWS = "diff-notes"
local MAX_CARD_WIDTH = 640
local MIN_CARD_WIDTH = 120
local scaled = note_card.scaled

---Make the notes of a Diff View from `specs`: `{ side = 1|2, line, end_line, text }`.
---Lines past the end of a side go to its last line.
function notes.create(side_buffers, specs)
  local list = {}
  for _, spec in ipairs(specs or {}) do
    local buffer = side_buffers[spec.side]
    if buffer then
      local count = #buffer.lines
      local line1 = math.max(1, math.min(count, math.floor(tonumber(spec.line) or 1)))
      local line2 = math.max(line1, math.min(count, math.floor(tonumber(spec.end_line) or line1)))
      local marker = range_marker.new(buffer, {
        line1 = line1, col1 = 1, line2 = line2, col2 = #buffer.lines[line2], kind = "diff-note",
      })
      list[#list + 1] = { buffer = buffer, marker = marker, text = tostring(spec.text or ""), spec = spec,
        line1 = line1, line2 = line2, id = #list + 1 }
    end
  end
  if #list > 0 then core.log_quiet("Diff Notes: %d note(s)", #list) end
  return list
end

---Read each note's lines from its marker. The spec follows, so saved state
---keeps the note on the lines that it moved to.
function notes.refresh_lines(list)
  for _, note in ipairs(list or {}) do
    local range = note.marker:range()
    if range then
      note.line1, note.line2 = range.line1, range.line2
      note.spec.line, note.spec.end_line = range.line1, range.line2
    end
  end
end

function notes.dispose(list)
  for _, note in ipairs(list or {}) do
    range_marker.remove(note.marker)
    if note.text_view then note.text_view:close_model() end
    note.text_view = nil
  end
end

---Split unchanged blocks around noted lines, so folds keep each note's lines
---and their context in view. `side_of(note)` gives `"a"` or `"b"`.
function notes.split_equal_blocks(blocks, list, side_of)
  if not list or #list == 0 then return blocks end
  local result = {}
  for _, block in ipairs(blocks or {}) do
    local spans = {}
    for _, note in ipairs(list) do
      local start = side_of(note) == "a" and block.a_start or block.b_start
      local first, last = note.line1 - start, note.line2 - start
      if last >= 0 and first < block.count then
        spans[#spans + 1] = { math.max(0, first), math.min(block.count - 1, last) }
      end
    end
    if #spans == 0 then
      result[#result + 1] = block
    else
      table.sort(spans, function(x, y) return x[1] < y[1] end)
      local offset = 0
      local function emit(stop, has_next)
        if stop > offset then
          result[#result + 1] = {
            a_start = block.a_start + offset, b_start = block.b_start + offset, count = stop - offset,
            has_prev_change = offset > 0 or block.has_prev_change, has_next_change = has_next,
          }
        end
      end
      for _, span in ipairs(spans) do
        emit(span[1], true)
        offset = math.max(offset, span[2] + 1)
      end
      emit(block.count, block.has_next_change)
    end
  end
  return result
end

-- Card layout -------------------------------------------------------------

local function text_for(note)
  if not note.text_view then
    note.text_view = note_card.Text()
    note.text_view:set_text(note.text)
  end
  return note.text_view
end

local function card_left(view)
  return view.position.x + view:get_gutter_width() + style.padding.x
end

local function card_width(view)
  local available = view.size.x - view:get_gutter_width() - style.padding.x * 2
  return math.max(scaled(MIN_CARD_WIDTH), math.min(scaled(MAX_CARD_WIDTH), math.floor(available)))
end

local function text_width(view)
  return card_width(view) - scaled(note_card.INLINE_PAD_X) * 2
end

---The height of a note's row in `view`: its pointer, card and bottom space.
function notes.row_height(note, view)
  return scaled(note_card.INLINE_TOP) + text_for(note):measure(text_width(view))
    + scaled(note_card.INLINE_PAD_Y) * 2 + scaled(note_card.INLINE_BOTTOM)
end

local function draw_card(view, row, _, y)
  local note, card_view = row.diff_note, row.card_view
  if row.spacer then return end
  local text = text_for(note)
  local pad_x, pad_y = scaled(note_card.INLINE_PAD_X), scaled(note_card.INLINE_PAD_Y)
  local card = { x = card_left(card_view), y = y + scaled(note_card.INLINE_TOP), w = card_width(card_view), pointer = "up" }
  card.h = text:fit_card(card.x + pad_x, card.y + pad_y, card.w - pad_x * 2) + pad_y * 2
  note_card.draw_frame(card, style.markdown_footnote_card_bg)
  text:draw()
end

---A row that shows `note` in `card_view`, or a `spacer` of the same height.
function notes.row(note, card_view, spacer)
  return { id = (spacer and "space:" or "note:") .. note.id, diff_note = note,
    card_view = card_view, spacer = spacer or nil, draw = draw_card }
end

-- Providers ---------------------------------------------------------------

---Install the note rows of `view`. `rows_for(placement, line)` gives the rows
---after or before a line, and `generation()` names the inputs of their heights.
function notes.install(view, rows_for, generation)
  view:add_visual_row_provider(notes.ROWS, {
    visual_rows = function(_, _, line, placement) return rows_for(placement, line) end,
  }, { priority = 60 })
  view:add_visual_metric_provider(notes.ROWS, {
    priority = 110,
    generation = function()
      return table.concat({ generation(), view:get_line_height(), tostring(style.markdown_body_font), SCALE }, ":")
    end,
    line_height = function(_, _, _, entry)
      local row = entry.provider_row
      if row and row.diff_note then return notes.row_height(row.diff_note, row.card_view) end
    end,
  })
end

function notes.uninstall(view)
  view:remove_visual_row_provider(notes.ROWS)
  view:remove_visual_metric_provider(notes.ROWS)
end

-- Side-by-side placement ----------------------------------------------------

---Place the note rows of both Diff Sides from the diff's alignment.
---Returns `{ [1] = rows, [2] = rows }`, where rows are `{ after = {[line] = list}, first = list }`.
function notes.place_sides(list, alignment, side_views, side_index_of)
  local placed = { { after = {}, first = {} }, { after = {}, first = {} } }
  if not list or #list == 0 then return placed end
  -- For each line of a side, the other side's last line at or before it.
  local other = { {}, {} }
  local last_a, last_b = 0, 0
  for _, pair in ipairs(alignment or {}) do
    last_a, last_b = pair.a or last_a, pair.b or last_b
    if pair.a then other[1][pair.a] = last_b end
    if pair.b then other[2][pair.b] = last_a end
  end
  local function add(rows, line, row)
    if line and line > 0 then
      rows.after[line] = rows.after[line] or {}
      table.insert(rows.after[line], row)
    else
      table.insert(rows.first, row)
    end
  end
  for _, note in ipairs(list) do
    local side = side_index_of(note)
    if side then
      local view = side_views[side]
      add(placed[side], note.line2, notes.row(note, view))
      add(placed[3 - side], other[side][note.line2] or 0, notes.row(note, view, true))
    end
  end
  return placed
end

function notes.rows_for(rows, placement, line)
  if not rows then return nil end
  if placement == "after" then return rows.after[line] end
  if line == 1 and #rows.first > 0 then return rows.first end
end

return notes
