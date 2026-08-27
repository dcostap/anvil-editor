local M = {}

local function max_line(lines)
  return math.max(1, #(lines or {}))
end

local function comparable_lines(lines)
  lines = lines or {}
  -- A Buffer always keeps one newline-only placeholder line. It is not file
  -- content and must not become an equality anchor against a real blank line.
  if #lines == 1 and lines[1] == "\n" then return {} end
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

local function append_token_range(ranges, target, col1, col2)
  if col2 <= col1 then return end
  local previous = ranges[#ranges]
  if previous and target:sub(previous.col2, col1 - 1):match("^%s*$") then
    previous.col2 = math.max(previous.col2, col2)
  else
    ranges[#ranges + 1] = { col1 = col1, col2 = col2 }
  end
end

---Use word alignment so repeated letters cannot make partially replaced words
---look unchanged. Modified, inserted, and deleted text is emphasized only at
---whole-word granularity, matching IntelliJ's restrained inline presentation.
local function token_inline_ranges(from, target)
  local _, from_values = token_segments(from)
  local target_segments, target_values = token_segments(target)

  local ranges = {}
  local target_index = 1
  for edit in diff.diff_iter(from_values, target_values) do
    local target_segment = edit.b and target_segments[target_index] or nil
    if (edit.tag == "modify" or edit.tag == "insert") and target_segment then
      local col1, col2 = content_range(target_segment)
      append_token_range(ranges, target, col1, col2)
    end
    if edit.b then target_index = target_index + 1 end
  end
  return ranges
end

local function inline_change(from, to)
  from, to = from or "", to or ""
  local edits = diff.inline_diff(from, to)
  if from == to then return edits, {} end
  return edits, token_inline_ranges(from, to)
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
  local comparable_a = comparable_lines(a_lines)
  local comparable_b = comparable_lines(b_lines)
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

  local function flush_equal_block(has_next_change)
    if equal_block and equal_block.count > 0 then
      equal_block.has_next_change = has_next_change == true
      equal_blocks[#equal_blocks + 1] = equal_block
    end
    equal_block = nil
  end

  for edit in diff.diff_iter(comparable_a, comparable_b) do
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
        local changes, inline_ranges = inline_change(edit.b, edit.a)
        a_changes[#a_changes + 1] = {
          tag = edit.tag,
          changes = changes,
          inline_ranges = inline_ranges,
        }
        ai = ai + 1
        a_offset = 0
      end
      if edit.b then
        local changes, inline_ranges = inline_change(edit.a, edit.b)
        b_changes[#b_changes + 1] = {
          tag = edit.tag,
          changes = changes,
          inline_ranges = inline_ranges,
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

  -- Once a changed block contains a confidently paired replacement, present
  -- its unmatched continuation lines as part of that modification rather
  -- than as a visually separate red/green delete/insert pair. Keep raw_tag so
  -- the renderer can still use the correct one-sided connector geometry.
  local changed_run = {}
  local function mark_modify(change)
    if change and change.tag ~= "equal" then
      change.raw_tag = change.tag
      change.tag = "modify"
    end
  end
  local function flush_changed_run()
    local has_modify = false
    for _, pair in ipairs(changed_run) do
      if pair.tag == "modify" then has_modify = true; break end
    end
    if has_modify then
      for _, pair in ipairs(changed_run) do
        mark_modify(pair.a and a_changes[pair.a] or nil)
        mark_modify(pair.b and b_changes[pair.b] or nil)
      end
    end
    changed_run = {}
  end
  for _, pair in ipairs(alignment) do
    if pair.tag == "equal" then
      flush_changed_run()
    else
      changed_run[#changed_run + 1] = pair
    end
  end
  flush_changed_run()

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
