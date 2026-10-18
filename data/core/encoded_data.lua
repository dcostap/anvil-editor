-- Encoded data, such as a base64 image pasted into a note, is one long run of
-- letters, digits and `+/=_-` without spaces. Searches and word lists treat a
-- match that starts inside such a run as data, not text.
--
-- `src/api/line_search.c` applies the same rule to native Find scans.
local encoded_data = {}

encoded_data.min_run_length = 256

local RUN = "[%w+/=_%-]"
local RUN_PLUS = RUN .. "+"
local RUN_AT_END = RUN .. "*$"
local RUN_AT_START = "^" .. RUN .. "*"

---Return the bounds of the next encoded run at or after `from`.
---@return integer? first
---@return integer? last
function encoded_data.next_run(text, from)
  if #text < encoded_data.min_run_length then return nil end
  while true do
    local first, last = text:find(RUN_PLUS, from)
    if not first then return nil end
    if last - first + 1 >= encoded_data.min_run_length then return first, last end
    from = last + 1
  end
end

---Whether the byte at `pos` lies inside an encoded run. The check reads at
---most one run length on each side, so it stays cheap on long lines.
function encoded_data.covers(text, pos)
  local min = encoded_data.min_run_length
  if #text < min or pos < 1 or pos > #text then return false end
  local after = text:sub(pos, pos + min - 1):match(RUN_AT_START)
  if after == "" then return false end
  local before = text:sub(math.max(1, pos - min), pos - 1):match(RUN_AT_END)
  return #before + #after >= min
end

---Return the last byte of the run that contains `pos`.
function encoded_data.run_end(text, pos)
  local _, last = text:find(RUN_AT_START, pos)
  return math.max(last, pos)
end

---Return the spans whose first byte lies outside encoded runs.
---@param spans table[] spans of `{ first, last }`
function encoded_data.text_spans(text, spans)
  if #text < encoded_data.min_run_length then return spans end
  local out = {}
  for _, span in ipairs(spans) do
    if not encoded_data.covers(text, span[1]) then out[#out + 1] = span end
  end
  return out
end

return encoded_data
