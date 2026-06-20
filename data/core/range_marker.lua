local core = require "core"
local common = require "core.common"
local Doc = require "core.doc"

local range_marker = {}

local stores = setmetatable({}, { __mode = "k" })
local generation = 0

local function bump_generation()
  generation = generation + 1
  return generation
end

function range_marker.generation()
  return generation
end

local function line_starts_for(lines)
  local starts, offset = {}, 0
  for i = 1, #lines do
    starts[i] = offset
    offset = offset + #lines[i]
  end
  return starts, offset
end

local function sanitize_position_in_lines(lines, line, col)
  local nlines = #lines
  if nlines == 0 then return 1, 1 end
  if line > nlines then
    return nlines, #(lines[nlines] or "")
  elseif line < 1 then
    return 1, 1
  end
  return line, common.clamp(col or 1, 1, #(lines[line] or ""))
end

local function position_to_offset_for_lines(lines, line, col)
  local starts = line_starts_for(lines)
  line, col = sanitize_position_in_lines(lines, line, col)
  return starts[line] + col - 1
end

local function offset_to_position_for_lines(lines, starts, total, offset)
  if #lines == 0 then return 1, 1 end
  offset = common.clamp(offset or 0, 0, total)
  if offset <= 0 then return 1, 1 end
  if offset >= total then return #lines, #(lines[#lines] or "") end
  local lo, hi = 1, #lines
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local next_start = starts[mid + 1] or total + 1
    if offset < starts[mid] then
      hi = mid - 1
    elseif offset >= next_start then
      lo = mid + 1
    else
      return mid, offset - starts[mid] + 1
    end
  end
  return #lines, #(lines[#lines] or "")
end

local function offsets_for_doc_range(doc, line1, col1, line2, col2)
  local lines = doc and doc.lines or { "\n" }
  line1, col1 = sanitize_position_in_lines(lines, line1 or 1, col1 or 1)
  line2, col2 = sanitize_position_in_lines(lines, line2 or line1, col2 or col1)
  local start_offset = position_to_offset_for_lines(lines, line1, col1)
  local end_offset = position_to_offset_for_lines(lines, line2, col2)
  if start_offset > end_offset then start_offset, end_offset = end_offset, start_offset end
  return start_offset, end_offset
end

local Marker = {}
Marker.__index = Marker

local function notify_marker_changed(marker, reason)
  if type(marker.on_change) == "function" then
    local ok, err = pcall(marker.on_change, marker, reason)
    if not ok and core and core.log_quiet then
      core.log_quiet("Range marker on_change failed for %s marker: %s", tostring(marker.kind or "unknown"), tostring(err))
    end
  end
end

function Marker:is_valid()
  return self.valid == true
end

function Marker:range()
  if not self.valid then return nil end
  local lines = self.doc and self.doc.lines or { "\n" }
  local starts, total = line_starts_for(lines)
  local line1, col1 = offset_to_position_for_lines(lines, starts, total, self.start_offset)
  local line2, col2 = offset_to_position_for_lines(lines, starts, total, self.end_offset)
  return {
    line1 = line1,
    col1 = col1,
    line2 = line2,
    col2 = col2,
    start_offset = self.start_offset,
    end_offset = self.end_offset,
  }
end

function Marker:set_range(line1, col1, line2, col2)
  local start_offset, end_offset = offsets_for_doc_range(self.doc, line1, col1, line2, col2)
  local changed = not self.valid or self.start_offset ~= start_offset or self.end_offset ~= end_offset
  self.start_offset = start_offset
  self.end_offset = end_offset
  self.valid = true
  self.invalid_reason = nil
  if changed then
    bump_generation()
    notify_marker_changed(self, "set-range")
  end
  return self
end

function Marker:invalidate(reason)
  if not self.valid then return false end
  self.valid = false
  self.invalid_reason = reason or "invalidated"
  bump_generation()
  notify_marker_changed(self, self.invalid_reason)
  if core and core.log_quiet then
    core.log_quiet("Invalidated %s range marker: %s", tostring(self.kind or "unknown"), tostring(self.invalid_reason))
  end
  return true
end

local function apply_insert(marker, s, e, a, len, text)
  if a < s then return s + len, e + len end
  if a > e then return s, e end
  local inserted_newline = tostring(text or ""):find("\n", 1, true) ~= nil
  if s == e and a == s then
    if marker.sticky_right or marker.sticky_right_on_newline and inserted_newline then return s + len, e + len end
    if marker.greedy_left and marker.greedy_right then return s, e + len end
    return s, e
  end
  if a == s then
    if marker.sticky_right or marker.sticky_right_on_newline and inserted_newline then return s + len, e + len end
    if marker.greedy_left then return s, e + len end
    return s + len, e + len
  end
  if a == e then
    if marker.greedy_right then return s, e + len end
    return s, e
  end
  return s, e + len
end

local function find_preserved_range_in_replacement(marker, s, e, a, edit)
  if not marker.preserve_on_replace then return nil end
  local old_text = edit and edit.old_text or ""
  local new_text = edit and edit.text or ""
  local rel_start = math.max(0, s - a)
  local rel_end = math.max(rel_start, e - a)
  local needle = old_text:sub(rel_start + 1, rel_end)
  if needle == "" then return nil end
  local best_rel, best_distance
  local search_from = 1
  while true do
    local found = new_text:find(needle, search_from, true)
    if not found then break end
    local rel = found - 1
    local distance = math.abs(rel - rel_start)
    if not best_distance or distance < best_distance then
      best_rel, best_distance = rel, distance
    end
    search_from = found + 1
  end
  if best_rel then return a + best_rel, a + best_rel + #needle end
  return nil
end

local function apply_replace(marker, s, e, a, b, len, edit)
  local old_len = b - a
  local delta = len - old_len
  if b <= s then return s + delta, e + delta end
  if a >= e then return s, e end
  if a <= s and b >= e then
    local ps, pe = find_preserved_range_in_replacement(marker, s, e, a, edit)
    if ps then return ps, pe end
    return nil, nil, "consumed-by-edit"
  end
  if a <= s and b < e then
    local ns = a + len
    local ne = e + delta
    if ne < ns then return nil, nil, "collapsed-by-prefix-edit" end
    return ns, ne
  end
  if a > s and b >= e then
    local ne = a
    if ne < s then return nil, nil, "collapsed-by-suffix-edit" end
    return s, ne
  end
  local ne = e + delta
  if ne < s then return nil, nil, "collapsed-by-inner-edit" end
  return s, ne
end

function Marker:update_for_transaction(transaction)
  if not self.valid then return false end
  local edits = transaction and transaction.edits or {}
  if #edits == 0 then return false end
  local old_start, old_end = self.start_offset, self.end_offset
  local s, e = old_start, old_end
  local delta = 0
  for _, edit in ipairs(edits) do
    local a = (edit.start_offset or 0) + delta
    local b = (edit.end_offset or edit.start_offset or 0) + delta
    local len = #(edit.text or "")
    local ns, ne, reason
    if a == b then
      ns, ne = apply_insert(self, s, e, a, len, edit.text)
    else
      ns, ne, reason = apply_replace(self, s, e, a, b, len, edit)
    end
    if not ns then
      self:invalidate(reason)
      return true
    end
    s, e = ns, ne
    delta = delta + len - (b - a)
  end
  local lines = self.doc and self.doc.lines or { "\n" }
  local _, total = line_starts_for(lines)
  s = common.clamp(s, 0, total)
  e = common.clamp(e, 0, total)
  if e < s then s, e = e, s end
  local changed = s ~= old_start or e ~= old_end
  self.start_offset, self.end_offset = s, e
  if changed then
    bump_generation()
    notify_marker_changed(self, "transaction")
  end
  return changed
end

local function doc_store(doc)
  local store = stores[doc]
  if not store then
    store = { markers = {} }
    stores[doc] = store
  end
  return store
end

function range_marker.markers_for_doc(doc)
  return doc_store(doc).markers
end

function range_marker.new(doc, opts)
  opts = opts or {}
  assert(doc, "range marker requires a document")
  local start_offset, end_offset = offsets_for_doc_range(doc, opts.line1, opts.col1, opts.line2, opts.col2)
  local marker = setmetatable({
    doc = doc,
    start_offset = start_offset,
    end_offset = end_offset,
    valid = true,
    greedy_left = opts.greedy_left == true,
    greedy_right = opts.greedy_right == true,
    sticky_right = opts.sticky_right == true,
    sticky_right_on_newline = opts.sticky_right_on_newline == true,
    preserve_on_replace = opts.preserve_on_replace == true,
    kind = opts.kind,
    data = opts.data,
    on_change = opts.on_change,
  }, Marker)
  local markers = doc_store(doc).markers
  markers[#markers + 1] = marker
  bump_generation()
  notify_marker_changed(marker, "new")
  return marker
end

range_marker.add = range_marker.new

function range_marker.remove(marker)
  if not marker then return false end
  local doc = marker.doc
  local store = doc and stores[doc]
  if store then
    for i = #store.markers, 1, -1 do
      if store.markers[i] == marker then
        table.remove(store.markers, i)
        break
      end
    end
  end
  local was_valid = marker.valid
  marker.valid = false
  marker.invalid_reason = marker.invalid_reason or "removed"
  if was_valid then
    bump_generation()
    notify_marker_changed(marker, "removed")
  end
  return was_valid
end

function range_marker.update_doc(doc, transaction)
  local store = stores[doc]
  if not store then return 0 end
  local changed = 0
  for _, marker in ipairs(store.markers) do
    if marker:update_for_transaction(transaction) then changed = changed + 1 end
  end
  if changed > 0 and core and core.log_quiet then
    core.log_quiet("Updated %d range marker(s) for %s", changed, doc:get_name())
  end
  return changed
end

if Doc.register_text_transaction_handler then
  Doc.register_text_transaction_handler("range_marker", range_marker.update_doc)
else
  local old_on_text_transaction = Doc.on_text_transaction
  function Doc:on_text_transaction(transaction)
    old_on_text_transaction(self, transaction)
    range_marker.update_doc(self, transaction)
  end
end

return range_marker
