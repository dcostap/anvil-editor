-- Shown Indentation: an empty line holds no indentation, but a caret on it
-- shows where Enter at the end of the line above would put the caret.
-- Typing, Tab and paste write that indentation first. After an edit, a caret
-- line that holds only that indentation, with the caret at its end, becomes
-- empty again. The caret stays at the same place on the screen.
local core = require "core"
local config = require "core.config"
local intelligence = require "core.language_intelligence"
local Buffer = require "core.buffer"

local empty_line_indent = {}

local SCAN_LIMIT = 1000
local openers = { ["("] = true, ["["] = true, ["{"] = true }
-- Edits that the user did not type at the caret.
local skipped_change_types = {
  undo = true, redo = true, reload = true, recovery = true,
  ["empty-line-indent"] = true,
}

local cache = setmetatable({}, { __mode = "k" })

local function has_content(text)
  return text and text:find("[^\t \r\n]") ~= nil
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
  local change_id = buffer:get_change_id()
  local lines = cache[buffer]
  if not lines or lines.change_id ~= change_id or lines.syntax ~= buffer.syntax then
    lines = { change_id = change_id, syntax = buffer.syntax }
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

---Returns the indentation that a caret on `line` shows, or nil when the line
---has content. The line can hold whitespace; its whitespace does not count.
---@param buffer core.buffer
---@param line integer
---@return string?
function empty_line_indent.get(buffer, line)
  local found = entry(buffer, line)
  return found and found.indent
end

local function indent_width(view, indent)
  local _, indent_size = view.buffer:get_indent_info()
  local columns = 0
  for i = 1, #indent do
    if indent:byte(i) == 9 then
      columns = columns + indent_size - (columns % indent_size)
    else
      columns = columns + 1
    end
  end
  return columns * view:get_font():get_width(" ")
end

---Returns how far right of column 1 a caret at `line`, `col` shows.
---@param view core.textview
---@param line integer
---@param col integer
---@return number
function empty_line_indent.caret_offset(view, line, col)
  if col ~= 1 or view.buffer.lines[line] ~= "\n" then return 0 end
  local found = entry(view.buffer, line)
  if not found or found.indent == "" then return 0 end
  local indent, reference = found.indent, found.reference
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
local function indented_empty_carets(buffer)
  local found, seen = {}, {}
  for idx, line1, col1, line2, col2 in buffer:get_selections(true) do
    if line1 == line2 and col1 == col2 and col1 == 1
    and buffer.lines[line1] == "\n" and not seen[line1] then
      local indent = empty_line_indent.get(buffer, line1)
      if indent ~= "" then
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
function empty_line_indent.write_then(view, edit)
  local buffer = view.buffer
  if view.can_edit and not view:can_edit("indent empty line") then return edit() end
  local carets = indented_empty_carets(buffer)
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

---Empties each caret line that holds only its shown indentation, with the
---caret at its end. The cleanup undoes with the edit before it.
---@param view core.textview
function empty_line_indent.clean(view)
  local buffer = view.buffer
  if config.keep_newline_whitespace then return end
  if view.can_edit and not view:can_edit("clean empty line") then return end
  local edits, seen = {}, {}
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    local text = buffer.lines[line1]
    if line1 == line2 and col1 == col2 and not seen[line1]
    and text ~= "\n" and not has_content(text) and col1 == #text
    and empty_line_indent.get(buffer, line1) == text:sub(1, -2) then
      seen[line1] = true
      edits[#edits + 1] = { line1 = line1, col1 = 1, line2 = line1, col2 = col1, text = "" }
    end
  end
  if #edits == 0 then return end
  local top = buffer.undo_stack[buffer.undo_stack.idx - 1]
  buffer:apply_edits(edits, {
    type = "empty-line-indent", merge_cursors = false,
    time = top and top.time, joins_previous = true,
  })
  core.log_quiet("Empty Line Indent emptied %d line(s) in %s", #edits, buffer:get_name())
end

Buffer.register_text_transaction_handler("empty-line-indent", function(buffer, transaction)
  local view = core.active_view
  if not skipped_change_types[transaction.type] and view and view.buffer == buffer then
    buffer.empty_line_indent_due = true
  end
end)

return empty_line_indent
