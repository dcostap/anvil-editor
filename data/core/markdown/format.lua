local core = require "core"

-- Markdown block formats that a line prefix makes: headings, lists and quotes.
-- Each change edits only the prefix, so the line's text and its carets stay in place.
local format = {}

local function line_text(buffer, line)
  return buffer.lines[line]:gsub("\n$", "")
end

-- The lines that the selections cover. A selection that ends at the start of a line does not cover that line.
local function selected_lines(buffer)
  local lines, seen = {}, {}
  for _, line1, _, line2, col2 in buffer:get_selections(true) do
    if line2 > line1 and col2 == 1 then line2 = line2 - 1 end
    for line = line1, line2 do
      if not seen[line] then
        seen[line] = true
        lines[#lines + 1] = line
      end
    end
  end
  table.sort(lines)
  return lines
end

-- The list prefix of a line: its indent, its kind, its length and, for a task, its mark.
local function list_prefix(text)
  local indent, rest = text:match("^([ \t]*)(.*)$")
  local marker = rest:match("^[%-%*%+]%s+%[[ xX]%]%s+") or rest:match("^[%-%*%+]%s+%[[ xX]%]$")
  if marker then return indent, "task", #indent + #marker, marker:match("%[([ xX])%]") end
  marker = rest:match("^[%-%*%+]%s+")
  if marker then return indent, "bullet", #indent + #marker end
  marker = rest:match("^%d+[.)]%s+")
  if marker then return indent, "numbered", #indent + #marker end
  return indent, nil, #indent
end

local function heading_prefix(text)
  local marks = text:match("^(#+)%s") or text:match("^(#+)$")
  if marks and #marks <= 6 then
    return #marks, #(text:match("^#+%s*"))
  end
  return 0, 0
end

-- Replace the prefix of each changed line, and keep each caret on the same text.
local function apply(view, changes, reason)
  local buffer = view.buffer
  local by_line, edits = {}, {}
  for _, change in ipairs(changes) do
    if line_text(buffer, change.line):sub(1, change.old_len) ~= change.prefix then
      by_line[change.line] = change
      edits[#edits + 1] = {
        line1 = change.line, col1 = 1, line2 = change.line, col2 = change.old_len + 1, text = change.prefix,
      }
    end
  end
  if #edits == 0 then return false end
  local selections = {}
  for index = 1, #buffer.selections, 2 do
    local line, col = buffer.selections[index], buffer.selections[index + 1]
    local change = by_line[line]
    if change then
      col = col > change.old_len + 1 and col + #change.prefix - change.old_len or #change.prefix + 1
    end
    selections[index], selections[index + 1] = line, col
  end
  -- A format is its own undo step, apart from the typing before it.
  buffer:apply_edits(edits, { selections = selections, merge_cursors = false, merge_undo = false })
  core.log_quiet("Markdown format %s changed %d line(s) in %s", reason, #edits, buffer:get_name())
  return true
end

---Make each selected line a heading of `level`. A line that already has that level becomes Normal Text.
---Level 0 makes Normal Text.
---@param view core.editor
---@param level integer
function format.heading(view, level)
  local buffer = view.buffer
  local lines = selected_lines(buffer)
  local all_at_level = level > 0
  for _, line in ipairs(lines) do
    if heading_prefix(line_text(buffer, line)) ~= level then all_at_level = false end
  end
  local prefix = (level > 0 and not all_at_level) and string.rep("#", level) .. " " or ""
  local changes = {}
  for _, line in ipairs(lines) do
    local _, old_len = heading_prefix(line_text(buffer, line))
    changes[#changes + 1] = { line = line, old_len = old_len, prefix = prefix }
  end
  return apply(view, changes, "heading " .. level)
end

-- Blank lines between selected lines keep their text. A single blank line gets the format.
local function formatted_lines(buffer)
  local lines = selected_lines(buffer)
  if #lines == 1 then return lines end
  local result = {}
  for _, line in ipairs(lines) do
    if line_text(buffer, line):find("%S") then result[#result + 1] = line end
  end
  return result
end

---Make the selected lines a list of `kind`: "bullet", "numbered" or "task".
---When all of them are already that kind, they become plain lines.
---@param view core.editor
---@param kind "bullet"|"numbered"|"task"
function format.list(view, kind)
  local buffer = view.buffer
  local lines = formatted_lines(buffer)
  local all_kind = #lines > 0
  for _, line in ipairs(lines) do
    local _, current = list_prefix(line_text(buffer, line))
    if current ~= kind then all_kind = false end
  end
  local changes = {}
  for number, line in ipairs(lines) do
    local indent, _, old_len, mark = list_prefix(line_text(buffer, line))
    local prefix = indent
    if not all_kind then
      if kind == "bullet" then
        prefix = indent .. "- "
      elseif kind == "numbered" then
        prefix = indent .. number .. ". "
      else
        prefix = indent .. "- [" .. (mark or " ") .. "] "
      end
    end
    changes[#changes + 1] = { line = line, old_len = old_len, prefix = prefix }
  end
  return apply(view, changes, kind .. " list")
end

---Quote the selected lines. When all of them are already quoted, remove one quote level.
---@param view core.editor
function format.quote(view)
  local buffer = view.buffer
  local lines = formatted_lines(buffer)
  local all_quoted = #lines > 0
  for _, line in ipairs(lines) do
    if not line_text(buffer, line):find("^>") then all_quoted = false end
  end
  local changes = {}
  for _, line in ipairs(lines) do
    local text = line_text(buffer, line)
    if all_quoted then
      changes[#changes + 1] = { line = line, old_len = #text:match("^>%s?"), prefix = "" }
    elseif not text:find("^>") then
      changes[#changes + 1] = { line = line, old_len = 0, prefix = "> " }
    end
  end
  return apply(view, changes, "quote")
end

---Make each selection a link. Selected text becomes the label and the caret goes to the address.
---A selected address becomes the address and the caret goes to the label.
---@param view core.editor
function format.link(view)
  local buffer = view.buffer
  local edits, ranges = {}, {}
  for idx, line1, col1, line2, col2 in buffer:get_selections(true) do
    local text = buffer:get_text(line1, col1, line2, col2)
    local new_text, caret
    if text:find("^%a[%w+.-]*://%S+$") then
      new_text, caret = "[](" .. text .. ")", 1
    else
      new_text = "[" .. text .. "]()"
      caret = text == "" and 1 or #new_text - 1
    end
    edits[#edits + 1] = { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = new_text, idx = idx }
    ranges[idx] = { caret, caret }
  end
  local normalized = buffer:plan_edits(edits)
  local selections, last_selection = buffer:selection_ranges_after_edits(
    normalized, ranges, buffer.last_selection, { normalized = true }
  )
  buffer:apply_edits(edits, {
    selections = selections, last_selection = last_selection, merge_cursors = false, merge_undo = false,
  })
  core.log_quiet("Markdown format link changed %d selection(s) in %s", #edits, buffer:get_name())
  return true
end

return format
