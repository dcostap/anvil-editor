-- Shown Indentation: an empty line holds no indentation, but a caret on it
-- initially shows where Enter at the end of the line above would put the caret.
-- Each View keeps its chosen position. Arrows and clicks move within the
-- indentation; text selections still use real text positions.
-- Tab, Shift+Tab, End, Backspace and typed spaces or tabs change the level of
-- that caret without an edit, until the caret leaves the line. Typing and paste write the
-- indentation first. A line that the user's edits leave holding only
-- whitespace becomes empty when no caret is on it, or at once when it holds
-- the Shown Indentation and the caret is at its end.
local core = require "core"
local config = require "core.config"
local intelligence = require "core.language_intelligence"
local Buffer = require "core.buffer"

local empty_line_indent = {}

local SCAN_LIMIT = 1000
local openers = { ["("] = true, ["["] = true, ["{"] = true }
-- Edits that the user did not make.
local skipped_change_types = {
  undo = true, redo = true, reload = true, recovery = true, load = true,
  ["empty-line-indent"] = true,
}

local cache = setmetatable({}, { __mode = "k" })
-- Buffers track whitespace cleanup. Each View owns its chosen caret positions.
local states = setmetatable({}, { __mode = "k" })
local caret_states = setmetatable({}, { __mode = "k" })

local function state_for(buffer)
  local state = states[buffer]
  if not state then
    state = { edited = {} }
    states[buffer] = state
  end
  return state
end

local function has_content(text)
  return text and text:find("[^\t \r\n]") ~= nil
end

local function whitespace_only(text)
  return text ~= nil and text ~= "\n" and not has_content(text)
end

local function token_is_code(buffer, line, col)
  local column = 0
  for _, token_type, token_text in buffer.highlighter:each_token(line) do
    column = column + #token_text
    if column >= col then return token_type ~= "comment" and token_type ~= "string" end
  end
  return true
end

local function is_markdown(buffer)
  local name = tostring(buffer.syntax and buffer.syntax.name or ""):lower()
  return name:find("markdown", 1, true) ~= nil
end

-- The whitespace that Enter at the end of `line` puts on the new line.
-- Keep this in step with `core:newline`.
local function newline_indent(buffer, line)
  local line_text = buffer.lines[line]
  local before = line_text:gsub("\n$", "")
  local lead = before:match("^[\t ]*")
  local last_col = #(before:gsub("[\t ]+$", ""))
  if openers[before:sub(last_col, last_col)] and token_is_code(buffer, line, last_col) then
    return lead .. buffer:get_indent_string(1)
  end
  local context = {
    event = "newline", line = line, col = #before + 1,
    base_indent = lead, full_indent = lead,
    previous_line_text = line_text, before_text = before,
  }
  if intelligence.newline_continuation(buffer, line + 1, context) then
    -- A blank line ends a Markdown list or quote, so it starts at the margin.
    return is_markdown(buffer) and "" or lead
  end
  local indent = intelligence.indent_for_line(buffer, line + 1, context)
  return type(indent) == "string" and indent or lead
end

-- The indentation of a new line before `line`, and the line above it with
-- content that gives it.
local function indent_before(buffer, line)
  for previous = line - 1, math.max(1, line - SCAN_LIMIT), -1 do
    if has_content(buffer.lines[previous]) then
      return newline_indent(buffer, previous), previous
    end
  end
  return ""
end

---Returns the indentation that a new empty line before `line` shows.
---@param buffer core.buffer
---@param line integer
---@return string
function empty_line_indent.indent_before(buffer, line)
  return (indent_before(buffer, line))
end

local function entry(buffer, line)
  local text = buffer.lines[line]
  if not text or has_content(text) then return nil end
  local revision = buffer.text_revision
  local lines = cache[buffer]
  if not lines or lines.revision ~= revision or lines.syntax ~= buffer.syntax then
    lines = { revision = revision, syntax = buffer.syntax }
    cache[buffer] = lines
  end
  local found = lines[line]
  if found then return found end
  local indent, reference = indent_before(buffer, line)
  found = { indent = indent, reference = reference }
  lines[line] = found
  return found
end

local function chosen_position(view, line)
  local state = caret_states[view]
  local levels = state and state.levels
  return levels and state.revision == view.buffer.text_revision and levels[line]
end

---Returns the indentation that a caret on `line` shows, or nil when the line
---has content. The line can hold whitespace; its whitespace does not count.
---@param view core.textview
---@param line integer
---@return string?
function empty_line_indent.get(view, line)
  local found = entry(view.buffer, line)
  if not found then return nil end
  local position = chosen_position(view, line)
  return position and position.indent or found.indent
end

local function forget_left_positions(view, selections)
  local state = caret_states[view]
  if not state then return end
  if state.revision ~= view.buffer.text_revision then
    state.levels, state.revision = {}, view.buffer.text_revision
    return
  end
  for line in pairs(state.levels) do
    local present = false
    for i = 1, #selections, 4 do
      if selections[i] == line and selections[i + 1] == 1
      and selections[i + 2] == line and selections[i + 3] == 1 then
        present = true
        break
      end
    end
    if not present then state.levels[line] = nil end
  end
end

local function set_level(view, line, indent)
  local state = caret_states[view]
  if not state then
    state = { levels = {} }
    caret_states[view] = state
    view:add_selection_listener("empty-line-indent", function(changed, selection)
      forget_left_positions(changed, selection.selections)
    end)
  end
  local revision = view.buffer.text_revision
  if state.revision ~= revision then
    state.levels, state.revision = {}, revision
  end
  local position = state.levels[line]
  local extent = position and position.extent or entry(view.buffer, line).indent
  if extent:sub(1, #indent) ~= indent then extent = indent end
  if position then
    position.indent, position.extent = indent, extent
  else
    state.levels[line] = { indent = indent, extent = extent }
  end
  -- The text position stays the same, but the next vertical move needs the new x.
  view.last_x_offset.line = nil
  core.blink_reset()
  core.redraw = true
end

local function visual_width(buffer, indent)
  local _, indent_size = buffer:get_indent_info()
  local columns = 0
  for i = 1, #indent do
    if indent:byte(i) == 9 then
      columns = columns + indent_size - (columns % indent_size)
    else
      columns = columns + 1
    end
  end
  return columns
end

local function remove_level(buffer, indent)
  if indent:sub(-1) == "\t" then return indent:sub(1, -2) end
  local _, indent_size = buffer:get_indent_info()
  local spaces = #indent:match(" *$")
  local remove = spaces % indent_size
  if remove == 0 then remove = math.min(spaces, indent_size) end
  return indent:sub(1, #indent - remove)
end

local function single_empty_line_caret(buffer)
  if #buffer.selections ~= 4 then return nil end
  local line1, col1, line2, col2 = buffer:get_selection()
  if line1 == line2 and col1 == 1 and col2 == 1 and buffer.lines[line1] == "\n" then return line1 end
end

---Tab or Shift+Tab when each caret is on an empty line: moves each caret one
---level deeper or shallower without an edit. Returns true when it applied.
---@param view core.textview
---@param outdent boolean
---@return boolean
function empty_line_indent.shift_level(view, outdent)
  local buffer = view.buffer
  local lines = {}
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 ~= line2 or col1 ~= 1 or col2 ~= 1 or buffer.lines[line1] ~= "\n" then return false end
    lines[#lines + 1] = line1
  end
  for _, line in ipairs(lines) do
    local indent = empty_line_indent.get(view, line)
    set_level(view, line, outdent and remove_level(buffer, indent) or indent .. buffer:get_indent_string(1))
  end
  core.log_quiet("Empty Line Indent moved %d caret(s) one level %s in %s",
    #lines, outdent and "out" or "in", buffer:get_name())
  return true
end

---Spaces or tabs typed when each caret is on an empty line: move each caret
---by that whitespace without an edit, as the cleanup would leave it.
---Returns true when it applied.
---@param view core.textview
---@param text string
---@return boolean
function empty_line_indent.type_whitespace(view, text)
  local buffer = view.buffer
  if config.keep_newline_whitespace or not text:find("^[\t ]+$") then return false end
  local lines = {}
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 ~= line2 or col1 ~= 1 or col2 ~= 1 or buffer.lines[line1] ~= "\n" then return false end
    lines[#lines + 1] = line1
  end
  for _, line in ipairs(lines) do
    set_level(view, line, empty_line_indent.get(view, line) .. text)
  end
  return true
end

---Line-start movement clears Shown Indentation at each empty-line caret.
---The line stays empty; the next edit starts at column 1.
---@param view core.textview
function empty_line_indent.move_to_start(view)
  local buffer = view.buffer
  local count = 0
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 == line2 and col1 == 1 and col2 == 1
    and buffer.lines[line1] == "\n" then
      set_level(view, line1, "")
      count = count + 1
    end
  end
  if count > 0 then
    core.log_quiet("Empty Line Indent moved %d caret(s) to the line start in %s", count, buffer:get_name())
  end
end

---Moves one character through Shown Indentation, without writing whitespace.
---At either edge, the caller continues normal text navigation.
function empty_line_indent.move_char(view, line, col, direction)
  if col ~= 1 or view.buffer.lines[line] ~= "\n" then return false end
  local indent = empty_line_indent.get(view, line)
  local position = chosen_position(view, line)
  local extent = position and position.extent or indent
  local length = #indent + direction
  if length < 0 or length > #extent then return false end
  set_level(view, line, extent:sub(1, length))
  return true
end

---A horizontal move into an empty line arrives at the corresponding edge.
---A collapsed text selection arrives at column 1, where its endpoint was.
function empty_line_indent.arrive(view, line, col, from_end)
  if col ~= 1 or view.buffer.lines[line] ~= "\n" then return end
  local position = chosen_position(view, line)
  local extent = position and position.extent or entry(view.buffer, line).indent
  set_level(view, line, from_end and extent or "")
end

---End on an empty line moves its caret to `block_indent` without an edit.
---Returns true when the caret is on an empty line.
---@param view core.textview
---@param block_indent string
---@return boolean
function empty_line_indent.end_at(view, block_indent)
  local buffer = view.buffer
  local line = single_empty_line_caret(buffer)
  if not line then return false end
  if empty_line_indent.get(view, line) ~= block_indent then set_level(view, line, block_indent) end
  return true
end

---Backspace on an empty line whose caret shows deeper than `block_indent`
---moves its caret to `block_indent` without an edit. Returns true when it
---applied; otherwise Backspace joins the line to the one above.
---@param view core.textview
---@param block_indent string
---@return boolean
function empty_line_indent.backspace(view, block_indent)
  local buffer = view.buffer
  local line = single_empty_line_caret(buffer)
  if not line then return false end
  local indent = empty_line_indent.get(view, line)
  if visual_width(buffer, indent) <= visual_width(buffer, block_indent) then return false end
  set_level(view, line, block_indent)
  return true
end

local function indent_width(view, indent)
  return visual_width(view.buffer, indent) * view:get_font():get_width(" ")
end

local function offset_for_indent(view, line, indent, reference)
  if indent == "" then return 0 end
  local lead = reference and view.buffer.lines[reference]:match("^[\t ]*")
  if lead and lead ~= "" then
    local columns = visual_width(view.buffer, indent)
    local lead_columns = visual_width(view.buffer, lead)
    -- Live Preview can compress indentation. Use the same scale for positions
    -- inside that indentation, so Left and pointer placement agree with drawing.
    local width = math.max(0, view:get_col_x_offset(reference, #lead + 1)
      - view:get_col_x_offset(line, 1))
    return width * math.min(columns / lead_columns, 1)
      + math.max(0, columns - lead_columns) * view:get_font():get_width(" ")
  end
  return indent_width(view, indent)
end

---Places an empty-line caret at the nearest position within its indentation.
---A pointer beyond that indentation stops at its end. Text selections stay real.
function empty_line_indent.place(view, line, col, x)
  if col ~= 1 or view.buffer.lines[line] ~= "\n" then return end
  local selections = view.buffer.selections
  local collapsed = false
  for i = 1, #selections, 4 do
    if selections[i] == line and selections[i + 1] == 1
    and selections[i + 2] == line and selections[i + 3] == 1 then
      collapsed = true
      break
    end
  end
  if not collapsed then return end
  local found = entry(view.buffer, line)
  local position = chosen_position(view, line)
  local extent = position and position.extent or found.indent
  local target = x - view:get_line_screen_position(line, 1)
  if target <= 0 then
    set_level(view, line, "")
    return
  end
  local low, high = 0, #extent
  while low < high do
    local middle = math.floor((low + high) / 2)
    local left = offset_for_indent(view, line, extent:sub(1, middle), found.reference)
    local right = offset_for_indent(view, line, extent:sub(1, middle + 1), found.reference)
    if target < (left + right) / 2 then high = middle else low = middle + 1 end
  end
  set_level(view, line, extent:sub(1, low))
end

---Returns how far right of column 1 a caret at `line`, `col` shows.
---Selection endpoints use real text positions, without Shown Indentation.
---@param view core.textview
---@param line integer
---@param col integer
---@return number
function empty_line_indent.caret_offset(view, line, col)
  if col ~= 1 or view.buffer.lines[line] ~= "\n" then return 0 end
  local selections = view.buffer.bound_selection_view == view
    and view.buffer.selections or view.selection_state.selections
  for i = 1, #selections, 4 do
    local line1, col1, line2, col2 = selections[i], selections[i + 1], selections[i + 2], selections[i + 3]
    if (line == line1 or line == line2) and (line1 ~= line2 or col1 ~= col2) then return 0 end
  end
  local found = entry(view.buffer, line)
  if not found then return 0 end
  return offset_for_indent(view, line, empty_line_indent.get(view, line), found.reference)
end

-- Collapsed carets on empty lines that show an indentation, one per line.
local function indented_empty_carets(view, chosen_only)
  local buffer = view.buffer
  local found, seen = {}, {}
  for idx, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 == line2 and col1 == col2 and col1 == 1
    and buffer.lines[line1] == "\n" and not seen[line1] then
      local indent = empty_line_indent.get(view, line1)
      if (indent ~= "" or chosen_only) and (not chosen_only or chosen_position(view, line1)) then
        seen[line1] = true
        found[#found + 1] = { idx = idx, line = line1, indent = indent }
      end
    end
  end
  return found
end

---Writes the shown indentation of each caret on an empty line. The next edit
---and this one undo together.
---@param view core.textview
---@param edit fun()
---@param chosen_only? boolean Enter: write chosen levels and carry a chosen margin
function empty_line_indent.write_then(view, edit, chosen_only)
  local buffer = view.buffer
  if view.can_edit and not view:can_edit("indent empty line") then return edit() end
  local carets = indented_empty_carets(view, chosen_only)
  if #carets == 0 then return edit() end
  local edits, final_by_idx = {}, {}
  for _, caret in ipairs(carets) do
    if caret.indent ~= "" then
      edits[#edits + 1] = { line1 = caret.line, col1 = 1, line2 = caret.line, col2 = 1, text = caret.indent, idx = caret.idx }
      final_by_idx[caret.idx] = "end"
    end
  end
  local undo_idx = buffer.undo_stack.idx
  if #edits > 0 then
    local selections, last_selection = buffer:selections_after_edits(edits, final_by_idx, buffer.last_selection)
    buffer:apply_edits(edits, {
      type = "insert", selections = selections, last_selection = last_selection, merge_cursors = false,
    })
    core.log_quiet("Empty Line Indent wrote %d indentation(s) in %s", #edits, buffer:get_name())
  end
  local revision = buffer.text_revision
  local result = edit()
  if chosen_only and buffer.text_revision ~= revision then
    -- Enter carries a chosen margin too. No whitespace was needed to record it.
    for _, caret in ipairs(carets) do
      if caret.indent == "" then
        local line, col, line2, col2 = buffer:get_selection_idx(caret.idx)
        if line == line2 and col == 1 and col2 == 1 and buffer.lines[line] == "\n" then
          set_level(view, line, "")
        end
      end
    end
  end
  buffer:join_undo_since(undo_idx)
  return result
end

-- Fills `caret_cols` with the column of each line's one collapsed caret, or
-- false for a line with any other selection end.
local function fill_caret_cols(buffer, caret_cols)
  for line in pairs(caret_cols) do caret_cols[line] = nil end
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 == line2 and col1 == col2 and caret_cols[line1] == nil then
      caret_cols[line1] = col1
    else
      caret_cols[line1], caret_cols[line2] = false, false
    end
  end
end

---Forgets chosen levels that no caret uses, then empties the lines that the
---user's edits left holding only whitespace: each line that no selection
---touches, and each line whose caret is at its end. That caret keeps its
---place, because its line's whitespace becomes its chosen level. The cleanup
---undoes with the edit before it. It waits while redo is available, so a
---caret move cannot clear redo.
---@param view core.textview
function empty_line_indent.update(view)
  local buffer = view.buffer
  forget_left_positions(view, buffer.selections)
  local state = states[buffer]
  if not state then return end
  local edited = state.edited
  if not next(edited) then return end
  local caret_cols = state.caret_cols or {}
  state.caret_cols = caret_cols
  fill_caret_cols(buffer, caret_cols)
  if config.keep_newline_whitespace then
    state.edited = {}
    return
  end
  if buffer.redo_stack.idx > 1 then return end
  if view.can_edit and not view:can_edit("clean empty line") then return end
  local edits, kept_levels = {}, {}
  for line in pairs(edited) do
    local text = buffer.lines[line]
    local col = caret_cols[line]
    if not whitespace_only(text) then
      edited[line] = nil
    elseif col == nil or col == #text then
      edited[line] = nil
      edits[#edits + 1] = { line1 = line, col1 = 1, line2 = line, col2 = #text, text = "" }
      if col then kept_levels[line] = text:sub(1, -2) end
    end
  end
  if #edits == 0 then return end
  for line, col in pairs(caret_cols) do
    local position = col == 1 and chosen_position(view, line)
    if position and buffer.lines[line] == "\n" then kept_levels[line] = position.indent end
  end
  table.sort(edits, function(a, b) return a.line1 < b.line1 end)
  local top = buffer.undo_stack[buffer.undo_stack.idx - 1]
  buffer:apply_edits(edits, {
    type = "empty-line-indent", merge_cursors = false,
    time = top and top.time, joins_previous = top ~= nil,
  })
  for line, indent in pairs(kept_levels) do
    if empty_line_indent.get(view, line) ~= indent then set_level(view, line, indent) end
  end
  core.log_quiet("Empty Line Indent emptied %d line(s) in %s", #edits, buffer:get_name())
end

-- Moves the edited lines through a text change. A changed line is no longer
-- known; a user edit adds each changed line that holds only whitespace.
Buffer.register_text_transaction_handler("empty-line-indent", function(buffer, transaction)
  local state = states[buffer]
  local view = core.active_view
  local user_edit = not skipped_change_types[transaction.type]
    and not config.keep_newline_whitespace and view and view.buffer == buffer
  if not user_edit and not (state and next(state.edited)) then return end
  state = state or state_for(buffer)
  local ranges = transaction.changed_ranges
  local moved = {}
  if ranges then
    for line in pairs(state.edited) do
      local shift, touched = 0, false
      for _, range in ipairs(ranges) do
        if line < range.old_line1 then break end
        if line <= range.old_line2 then
          touched = true
          break
        end
        shift = shift + range.line_delta
      end
      if not touched then moved[line + shift] = true end
    end
    if user_edit then
      for _, range in ipairs(ranges) do
        for line = range.new_line1, range.new_line2 do
          if whitespace_only(buffer.lines[line]) then moved[line] = true end
        end
      end
    end
  end
  state.edited = moved
end)

return empty_line_indent
