local M = {}

local function max_line(lines)
  return math.max(1, #(lines or {}))
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
  return change and change.changes or nil
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
  local ai, bi = 1, 1
  local a_offset, b_offset = 0, 0
  local a_offset_total, b_offset_total = 0, 0
  local a_len, b_len = max_line(a_lines), max_line(b_lines)
  local a_gaps, b_gaps = {}, {}
  local a_changes, b_changes = {}, {}
  local a_to_b, b_to_a = {}, {}
  local equal_blocks = {}
  local equal_block, seen_change = nil, false

  local function flush_equal_block(has_next_change)
    if equal_block and equal_block.count > 0 then
      equal_block.has_next_change = has_next_change == true
      equal_blocks[#equal_blocks + 1] = equal_block
    end
    equal_block = nil
  end

  for edit in diff.diff_iter(a_lines, b_lines) do
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
        a_changes[#a_changes + 1] = {
          tag = edit.tag,
          changes = diff.inline_diff(edit.b or "", edit.a),
        }
        ai = ai + 1
        a_offset = 0
      end
      if edit.b then
        b_changes[#b_changes + 1] = {
          tag = edit.tag,
          changes = diff.inline_diff(edit.a or "", edit.b),
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
  }, DiffModel)
end

M.DiffModel = DiffModel

return M
