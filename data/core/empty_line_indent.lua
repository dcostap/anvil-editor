-- Shown Indentation: an empty line holds no indentation, but a caret on it
-- shows where Enter at the end of the line above would put the caret.
-- Tab, Shift+Tab, End and Backspace change the level of that caret without an
-- edit, until the caret leaves the line. Typing and paste write the
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
-- For each Buffer: `levels` maps an empty line to the indentation that the
-- user chose for its caret, valid for one text revision. `edited` holds the
-- lines that the user's edits left holding only whitespace.
local states = setmetatable({}, { __mode = "k" })

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
  if type(intelligence.newline_continuation(buffer, line + 1, context)) == "string" then
    -- A blank line ends a Markdown list or quote, so it starts at the margin.
    return is_markdown(buffer) and "" or lead
  end
  local indent = intelligence.indent_for_line(buffer, line + 1, context)
  return type(indent) == "string" and indent or lead
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
  local reference
  for previous = line - 1, math.max(1, line - SCAN_LIMIT), -1 do
    if has_content(buffer.lines[previous]) then
      reference = previous
      break
    end
  end
  found = { indent = reference and newline_indent(buffer, reference) or "", reference = reference }
  lines[line] = found
  return found
end

local function chosen_level(buffer, line)
  local state = states[buffer]
  local levels = state and state.levels
  return levels and state.levels_revision == buffer.text_revision and levels[line]
end

---Returns the indentation that a caret on `line` shows, or nil when the line
---has content. The line can hold whitespace; its whitespace does not count.
---@param buffer core.buffer
---@param line integer
---@return string?
function empty_line_indent.get(buffer, line)
  local found = entry(buffer, line)
  if not found then return nil end
  return chosen_level(buffer, line) or found.indent
end

local function set_level(buffer, line, indent)
  local state = state_for(buffer)
  local revision = buffer.text_revision
  if state.levels_revision ~= revision then
    state.levels, state.levels_revision = {}, revision
  end
  state.levels[line] = indent
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
---@param buffer core.buffer
---@param outdent boolean
---@return boolean
function empty_line_indent.shift_level(buffer, outdent)
  local lines = {}
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 ~= line2 or col1 ~= 1 or col2 ~= 1 or buffer.lines[line1] ~= "\n" then return false end
    lines[#lines + 1] = line1
  end
  for _, line in ipairs(lines) do
    local indent = empty_line_indent.get(buffer, line)
    set_level(buffer, line, outdent and remove_level(buffer, indent) or indent .. buffer:get_indent_string(1))
  end
  core.log_quiet("Empty Line Indent moved %d caret(s) one level %s in %s",
    #lines, outdent and "out" or "in", buffer:get_name())
  return true
end

---End on an empty line moves its caret to `block_indent` without an edit.
---Returns true when the caret is on an empty line.
---@param buffer core.buffer
---@param block_indent string
---@return boolean
function empty_line_indent.end_at(buffer, block_indent)
  local line = single_empty_line_caret(buffer)
  if not line then return false end
  if empty_line_indent.get(buffer, line) ~= block_indent then set_level(buffer, line, block_indent) end
  return true
end

---Backspace on an empty line whose caret shows deeper than `block_indent`
---moves its caret to `block_indent` without an edit. Returns true when it
---applied; otherwise Backspace joins the line to the one above.
---@param buffer core.buffer
---@param block_indent string
---@return boolean
function empty_line_indent.backspace(buffer, block_indent)
  local line = single_empty_line_caret(buffer)
  if not line then return false end
  local indent = empty_line_indent.get(buffer, line)
  if visual_width(buffer, indent) <= visual_width(buffer, block_indent) then return false end
  set_level(buffer, line, block_indent)
  return true
end

local function indent_width(view, indent)
  return visual_width(view.buffer, indent) * view:get_font():get_width(" ")
end

---Returns how far right of column 1 a caret at `line`, `col` shows.
---@param view core.textview
---@param line integer
---@param col integer
---@return number
function empty_line_indent.caret_offset(view, line, col)
  if col ~= 1 or view.buffer.lines[line] ~= "\n" then return 0 end
  local found = entry(view.buffer, line)
  if not found then return 0 end
  local indent, reference = empty_line_indent.get(view.buffer, line), found.reference
  if indent == "" then return 0 end
  local lead = view.buffer.lines[reference]:match("^[\t ]*")
  -- Measure on the line above, so the caret lines up with its text in any
  -- layout, such as Markdown Live Preview.
  if indent:sub(1, #lead) == lead then
    return view:get_col_x_offset(reference, #lead + 1)
      + indent_width(view, indent:sub(#lead + 1))
      - view:get_col_x_offset(line, 1)
  end
  return indent_width(view, indent)
end

-- Collapsed carets on empty lines that show an indentation, one per line.
local function indented_empty_carets(buffer, chosen_only)
  local found, seen = {}, {}
  for idx, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 == line2 and col1 == col2 and col1 == 1
    and buffer.lines[line1] == "\n" and not seen[line1] then
      local indent = empty_line_indent.get(buffer, line1)
      if indent ~= "" and (not chosen_only or chosen_level(buffer, line1)) then
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
---@param chosen_only? boolean Write only levels that the user chose
function empty_line_indent.write_then(view, edit, chosen_only)
  local buffer = view.buffer
  if view.can_edit and not view:can_edit("indent empty line") then return edit() end
  local carets = indented_empty_carets(buffer, chosen_only)
  if #carets == 0 then return edit() end
  local edits, final_by_idx = {}, {}
  for _, caret in ipairs(carets) do
    edits[#edits + 1] = { line1 = caret.line, col1 = 1, line2 = caret.line, col2 = 1, text = caret.indent, idx = caret.idx }
    final_by_idx[caret.idx] = "end"
  end
  local selections, last_selection = buffer:selections_after_edits(edits, final_by_idx, buffer.last_selection)
  local undo_idx = buffer.undo_stack.idx
  buffer:apply_edits(edits, {
    type = "insert", selections = selections, last_selection = last_selection, merge_cursors = false,
  })
  core.log_quiet("Empty Line Indent wrote %d indentation(s) in %s", #carets, buffer:get_name())
  local result = edit()
  buffer:join_undo_since(undo_idx)
  return result
end

-- Forgets the chosen levels of lines that no caret is on.
local function drop_left_levels(buffer, state, caret_cols)
  local levels = state.levels
  if not levels or not next(levels) then return end
  if state.levels_revision ~= buffer.text_revision then
    state.levels = nil
    return
  end
  for line in pairs(levels) do
    if caret_cols[line] ~= 1 then levels[line] = nil end
  end
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
  local state = states[buffer]
  if not state then return end
  local edited, levels = state.edited, state.levels
  if not next(edited) and not (levels and next(levels)) then return end
  local caret_cols = state.caret_cols or {}
  state.caret_cols = caret_cols
  fill_caret_cols(buffer, caret_cols)
  drop_left_levels(buffer, state, caret_cols)
  if not next(edited) then return end
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
  table.sort(edits, function(a, b) return a.line1 < b.line1 end)
  local top = buffer.undo_stack[buffer.undo_stack.idx - 1]
  buffer:apply_edits(edits, {
    type = "empty-line-indent", merge_cursors = false,
    time = top and top.time, joins_previous = top ~= nil,
  })
  for line, indent in pairs(kept_levels) do
    if empty_line_indent.get(buffer, line) ~= indent then set_level(buffer, line, indent) end
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
