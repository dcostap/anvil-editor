local markdown_model = require "core.markdown.model"

local selection = {}

local MAX_HISTORY = 32
local histories = setmetatable({}, { __mode = "k" })

local INLINE_TYPES = {
  code = true,
  comment = true,
  embed = true,
  emphasis = true,
  escape = true,
  hard_break = true,
  highlight = true,
  html = true,
  image = true,
  link = true,
  link_reference = true,
  math = true,
  strikethrough = true,
  strong = true,
  tag = true,
  wiki_link = true,
}

local function copy_list(values)
  local copy = {}
  for index = 1, #values do copy[index] = values[index] end
  return copy
end

local function same_list(left, right)
  if not left or not right or #left ~= #right then return false end
  for index = 1, #left do
    if left[index] ~= right[index] then return false end
  end
  return true
end

local function line_starts(buffer)
  local starts, offset = {}, 0
  for line = 1, #buffer.lines do
    starts[line] = offset
    offset = offset + #(buffer.lines[line] or "")
  end
  starts[#buffer.lines + 1] = offset
  return starts, offset
end

local function position_offset(starts, line, col)
  return (starts[line] or 0) + (col or 1) - 1
end

local function offset_position(buffer, starts, offset)
  local low, high = 1, #buffer.lines
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    if starts[middle] <= offset then low = middle else high = middle - 1 end
  end
  return buffer:sanitize_position(low, offset - starts[low] + 1)
end

local function add_candidate(candidates, seen, start_offset, end_offset, kind)
  if not start_offset or not end_offset or end_offset <= start_offset then return end
  local key = start_offset .. ":" .. end_offset
  if seen[key] then return end
  seen[key] = true
  candidates[#candidates + 1] = {
    start_offset = start_offset,
    end_offset = end_offset,
    kind = kind,
  }
end

local function range_offsets(range, starts)
  if not range then return nil end
  return range.start_byte or position_offset(starts, range.line1, range.col1),
    range.end_byte or position_offset(starts, range.line2, range.col2)
end

local function add_range(candidates, seen, range, starts, kind)
  local start_offset, end_offset = range_offsets(range, starts)
  add_candidate(candidates, seen, start_offset, end_offset, kind)
end

local function byte_is_word(byte)
  return byte and (byte >= 128
    or byte >= string.byte("0") and byte <= string.byte("9")
    or byte >= string.byte("A") and byte <= string.byte("Z")
    or byte >= string.byte("a") and byte <= string.byte("z")
    or byte == string.byte("_"))
end

local function add_word(candidates, seen, text, caret)
  if #text == 0 then return end
  local probe = caret + 1
  if not byte_is_word(text:byte(probe)) and probe > 1 and byte_is_word(text:byte(probe - 1)) then
    probe = probe - 1
  end
  if not byte_is_word(text:byte(probe)) then return end
  local first, last = probe, probe
  while first > 1 and byte_is_word(text:byte(first - 1)) do first = first - 1 end
  while last < #text and byte_is_word(text:byte(last + 1)) do last = last + 1 end
  add_candidate(candidates, seen, first - 1, last, "word")
end

local function add_block_source(candidates, seen, text, node, starts)
  local range = node.source
  if not range then return end
  local start_offset, end_offset = range_offsets(range, starts)
  local source = text:sub(start_offset + 1, end_offset)
  local trailing_pattern = node.type == "table_cell" and "%s*$" or "[\r\n]*$"
  local trailing = #(source:match(trailing_pattern) or "")
  local leading = node.type == "table_cell" and #(source:match("^%s*") or "") or 0
  add_candidate(candidates, seen, start_offset + leading, end_offset - trailing, node.type)
end

local function add_fenced_code_content(candidates, seen, buffer, node, starts)
  if node.type ~= "code_fenced" or not node.source then return end
  local first_line = node.source.line1
  local opening = buffer.lines[first_line] or ""
  local marker = opening:match("^%s*(```+)") or opening:match("^%s*(~~~+)")
  if not marker then return end
  local closing_line
  for line = first_line + 1, math.min(node.source.line2, #buffer.lines) do
    local text = buffer.lines[line] or ""
    local close = text:match("^%s*(`+)%s*$") or text:match("^%s*(~+)%s*$")
    if close and close:sub(1, 1) == marker:sub(1, 1) and #close >= #marker then
      closing_line = line
      break
    end
  end
  if not closing_line or closing_line <= first_line + 1 then return end
  local final_content_line = buffer.lines[closing_line - 1] or ""
  local final_content = final_content_line:gsub("[\r\n]+$", "")
  add_candidate(candidates, seen, starts[first_line + 1],
    starts[closing_line - 1] + #final_content, "code_fenced_content")
end

local function add_inline_content(candidates, seen, node, starts)
  for _, range in ipairs(node.content_ranges or {}) do
    add_range(candidates, seen, range, starts, node.type .. "_content")
  end

  local source_start, source_end = range_offsets(node.source, starts)
  local markers = node.marker_ranges or {}
  if #markers < 2 then return end
  local content_start, content_end = source_start, source_end
  local changed = true
  while changed do
    changed = false
    for _, marker in ipairs(markers) do
      local marker_start, marker_end = range_offsets(marker, starts)
      if marker_start == content_start and marker_end > content_start then
        content_start, changed = marker_end, true
      end
    end
  end
  changed = true
  while changed do
    changed = false
    for _, marker in ipairs(markers) do
      local marker_start, marker_end = range_offsets(marker, starts)
      if marker_end == content_end and marker_start < content_end then
        content_end, changed = marker_start, true
      end
    end
  end
  if content_start > source_start and content_end < source_end then
    add_candidate(candidates, seen, content_start, content_end, node.type .. "_content")
  end
end

local function heading_level(buffer, line)
  local text = buffer.lines[line] or ""
  local marks = text:match("^%s*(#+)%s+")
  if marks and #marks <= 6 then return #marks end
  local underline = buffer.lines[line + 1] or ""
  if underline:match("^%s*=+%s*$") then return 1 end
  if underline:match("^%s*%-+%s*$") then return 2 end
end

local function add_sections(candidates, seen, buffer, starts, total)
  local headings = {}
  local line, fence_char, fence_length = 1
  while line <= #buffer.lines do
    local text = buffer.lines[line] or ""
    if fence_char then
      local close = text:match("^%s*(`+)%s*$") or text:match("^%s*(~+)%s*$")
      if close and close:sub(1, 1) == fence_char and #close >= fence_length then
        fence_char, fence_length = nil, nil
      end
    else
      local fence = text:match("^%s*(```+)") or text:match("^%s*(~~~+)")
      if fence then
        fence_char, fence_length = fence:sub(1, 1), #fence
      else
        local level = heading_level(buffer, line)
        if level then
          headings[#headings + 1] = { line = line, level = level }
          if not text:match("^%s*#") then line = line + 1 end
        end
      end
    end
    line = line + 1
  end
  for index, heading in ipairs(headings) do
    local end_offset = total
    for next_index = index + 1, #headings do
      if headings[next_index].level <= heading.level then
        end_offset = starts[headings[next_index].line]
        break
      end
    end
    add_candidate(candidates, seen, starts[heading.line], end_offset, "section")
  end
end

local function strictly_contains(candidate, start_offset, end_offset)
  return candidate.start_offset <= start_offset and candidate.end_offset >= end_offset
    and (candidate.start_offset < start_offset or candidate.end_offset > end_offset)
end

local function candidate_order(left, right)
  local left_size = left.end_offset - left.start_offset
  local right_size = right.end_offset - right.start_offset
  if left_size ~= right_size then return left_size < right_size end
  if left.start_offset ~= right.start_offset then return left.start_offset > right.start_offset end
  return left.kind < right.kind
end

local function paragraph_container_ranges(nodes, starts)
  local ranges = {}
  for _, node in ipairs(nodes) do
    if node.type == "list_item" or node.type == "quote" then
      local start_offset, end_offset = range_offsets(node.source, starts)
      ranges[#ranges + 1] = { start_offset, end_offset }
    end
  end
  return ranges
end

local function paragraph_is_in_container(node, containers, starts)
  if node.type ~= "paragraph" then return false end
  local start_offset, end_offset = range_offsets(node.source, starts)
  for _, container in ipairs(containers) do
    if container[1] <= start_offset and container[2] >= end_offset then return true end
  end
  return false
end

local function is_redundant_strong_emphasis(node, nodes, starts, text)
  if node.type ~= "emphasis" then return false end
  local start_offset, end_offset = range_offsets(node.source, starts)
  for _, parent in ipairs(nodes) do
    if parent.type == "strong" then
      local parent_start, parent_end = range_offsets(parent.source, starts)
      if parent_start + 1 == start_offset and parent_end - 1 == end_offset
        and text:sub(parent_start + 1, parent_start + 2) == "**"
        and text:sub(parent_end - 1, parent_end) == "**"
      then
        return true
      end
    end
  end
  return false
end

local PAIR_CONTAINERS = {
  paragraph = true, heading = true, table_cell = true,
  code = true, code_fenced = true, code_indented = true,
}

local LINK_TYPES = {
  link = true, image = true, wiki_link = true, embed = true,
}

local function add_pairs(candidates, seen, text, nodes, starts)
  local opens = { ["("] = ")", ["["] = "]", ["{"] = "}" }
  local closes = { [")"] = true, ["]"] = true, ["}"] = true }
  local links, code = {}, {}
  for _, node in ipairs(nodes) do
    if node.source and (LINK_TYPES[node.type] or node.type == "code") then
      local first, last = range_offsets(node.source, starts)
      local ranges = LINK_TYPES[node.type] and links or code
      ranges[#ranges + 1] = { first, last, node = node }
    end
  end

  local function is_link_marker(first, last)
    for _, link in ipairs(links) do
      if first >= link[1] and last <= link[2] then
        -- Keep Markdown link syntax whole. Nested pairs in its text remain scopes.
        for _, range in ipairs(link.node.content_ranges or {}) do
          local a, b = range_offsets(range, starts)
          if first >= a and last <= b and a > link[1] and b < link[2] then
            return false
          end
        end
        return true
      end
    end
    return false
  end

  for _, node in ipairs(nodes) do
    if node.source and PAIR_CONTAINERS[node.type] then
      local first, last = range_offsets(node.source, starts)
      local stack = {}
      local pos = first
      while pos < last do
        local skip_to
        if node.type ~= "code" then
          for _, range in ipairs(code) do
            if pos == range[1] then skip_to = range[2]; break end
          end
        end
        local ch = text:sub(pos + 1, pos + 1)
        if skip_to then
          pos = skip_to
        elseif ch == "\\" then
          pos = pos + 2
        else
          if opens[ch] then
            stack[#stack + 1] = { close = opens[ch], offset = pos }
          elseif closes[ch] then
            local opening = stack[#stack]
            if opening and opening.close == ch then
              stack[#stack] = nil
              if not is_link_marker(opening.offset, pos + 1) then
                add_candidate(candidates, seen, opening.offset + 1, pos, "pair_content")
                add_candidate(candidates, seen, opening.offset, pos + 1, "pair")
              end
            else
              -- A crossed or unmatched closer cannot complete an enclosing pair.
              stack = {}
            end
          end
          pos = pos + 1
        end
      end
    end
  end
end

local function candidates_for(buffer, line1, col1, line2, col2, blocks_only)
  local instance = markdown_model.peek(buffer)
  if not instance or instance.status ~= "ready"
    or instance.published_revision ~= buffer.text_revision
  then
    return nil, "not-ready"
  end

  local nodes, reason = instance:nodes_for_lines(line1, line2, { limit = 4096 })
  if not nodes or reason == "limit" then return nil, reason or "unavailable" end

  local starts, total = line_starts(buffer)
  local text = table.concat(buffer.lines)
  local start_offset = position_offset(starts, line1, col1)
  local end_offset = position_offset(starts, line2, col2)
  local candidates, seen = {}, {}

  if not blocks_only and start_offset == end_offset then add_word(candidates, seen, text, start_offset) end

  add_pairs(candidates, seen, text, nodes, starts)

  local containers = paragraph_container_ranges(nodes, starts)
  for _, node in ipairs(nodes) do
    if node.source and not paragraph_is_in_container(node, containers, starts)
      and not is_redundant_strong_emphasis(node, nodes, starts, text)
    then
      local inline = INLINE_TYPES[node.type] == true
      local include_inline = not blocks_only or node.type == "code"
      if include_inline and inline then add_inline_content(candidates, seen, node, starts) end
      if include_inline or not inline then
        if inline then
          add_range(candidates, seen, node.source, starts, node.type)
        else
          add_fenced_code_content(candidates, seen, buffer, node, starts)
          add_block_source(candidates, seen, text, node, starts)
        end
      end
    end
  end

  add_sections(candidates, seen, buffer, starts, total)
  add_candidate(candidates, seen, 0, total, "document")
  table.sort(candidates, candidate_order)
  return candidates, nil, starts, start_offset, end_offset
end

local function push_history(buffer)
  local history = histories[buffer] or {}
  histories[buffer] = history
  history[#history + 1] = {
    revision = buffer.text_revision,
    selections = copy_list(buffer.selections or {}),
    last_selection = buffer.last_selection,
  }
  if #history > MAX_HISTORY then table.remove(history, 1) end
  return history[#history]
end

function selection.expand(view, blocks_only)
  local buffer = view and view.buffer
  if not buffer or view.__markdown_live_attached ~= true then return false, "not-live" end

  local next_selections = {}
  for index, caret_line, caret_col, anchor_line, anchor_col in buffer:get_selections(false) do
    local line1, col1, line2, col2 = buffer:get_selection_idx(index, true)
    local candidates, reason, starts, start_offset, end_offset =
      candidates_for(buffer, line1, col1, line2, col2, blocks_only)
    if not candidates then return false, reason end
    local chosen
    for _, candidate in ipairs(candidates) do
      if strictly_contains(candidate, start_offset, end_offset) then
        chosen = candidate
        break
      end
    end
    if not chosen then return false, "no-larger-node" end

    local new_line1, new_col1 = offset_position(buffer, starts, chosen.start_offset)
    local new_line2, new_col2 = offset_position(buffer, starts, chosen.end_offset)
    local reversed = caret_line > anchor_line or caret_line == anchor_line and caret_col > anchor_col
    if reversed then
      next_selections[#next_selections + 1] = new_line2
      next_selections[#next_selections + 1] = new_col2
      next_selections[#next_selections + 1] = new_line1
      next_selections[#next_selections + 1] = new_col1
    else
      next_selections[#next_selections + 1] = new_line1
      next_selections[#next_selections + 1] = new_col1
      next_selections[#next_selections + 1] = new_line2
      next_selections[#next_selections + 1] = new_col2
    end
  end

  local history = push_history(buffer)
  buffer:set_selection_list(next_selections, buffer.last_selection,
    { sanitized = true, merge_cursors = true })
  history.applied = copy_list(buffer.selections or {})
  return true
end

function selection.shrink(view)
  local buffer = view and view.buffer
  local history = buffer and histories[buffer]
  if not buffer or view.__markdown_live_attached ~= true or not history or #history == 0 then
    return false, "no-history"
  end
  local previous = history[#history]
  if previous.revision ~= buffer.text_revision
    or not same_list(previous.applied, buffer.selections)
  then
    histories[buffer] = nil
    return false, "stale-history"
  end
  table.remove(history)
  buffer:set_selection_list(previous.selections, previous.last_selection,
    { sanitized = true, merge_cursors = true })
  return true
end

function selection.move_to_boundary(view)
  local buffer = view and view.buffer
  if not buffer or view.__markdown_live_attached ~= true then return false, "not-live" end
  local line, col = buffer:get_selection()
  local candidates, reason, starts, caret = candidates_for(buffer, line, col, line, col, true)
  if not candidates then return false, reason end
  for _, candidate in ipairs(candidates) do
    -- Pair navigation lands on delimiters, like ordinary bracket navigation.
    -- Other scopes use the same start/end positions as block selection.
    local first = candidate.start_offset
    local last = candidate.end_offset - (candidate.kind == "pair" and 1 or 0)
    if candidate.kind ~= "pair_content" and first <= caret and caret <= last then
      local target = caret == first and last or first
      local next_line, next_col = offset_position(buffer, starts, target)
      local panes = require "core.panes"
      local pane = panes.pane_for_view(view)
      if pane then panes.record_location(pane) end
      buffer:set_selection(next_line, next_col)
      view:scroll_to_make_visible(next_line, next_col)
      if pane then panes.record_location(pane) end
      require("core").log_quiet("Markdown scope navigation: %s at %d:%d",
        candidate.kind, next_line, next_col)
      return true
    end
  end
  return false, "no-scope"
end

return selection
