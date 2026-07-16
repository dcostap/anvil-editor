-- mod-version:3
-- First-party selection surrounding behavior.

local core = require "core"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local translate = require "core.doc.translate"

local delimiters = {
  ["("] = { close = ")", block = true },
  ["["] = { close = "]", block = true },
  ["{"] = { close = "}", block = true, spaced = true },
  ["<"] = { close = ">" },
  ["\""] = { close = "\"" },
  ["'"] = { close = "'" },
}

local function line_body(text)
  return tostring(text or ""):gsub("\n$", "")
end

local function content_bounds(text)
  local first = text:find("%S")
  if not first then return nil end
  local _, last = text:find(".*%S")
  return first, last
end

local function leading_whitespace(text)
  return text:match("^[\t ]*") or ""
end

local function common_indent(lines)
  local result
  for _, text in ipairs(lines) do
    if text:find("%S") then
      local indent = leading_whitespace(text)
      if result == nil then
        result = indent
      else
        local count = math.min(#result, #indent)
        local i = 1
        while i <= count and result:sub(i, i) == indent:sub(i, i) do i = i + 1 end
        result = result:sub(1, i - 1)
      end
    end
  end
  return result or leading_whitespace(lines[1] or "")
end

local function block_action(doc, idx, line1, col1, line2, col2, swapped, opener, closer)
  if line1 >= line2 then return nil end

  local content_line2 = line2
  local ends_at_next_line = col2 == 1
  if ends_at_next_line then content_line2 = content_line2 - 1 end
  if content_line2 < line1 then return nil end

  local first_body = line_body(doc.lines[line1])
  local last_body = line_body(doc.lines[content_line2])
  local first_nonspace = content_bounds(first_body)
  local _, last_nonspace = content_bounds(last_body)
  if first_nonspace and col1 > first_nonspace then return nil end
  if not ends_at_next_line and last_nonspace and col2 <= last_nonspace then return nil end

  local bodies = {}
  for line = line1, content_line2 do
    bodies[#bodies + 1] = line_body(doc.lines[line])
  end

  local base = common_indent(bodies)
  local inner = doc:get_indent_string(1)
  local replacement_lines = { base .. opener }
  local selected_start
  local selected_end
  local running_offset = #replacement_lines[1] + 1

  for _, body in ipairs(bodies) do
    local relative = body:sub(1, #base) == base and body:sub(#base + 1) or body
    local transformed = body:find("%S") and (base .. inner .. relative) or ""
    replacement_lines[#replacement_lines + 1] = transformed

    local first, last = content_bounds(transformed)
    if first then
      selected_start = selected_start or (running_offset + first - 1)
      selected_end = running_offset + last
    end
    running_offset = running_offset + #transformed + 1
  end

  replacement_lines[#replacement_lines + 1] = base .. closer
  local has_following_line = content_line2 < #doc.lines
  local replacement = table.concat(replacement_lines, "\n") .. (has_following_line and "\n" or "")
  if not selected_start then
    selected_start = #replacement_lines[1] + 1
    selected_end = selected_start
  end

  local edit_line2, edit_col2
  if has_following_line then
    edit_line2, edit_col2 = content_line2 + 1, 1
  else
    edit_line2, edit_col2 = content_line2, #doc.lines[content_line2]
  end

  return {
    edit = {
      line1 = line1,
      col1 = 1,
      line2 = edit_line2,
      col2 = edit_col2,
      text = replacement,
      idx = idx,
    },
    first = swapped and selected_end or selected_start,
    second = swapped and selected_start or selected_end,
  }
end

local function surround_action(doc, idx, line1, col1, line2, col2, swapped, opener, delimiter)
  if delimiter.block then
    local action = block_action(doc, idx, line1, col1, line2, col2, swapped, opener, delimiter.close)
    if action then return action end
  end

  local selected = doc:get_text(line1, col1, line2, col2)
  local prefix = delimiter.spaced and (opener .. " ") or opener
  local suffix = delimiter.spaced and (" " .. delimiter.close) or delimiter.close
  local selection_start = #prefix
  local selection_end = selection_start + #selected
  return {
    edit = {
      line1 = line1,
      col1 = col1,
      line2 = line2,
      col2 = col2,
      text = prefix .. selected .. suffix,
      idx = idx,
    },
    first = swapped and selection_end or selection_start,
    second = swapped and selection_start or selection_end,
  }
end

local function collapsed_action(doc, idx, line, col, opener)
  local line2, col2 = line, col
  if doc.overwrite and col < #doc:get_utf8_line(line) then
    line2, col2 = translate.next_char(doc, line, col)
  end
  return {
    edit = {
      line1 = line,
      col1 = col,
      line2 = line2,
      col2 = col2,
      text = opener,
      idx = idx,
    },
    first = #opener,
    second = #opener,
  }
end

local function apply_surround(view, opener, delimiter)
  local doc = view.doc
  local actions = {}
  local edits = {}
  local has_selection = false

  for idx, line1, col1, line2, col2, swapped in doc:get_selections(true, true) do
    local action
    if line1 ~= line2 or col1 ~= col2 then
      has_selection = true
      action = surround_action(doc, idx, line1, col1, line2, col2, swapped, opener, delimiter)
    else
      action = collapsed_action(doc, idx, line1, col1, opener)
    end
    actions[idx] = action
    edits[#edits + 1] = action.edit
  end
  if not has_selection then return nil end

  local normalized = doc:plan_edits(edits)
  for i = 2, #normalized do
    local previous, current = normalized[i - 1], normalized[i]
    if previous.end_offset > current.start_offset
    or (previous.start_offset == previous.end_offset
      and current.start_offset == current.end_offset
      and previous.start_offset == current.start_offset) then
      core.log_quiet("Selection surround skipped for %s because selections overlap", doc:get_name())
      return nil
    end
  end

  local ranges = {}
  for idx, action in pairs(actions) do ranges[idx] = { action.first, action.second } end
  local selections, last_selection = doc:selection_ranges_after_edits(
    normalized,
    ranges,
    doc.last_selection,
    { normalized = true }
  )

  local result = doc:apply_edits(edits, {
    type = "insert",
    selections = selections,
    last_selection = last_selection,
    merge_cursors = false,
  })
  linewrapping.notify_doc_text_input(doc, result)
  if result and result.changed then
    core.log_quiet("Selection surround %s in %s across %d selection(s)", opener, doc:get_name(), #edits)
  end
  return result
end

local original_on_text_input = DocView.__selection_surround_original_on_text_input or DocView.on_text_input
DocView.__selection_surround_original_on_text_input = original_on_text_input

function DocView:on_text_input(text)
  local delimiter = delimiters[text]
  if not delimiter or not self.doc or not self.doc:has_any_selection() then
    return original_on_text_input(self, text)
  end
  if not self:can_edit("text input", { warn = true, text = text }) then return false end
  self.doc:clear_search_selections()
  return apply_surround(self, text, delimiter) or original_on_text_input(self, text)
end

return {}
