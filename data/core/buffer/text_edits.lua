-- Turn one list of Buffer lines into another with few, small edits.
-- Changed lines are compared again word by word, so text around a change keeps
-- its position, such as a caret in the same line.
local text_edits = {}

-- Larger changed blocks become one edit. Word comparison of a rewrite this
-- size gives no useful positions and costs one Lua string for each word.
local MAX_REFINED_BYTES = 256 * 1024

local function tokens(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local _, e = text:find("^[%w_\128-\255]+", i)
    if not e then _, e = text:find("^[ \t]+", i) end
    e = e or i
    out[#out + 1] = text:sub(i, e)
    i = e + 1
  end
  return out
end

local function concat(lines, first, last)
  return table.concat(lines, "", first, last)
end

local function slice(lines, first, last)
  local out = {}
  for i = first, last do out[#out + 1] = lines[i] end
  return out
end

-- Append edits that change old_text, which starts at byte offset start, into new_text.
local function append_refined(out, start, old_text, new_text)
  if old_text == "" or new_text == "" or #old_text + #new_text > MAX_REFINED_BYTES then
    out[#out + 1] = { start = start, stop = start + #old_text, text = new_text }
    return
  end
  local old_tokens, new_tokens = tokens(old_text), tokens(new_text)
  local offset, run_start, run_text = start, nil, {}
  local function flush()
    if run_start then
      out[#out + 1] = { start = run_start, stop = offset, text = table.concat(run_text) }
      run_start, run_text = nil, {}
    end
  end
  for edit in diff.diff_iter(old_tokens, new_tokens, "minimal") do
    if edit.tag == "equal" then
      flush()
      offset = offset + #edit.a
    else
      run_start = run_start or offset
      if edit.a then offset = offset + #edit.a end
      if edit.b then run_text[#run_text + 1] = edit.b end
    end
  end
  flush()
end

---Return edits that change old_lines into new_lines, in Buffer positions.
---Both lists use Buffer lines: each line ends with "\n", and the last "\n" is not text.
---@param old_lines string[]
---@param new_lines string[]
---@return { line1: integer, col1: integer, line2: integer, col2: integer, text: string }[]
function text_edits.between(old_lines, new_lines)
  local old_count, new_count = #old_lines, #new_lines
  local prefix = 0
  while prefix < old_count and prefix < new_count
    and old_lines[prefix + 1] == new_lines[prefix + 1] do
    prefix = prefix + 1
  end
  if prefix == old_count and prefix == new_count then return {} end
  local suffix = 0
  while suffix < old_count - prefix and suffix < new_count - prefix
    and old_lines[old_count - suffix] == new_lines[new_count - suffix] do
    suffix = suffix + 1
  end

  local starts, total = {}, 0
  for i = 1, old_count do
    starts[i] = total
    total = total + #old_lines[i]
  end

  local blocks, block = {}, nil
  local ai, bi = prefix + 1, prefix + 1
  local function flush()
    if block then
      block.a2, block.b2 = ai - 1, bi - 1
      blocks[#blocks + 1] = block
      block = nil
    end
  end
  local old_mid = slice(old_lines, prefix + 1, old_count - suffix)
  local new_mid = slice(new_lines, prefix + 1, new_count - suffix)
  for edit in diff.diff_iter(old_mid, new_mid) do
    if edit.tag == "equal" then
      flush()
    else
      block = block or { a1 = ai, b1 = bi }
    end
    if edit.tag ~= "insert" then ai = ai + 1 end
    if edit.tag ~= "delete" then bi = bi + 1 end
  end
  flush()

  local ranges = {}
  for _, b in ipairs(blocks) do
    local old_text, new_text = concat(old_lines, b.a1, b.a2), concat(new_lines, b.b1, b.b2)
    local start = starts[b.a1] or total
    if b.a2 == old_count then
      -- The last "\n" is not text. Move the block one byte left, so it starts
      -- at the "\n" before it, or drop the last "\n" when the block starts the text.
      if old_text == "" then
        start = total - 1
        new_text = "\n" .. new_text:sub(1, -2)
      elseif start > 0 then
        start = start - 1
        old_text = "\n" .. old_text:sub(1, -2)
        new_text = new_text ~= "" and "\n" .. new_text:sub(1, -2) or ""
      else
        old_text, new_text = old_text:sub(1, -2), new_text:sub(1, -2)
      end
    end
    append_refined(ranges, start, old_text, new_text)
  end

  local edits, line = {}, 1
  local function position(offset)
    while line < old_count and starts[line + 1] <= offset do line = line + 1 end
    return line, offset - starts[line] + 1
  end
  for _, range in ipairs(ranges) do
    local line1, col1 = position(range.start)
    local line2, col2 = position(range.stop)
    edits[#edits + 1] = { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = range.text }
  end
  return edits
end

return text_edits
