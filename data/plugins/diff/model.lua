local common = require "core.common"
local M = {}

local function max_line(lines)
  return math.max(1, #(lines or {}))
end

local function trim_line(line)
  local content, ending = line, ""
  if line:sub(-2) == "\r\n" then
    content, ending = line:sub(1, -3), "\r\n"
  elseif line:sub(-1) == "\n" then
    content, ending = line:sub(1, -2), "\n"
  end
  content = content:gsub("^[ \t]+", "")
  content = content:gsub("[ \t]+$", "")
  return content .. ending
end

local function comparable_lines(lines, whitespace_mode)
  lines = lines or {}
  -- A Buffer always keeps one newline-only placeholder line. It is not file
  -- content and must not become an equality anchor against a real blank line.
  if #lines == 1 and lines[1] == "\n" then return {} end
  if whitespace_mode == "ignore" then
    local normalized = {}
    for i, line in ipairs(lines) do normalized[i] = line:gsub("%s", "") end
    return normalized
  elseif whitespace_mode == "trim" then
    local normalized = {}
    for i, line in ipairs(lines) do normalized[i] = trim_line(line) end
    return normalized
  end
  return lines
end

local function clamp_line(line, max)
  return math.max(1, math.min(math.max(1, max or 1), math.floor(tonumber(line) or 1)))
end

local DiffModel = {}
DiffModel.__index = DiffModel

local function side_changes(model, side)
  if side == "left" or side == "a" then return model.a_changes end
  return model.b_changes
end

function DiffModel:line_state(side, line)
  local changes = side_changes(self, side)
  local change = changes and changes[line]
  return change and change.tag or "equal"
end

function DiffModel:inline_ranges(side, line)
  local changes = side_changes(self, side)
  local change = changes and changes[line]
  return change and change.inline_ranges or nil
end

function DiffModel:inline_markers(side, line)
  local changes = side_changes(self, side)
  local change = changes and changes[line]
  return change and change.inline_markers or {}
end

local function token_segments(text)
  local segments, values = {}, {}
  local cursor = 1
  local function is_space(byte)
    return byte == 32 or (byte and byte >= 9 and byte <= 13)
  end
  local function is_word(byte)
    return byte and (
      (byte >= 48 and byte <= 57)
      or (byte >= 65 and byte <= 90)
      or byte == 95
      or (byte >= 97 and byte <= 122)
      or byte >= 128
    )
  end
  local function is_operator(byte)
    return byte and ("=+-*/%<>!&|^~?:."):find(string.char(byte), 1, true) ~= nil
  end

  while cursor <= #text do
    while cursor <= #text and is_space(text:byte(cursor)) do cursor = cursor + 1 end
    if cursor > #text then break end
    local start_col = cursor
    if is_word(text:byte(cursor)) then
      repeat cursor = cursor + 1
      until cursor > #text or not is_word(text:byte(cursor))
    elseif is_operator(text:byte(cursor)) then
      repeat cursor = cursor + 1
      until cursor > #text or not is_operator(text:byte(cursor))
    else
      -- Operators and delimiters are boundaries and tokens in their own right.
      cursor = cursor + 1
    end
    local end_col = cursor - 1
    segments[#segments + 1] = {
      text = text:sub(start_col, end_col),
      col1 = start_col,
      col2 = end_col + 1,
    }
    values[#values + 1] = segments[#segments].text
  end
  return segments, values
end

local function content_range(segment)
  local col1, col2 = segment.col1, segment.col2
  while col1 < col2 and segment.text:sub(col1 - segment.col1 + 1, col1 - segment.col1 + 1):match("%p") do
    col1 = col1 + 1
  end
  while col2 > col1 and segment.text:sub(col2 - segment.col1, col2 - segment.col1):match("%p") do
    col2 = col2 - 1
  end
  if col1 == col2 then return segment.col1, segment.col2 end
  return col1, col2
end

local function append_token_range(ranges, target, col1, col2, tag)
  if col2 <= col1 then return end
  local previous = ranges[#ranges]
  if previous and previous.tag == tag and target:sub(previous.col2, col1 - 1):match("^%s*$") then
    previous.col2 = math.max(previous.col2, col2)
  else
    ranges[#ranges + 1] = { col1 = col1, col2 = col2, tag = tag }
  end
end

local function line_end_column(text)
  if text:sub(-2) == "\r\n" then return #text - 1 end
  if text:sub(-1) == "\n" then return #text end
  return #text + 1
end

local function changed_target_spans(from, target)
  local spans, gaps, source_index, target_index = {}, {}, 1, 1
  local first, last, source_first, source_last
  local function flush()
    if first then
      -- A changed span with source and target text is a replacement.
      spans[#spans + 1] = {
        first = first, last = last, tag = source_first and "modify" or nil,
        source_first = source_first, source_last = source_last,
      }
    elseif source_first then
      gaps[#gaps + 1] = { index = target_index, source_first = source_first, source_last = source_last }
    end
    first, last, source_first, source_last = nil, nil, nil, nil
  end
  for edit in diff.diff_iter(from, target) do
    if edit.tag == "equal" or edit.tag == "modify" then
      flush()
      if edit.tag == "modify" then
        spans[#spans + 1] = {
          first = target_index, last = target_index, tag = "modify",
          source_first = source_index, source_last = source_index,
        }
      end
    else
      if edit.a then source_first, source_last = source_first or source_index, source_index end
      if edit.b then
        first, last = first or target_index, target_index
      end
    end
    if edit.a then source_index = source_index + 1 end
    if edit.b then target_index = target_index + 1 end
  end
  flush()
  return spans, gaps
end

local function uncovered_markers(markers, ranges)
  local result, index = {}, 1
  for _, marker in ipairs(markers) do
    while ranges[index] and ranges[index].col2 <= marker.col do index = index + 1 end
    -- Keep markers at range boundaries, not inside highlighted text.
    if not ranges[index] or marker.col <= ranges[index].col1 then
      result[#result + 1] = marker
    end
  end
  return result
end

local function changed_token_contents(from_segments, target_segments)
  local function characters(segments)
    local values, owners = {}, {}
    for index, segment in ipairs(segments) do
      for char in common.utf8_chars(segment.text) do
        values[#values + 1], owners[#owners + 1] = char, index
      end
    end
    return values, owners
  end
  local from_values, from_owners = characters(from_segments)
  local target_values, target_owners = characters(target_segments)
  local from_changed, target_changed, ai, bi = {}, {}, 1, 1
  for edit in diff.diff_iter(from_values, target_values) do
    if edit.tag ~= "equal" then
      if edit.a then from_changed[from_owners[ai]] = true end
      if edit.b then target_changed[target_owners[bi]] = true end
    end
    if edit.a then ai = ai + 1 end
    if edit.b then bi = bi + 1 end
  end
  return from_changed, target_changed
end

local function has_changed_token(changed, first, last)
  if not first then return false end
  for index = first, last do
    if changed[index] then return true end
  end
  return false
end

---Use word alignment so repeated letters cannot make partially replaced words
---look unchanged. Modified, inserted, and deleted text is emphasized only at
---whole-word granularity, matching IntelliJ's restrained inline presentation.
local function token_inline_ranges(from, target, ignore_whitespace)
  local from_segments, from_values = token_segments(from)
  local target_segments, target_values = token_segments(target)
  local from_changed, target_changed
  if ignore_whitespace then
    -- Use character matches to ignore spacing-only changes. Words select colors and marker positions.
    from_changed, target_changed = changed_token_contents(from_segments, target_segments)
  end

  local ranges, markers = {}, {}
  local spans, gaps = changed_target_spans(from_values, target_values)
  for _, span in ipairs(spans) do
    local source_changed = from_changed and has_changed_token(from_changed, span.source_first, span.source_last)
    for index = span.first, span.last do
      if not ignore_whitespace or source_changed or target_changed[index] then
        local col1, col2 = content_range(target_segments[index])
        append_token_range(ranges, target, col1, col2, span.tag)
      end
    end
  end
  for _, gap in ipairs(gaps) do
    if not ignore_whitespace or has_changed_token(from_changed, gap.source_first, gap.source_last) then
      local segment = target_segments[gap.index]
      markers[#markers + 1] = { col = segment and segment.col1 or line_end_column(target) }
    end
  end
  return ranges, uncovered_markers(markers, ranges)
end

local function is_trim_space(byte)
  return byte == 32 or byte == 9
end

local function trim_content_bounds(text)
  local end_col = line_end_column(text) - 1

  local first = 1
  while first <= end_col and is_trim_space(text:byte(first)) do first = first + 1 end
  local last = end_col
  while last >= first and is_trim_space(text:byte(last)) do last = last - 1 end
  return first, last
end

local function full_content_ranges(text)
  local first, last = trim_content_bounds(text)
  if last < first then return {} end
  return { { col1 = first, col2 = last + 1 } }
end

local function is_trim_edge_column(text, col)
  if not is_trim_space(text:byte(col)) then return false end
  local first, last = trim_content_bounds(text)
  return col < first or col > last
end

local function append_inline_range(ranges, col)
  local previous = ranges[#ranges]
  if previous and not previous.tag and col >= previous.col1 and col <= previous.col2 then
    previous.col2 = math.max(previous.col2, col + 1)
  else
    ranges[#ranges + 1] = { col1 = col, col2 = col + 1 }
  end
end

local function merge_inline_ranges(ranges)
  table.sort(ranges, function(a, b) return a.col1 < b.col1 end)
  local merged = {}
  for _, range in ipairs(ranges) do
    local previous = merged[#merged]
    if previous and range.col1 <= previous.col2
      and (previous.tag == range.tag or range.col1 < previous.col2) then
      previous.col2 = math.max(previous.col2, range.col2)
      previous.tag = previous.tag or range.tag
    else
      merged[#merged + 1] = { col1 = range.col1, col2 = range.col2, tag = range.tag }
    end
  end
  return merged
end

local function trim_whitespace_inline_ranges(from, target)
  local ranges, markers = token_inline_ranges(from, target)
  local target_col = 1
  for _, edit in ipairs(diff.inline_diff(from, target) or {}) do
    local value = edit.val or ""
    if edit.tag ~= "delete" then
      if edit.tag ~= "equal" then
        for offset = 0, #value - 1 do
          local col = target_col + offset
          if is_trim_space(target:byte(col)) and not is_trim_edge_column(target, col) then
            append_inline_range(ranges, col)
          end
        end
      end
      target_col = target_col + #value
    end
  end
  ranges = merge_inline_ranges(ranges)
  return ranges, uncovered_markers(markers, ranges)
end

local function inline_change(from, to, whitespace_mode)
  from, to = from or "", to or ""
  if from == to then return nil, {}, {} end
  if whitespace_mode == "ignore" then
    return nil, token_inline_ranges(from, to, true)
  end
  if whitespace_mode == "trim" then
    return nil, trim_whitespace_inline_ranges(from, to)
  end
  return nil, token_inline_ranges(from, to)
end

function DiffModel:hunk_at(side, line)
  local changes = side_changes(self, side)
  local change = changes and changes[line]
  if not change or change.tag == "equal" then return nil end
  local tag = change.tag
  local start_line, end_line = line, line
  while start_line > 1 and changes[start_line - 1] and changes[start_line - 1].tag == tag do
    start_line = start_line - 1
  end
  while changes[end_line + 1] and changes[end_line + 1].tag == tag do
    end_line = end_line + 1
  end
  return { tag = tag, start_line = start_line, end_line = end_line }
end

function DiffModel:next_hunk(side, line, direction)
  local changes = side_changes(self, side)
  if not changes or #changes == 0 then return nil end
  direction = direction and direction < 0 and -1 or 1
  local count = #changes
  local current = math.max(1, math.min(count, math.floor(tonumber(line) or 1)))
  for step = 1, count do
    local idx = ((current - 1 + direction * step) % count) + 1
    local change = changes[idx]
    if change and change.tag ~= "equal" and (not changes[idx - 1] or changes[idx - 1].tag ~= change.tag) then
      return self:hunk_at(side, idx)
    end
  end
end

function DiffModel:map_line(source_side, line)
  line = math.max(1, math.floor(tonumber(line) or 1))
  local source_key = (source_side == "left" or source_side == "a") and "a" or "b"
  local target_key = source_key == "a" and "b" or "a"
  for index, pair in ipairs(self.alignment or {}) do
    if pair[source_key] == line and pair.tag ~= "equal" then
      if pair[target_key] then return pair[target_key] end
      local first, last = index, index
      while first > 1 and self.alignment[first - 1].tag ~= "equal" do first = first - 1 end
      while last < #self.alignment and self.alignment[last + 1].tag ~= "equal" do last = last + 1 end
      local source_lines, target_lines = {}, {}
      for i = first, last do
        local item = self.alignment[i]
        if item[source_key] then source_lines[#source_lines + 1] = item[source_key] end
        if item[target_key] then target_lines[#target_lines + 1] = item[target_key] end
      end
      if #target_lines > 0 then
        for source_index, source_line in ipairs(source_lines) do
          if source_line == line then
            return target_lines[math.min(source_index, #target_lines)]
          end
        end
      end
      break
    end
  end
  if source_side == "left" or source_side == "a" then
    return self.a_to_b[line] or math.max(1, math.min(self.b_len, line))
  end
  return self.b_to_a[line] or math.max(1, math.min(self.a_len, line))
end

function DiffModel:map_range(source_side, line)
  local hunk = self:hunk_at(source_side, line)
  if not hunk then
    local mapped = self:map_line(source_side, line)
    return line, line, mapped, mapped
  end
  return hunk.start_line, hunk.end_line, self:map_line(source_side, hunk.start_line), self:map_line(source_side, hunk.end_line)
end

function M.compute(a_lines, b_lines, opts)
  opts = opts or {}
  local whitespace_mode = opts.whitespace_mode or "none"
  local comparable_a = comparable_lines(a_lines, whitespace_mode)
  local comparable_b = comparable_lines(b_lines, whitespace_mode)
  local ai, bi = 1, 1
  local a_offset, b_offset = 0, 0
  local a_offset_total, b_offset_total = 0, 0
  local a_len, b_len = max_line(a_lines), max_line(b_lines)
  local a_gaps, b_gaps = {}, {}
  local a_changes, b_changes = {}, {}
  local a_to_b, b_to_a = {}, {}
  local alignment = {}
  local equal_blocks = {}
  local equal_block, seen_change = nil, false
  local change_start_a, change_start_b

  local function finish_changed_side(changes, source, first, last, block_tag)
    for line = first, last do
      local change = changes[line]
      change.block_tag = block_tag
      if change.tag ~= "modify" then
        change.inline_ranges = block_tag == "modify" and full_content_ranges(source[line]) or {}
      end
      if opts.should_yield and opts.should_yield() then coroutine.yield() end
    end
  end

  local function flush_change_block()
    if not change_start_a then return end
    -- Unchanged lines separate blocks. A block with text on both sides is mixed.
    local tag = ai > change_start_a and (bi > change_start_b and "modify" or "delete") or "insert"
    finish_changed_side(a_changes, a_lines, change_start_a, ai - 1, tag)
    finish_changed_side(b_changes, b_lines, change_start_b, bi - 1, tag)
    change_start_a, change_start_b = nil, nil
  end

  local function flush_equal_block(has_next_change)
    if equal_block and equal_block.count > 0 then
      equal_block.has_next_change = has_next_change == true
      equal_blocks[#equal_blocks + 1] = equal_block
    end
    equal_block = nil
  end

  for edit in diff.diff_iter(comparable_a, comparable_b) do
    -- Compare normalized keys, but keep source columns and source text intact.
    edit.a = edit.a and a_lines[ai] or nil
    edit.b = edit.b and b_lines[bi] or nil
    if edit.tag == "equal" then
      flush_change_block()
    elseif not change_start_a then
      change_start_a, change_start_b = ai, bi
    end
    alignment[#alignment + 1] = {
      tag = edit.tag,
      a = edit.a and ai or nil,
      b = edit.b and bi or nil,
    }
    if edit.tag == "equal" or edit.tag == "modify" then
      a_gaps[ai] = { a_offset, a_offset_total }
      b_gaps[bi] = { b_offset, b_offset_total }

      if edit.a and edit.b and edit.tag == "equal" then
        equal_block = equal_block or { a_start = ai, b_start = bi, count = 0, has_prev_change = seen_change }
        equal_block.count = equal_block.count + 1
      else
        flush_equal_block(true)
        seen_change = true
      end

      if edit.a and edit.b then
        a_to_b[ai] = bi
        b_to_a[bi] = ai
      end
      if edit.a then
        local changes, inline_ranges, inline_markers = nil, {}
        if edit.tag ~= "equal" then
          changes, inline_ranges, inline_markers = inline_change(edit.b, edit.a, whitespace_mode)
        end
        a_changes[#a_changes + 1] = {
          tag = edit.tag,
          changes = changes,
          inline_ranges = inline_ranges,
          inline_markers = inline_markers,
        }
        ai = ai + 1
        a_offset = 0
      end
      if edit.b then
        local changes, inline_ranges, inline_markers = nil, {}
        if edit.tag ~= "equal" then
          changes, inline_ranges, inline_markers = inline_change(edit.a, edit.b, whitespace_mode)
        end
        b_changes[#b_changes + 1] = {
          tag = edit.tag,
          changes = changes,
          inline_ranges = inline_ranges,
          inline_markers = inline_markers,
        }
        bi = bi + 1
        b_offset = 0
      end
    elseif edit.tag == "delete" then
      flush_equal_block(true)
      seen_change = true
      if edit.a then
        a_gaps[ai] = { a_offset, a_offset_total }
        a_changes[#a_changes + 1] = { tag = "delete" }
        a_to_b[ai] = clamp_line(bi, b_len)
        ai = ai + 1
        b_offset = b_offset + 1
        b_offset_total = b_offset_total + 1
      end
    elseif edit.tag == "insert" then
      flush_equal_block(true)
      seen_change = true
      if edit.b then
        b_gaps[bi] = { b_offset, b_offset_total }
        b_changes[#b_changes + 1] = { tag = "insert" }
        b_to_a[bi] = clamp_line(ai, a_len)
        bi = bi + 1
        a_offset = a_offset + 1
        a_offset_total = a_offset_total + 1
      end
    end

    if opts.should_yield and opts.should_yield() then coroutine.yield() end
  end

  flush_change_block()
  flush_equal_block(false)

  while ai <= a_len do
    a_gaps[ai] = a_gaps[ai] or { a_offset, a_offset_total }
    a_to_b[ai] = a_to_b[ai] or clamp_line(ai + b_offset_total - a_offset_total, b_len)
    ai = ai + 1
  end
  while bi <= b_len do
    b_gaps[bi] = b_gaps[bi] or { b_offset, b_offset_total }
    b_to_a[bi] = b_to_a[bi] or clamp_line(bi + a_offset_total - b_offset_total, a_len)
    bi = bi + 1
  end

  return setmetatable({
    a_len = a_len,
    b_len = b_len,
    a_gaps = a_gaps,
    b_gaps = b_gaps,
    a_changes = a_changes,
    b_changes = b_changes,
    equal_blocks = equal_blocks,
    a_to_b = a_to_b,
    b_to_a = b_to_a,
    alignment = alignment,
  }, DiffModel)
end

M.DiffModel = DiffModel

return M
