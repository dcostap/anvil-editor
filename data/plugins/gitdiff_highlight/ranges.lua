-- mod-version:3
-- Range builder for gitdiff_highlight.
--
-- The public model uses 1-based half-open ranges:
--   current_start <= line < current_end
--   base_start    <= line < base_end
-- Deletions have current_start == current_end and are anchored at that current
-- document position.
local ranges = {}

local default_options = {
  max_diff_cells = 2 * 1000 * 1000,
  max_diff_lines = 50000,
}

local function line_equal(a, b)
  return a == b
end

local function slice_lines(lines, first, last_exclusive)
  local out = {}
  for i = first, last_exclusive - 1 do
    out[#out + 1] = lines[i]
  end
  return out
end

local function range_len(start_line, end_line)
  return math.max(0, end_line - start_line)
end

local function range_type_for_counts(base_count, current_count)
  if base_count == 0 and current_count > 0 then return "addition" end
  if base_count > 0 and current_count == 0 then return "deletion" end
  if base_count > 0 and current_count > 0 then return "modification" end
end

local function make_range(base_start, base_end, current_start, current_end)
  local typ = range_type_for_counts(
    range_len(base_start, base_end),
    range_len(current_start, current_end)
  )
  if not typ then return nil end
  return {
    type = typ,
    current_start = current_start,
    current_end = current_end,
    base_start = base_start,
    base_end = base_end,
  }
end

local function can_merge_same_type(a, b)
  if a.type ~= b.type then return false end
  return a.current_end == b.current_start and a.base_end == b.base_start
end

local function can_merge_replacement(a, b)
  -- Diff iterators commonly report a replace as delete(s) followed by insert(s)
  -- at the same current anchor.  Be permissive and also accept the opposite
  -- order if a future diff backend emits it.
  if a.type == "deletion" and b.type == "addition" then
    return a.current_start == b.current_start and a.base_end == b.base_start
  end
  if a.type == "addition" and b.type == "deletion" then
    return a.current_end == b.current_start and a.base_start == b.base_start
  end
  return false
end

local function merge_replacement(a, b)
  return {
    type = "modification",
    current_start = math.min(a.current_start, b.current_start),
    current_end = math.max(a.current_end, b.current_end),
    base_start = math.min(a.base_start, b.base_start),
    base_end = math.max(a.base_end, b.base_end),
  }
end

local function append_range(out, r)
  if not r then return end
  local last = out[#out]
  if last then
    if can_merge_same_type(last, r) then
      last.current_end = r.current_end
      last.base_end = r.base_end
      return
    end
    if can_merge_replacement(last, r) then
      out[#out] = merge_replacement(last, r)
      return
    end
  end
  out[#out + 1] = r
end

local function append_direct_range(out, base_start, base_end, current_start, current_end)
  append_range(out, make_range(base_start, base_end, current_start, current_end))
end

local function exact_equal(base_lines, current_lines)
  if #base_lines ~= #current_lines then return false end
  for i = 1, #base_lines do
    if not line_equal(base_lines[i], current_lines[i]) then return false end
  end
  return true
end

local function find_trim(base_lines, current_lines)
  local base_count = #base_lines
  local current_count = #current_lines
  local prefix = 0

  while prefix < base_count and prefix < current_count
    and line_equal(base_lines[prefix + 1], current_lines[prefix + 1]) do
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < base_count - prefix and suffix < current_count - prefix
    and line_equal(base_lines[base_count - suffix], current_lines[current_count - suffix]) do
    suffix = suffix + 1
  end

  return {
    prefix = prefix,
    suffix = suffix,
    base_first = prefix + 1,
    base_last_exclusive = base_count - suffix + 1,
    current_first = prefix + 1,
    current_last_exclusive = current_count - suffix + 1,
  }
end

local function count_cells(a, b)
  if a == 0 or b == 0 then return 0 end
  return a * b
end

local function over_budget(base_mid_count, current_mid_count, options)
  local max_diff_lines = options.max_diff_lines or default_options.max_diff_lines
  if base_mid_count > max_diff_lines or current_mid_count > max_diff_lines then
    return true, "too_many_lines"
  end

  local max_diff_cells = options.max_diff_cells or default_options.max_diff_cells
  if count_cells(base_mid_count, current_mid_count) > max_diff_cells then
    return true, "too_many_cells"
  end

  return false
end

local function iter_to_ranges(base_mid_lines, current_mid_lines, base_shift, current_shift, diff_iter)
  local out = {}
  local base_line = base_shift + 1
  local current_line = current_shift + 1

  for edit in diff_iter(base_mid_lines, current_mid_lines) do
    local tag = edit.tag
    if tag == "equal" then
      if edit.a then base_line = base_line + 1 end
      if edit.b then current_line = current_line + 1 end
    elseif tag == "modify" then
      local base_inc = edit.a and 1 or 0
      local current_inc = edit.b and 1 or 0
      append_direct_range(
        out,
        base_line, base_line + base_inc,
        current_line, current_line + current_inc
      )
      base_line = base_line + base_inc
      current_line = current_line + current_inc
    elseif tag == "delete" then
      if edit.a then
        append_direct_range(out, base_line, base_line + 1, current_line, current_line)
        base_line = base_line + 1
      end
    elseif tag == "insert" then
      if edit.b then
        append_direct_range(out, base_line, base_line, current_line, current_line + 1)
        current_line = current_line + 1
      end
    end
  end

  return out
end

---Build sorted half-open ranges from base/current line arrays.
---@param base_lines string[]
---@param current_lines string[]
---@param options? table
---@return gitdiff.range[] ranges
---@return table meta
function ranges.build(base_lines, current_lines, options)
  options = options or default_options
  base_lines = base_lines or {}
  current_lines = current_lines or {}

  if exact_equal(base_lines, current_lines) then
    return {}, { clean = true, trimmed = true, cells = 0 }
  end

  local trim = find_trim(base_lines, current_lines)
  local base_mid_count = trim.base_last_exclusive - trim.base_first
  local current_mid_count = trim.current_last_exclusive - trim.current_first

  if base_mid_count == 0 or current_mid_count == 0 then
    local out = {}
    append_direct_range(
      out,
      trim.base_first, trim.base_last_exclusive,
      trim.current_first, trim.current_last_exclusive
    )
    return out, {
      clean = false,
      trimmed = true,
      cells = 0,
      prefix = trim.prefix,
      suffix = trim.suffix,
    }
  end

  local is_over_budget, reason = over_budget(base_mid_count, current_mid_count, options)
  if is_over_budget then
    return {}, {
      too_large = true,
      reason = reason,
      base_mid_count = base_mid_count,
      current_mid_count = current_mid_count,
      cells = count_cells(base_mid_count, current_mid_count),
      prefix = trim.prefix,
      suffix = trim.suffix,
    }
  end

  local diff_mod = options.diff or diff
  local diff_iter = options.diff_iter or (diff_mod and diff_mod.diff_iter)
  if not diff_iter then
    return {}, { error = "diff_iter_unavailable" }
  end

  local base_mid_lines = slice_lines(base_lines, trim.base_first, trim.base_last_exclusive)
  local current_mid_lines = slice_lines(current_lines, trim.current_first, trim.current_last_exclusive)
  local out = iter_to_ranges(base_mid_lines, current_mid_lines, trim.prefix, trim.prefix, diff_iter)

  return out, {
    clean = false,
    trimmed = true,
    cells = count_cells(base_mid_count, current_mid_count),
    prefix = trim.prefix,
    suffix = trim.suffix,
  }
end

---Split text to match core.doc's loaded line representation as closely as the
---plugin can without executing Doc:load(): CRLF is normalized to LF; every
---stored line has a trailing "\n"; empty text becomes {"\n"}.
---@param text string
---@return string[]
function ranges.split_doc_lines(text)
  text = text or ""
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local out = {}
  local pos = 1
  while true do
    local nl = text:find("\n", pos, true)
    if nl then
      out[#out + 1] = text:sub(pos, nl - 1) .. "\n"
      pos = nl + 1
    else
      if pos <= #text then
        -- Match Doc:load(): a file without a final newline is still stored as
        -- a newline-terminated document line in memory.
        out[#out + 1] = text:sub(pos) .. "\n"
      end
      break
    end
  end
  if #out == 0 then out[1] = "\n" end
  return out
end

return ranges
