-- Resolve saved locations without choosing between equally plausible lines.
local diff = require "diff"
local locations = { recovery_limit = 8 * 1024 * 1024 }

local function text(line)
  return (line or ""):gsub("[\r\n]+$", "")
end

function locations.capture(lines, line)
  local before, after = {}, {}
  for offset = 1, 3 do
    if lines[line - offset] then before[offset] = text(lines[line - offset]) end
    if lines[line + offset] then after[offset] = text(lines[line + offset]) end
  end
  return before, after
end

local function context_matches(saved, lines, line, direction)
  local content = false
  for offset, value in ipairs(saved or {}) do
    -- Blank lines and punctuation alone do not identify a saved location.
    if value:find("[^%s%p]") then
      local matches = lines[line + offset * direction] and text(lines[line + offset * direction]) == value
      if not matches then return false, true end
      content = true
    end
  end
  return true, content
end

-- Strings are immutable. Copy only the line array at a retained text boundary.
function locations.snapshot(lines)
  local copy, size = {}, 0
  for index, line in ipairs(lines) do
    size = size + #line
    if size > locations.recovery_limit then return nil end
    copy[index] = line
  end
  return { lines = copy }
end

local function line_index(lines, cancelled)
  local index = {}
  for line, value in ipairs(lines) do
    if cancelled and cancelled() then return nil end
    local candidates = index[value] or {}
    candidates[#candidates + 1] = line
    index[value] = candidates
  end
  return index
end

local function same_lines(a, b)
  if #a ~= #b then return false end
  for line, value in ipairs(a) do if value ~= b[line] then return false end end
  return true
end

local function snapshot_source(snapshot, current, cancelled)
  local lines = snapshot.lines
  local source = { lines = lines, equal = same_lines(lines, current), regions = {} }
  if source.equal then return source end
  source.index = line_index(lines, cancelled)
  if not source.index then return nil end
  source.before, source.after = {}, {}
  local anchor
  for line, value in ipairs(lines) do
    source.before[line] = anchor
    if #source.index[value] == 1 and value:find("[^%s%p]") then anchor = line end
  end
  anchor = nil
  for line = #lines, 1, -1 do
    source.after[line] = anchor
    local value = lines[line]
    if #source.index[value] == 1 and value:find("[^%s%p]") then anchor = line end
  end
  return source
end

local function slice(lines, first, last)
  local out = {}
  for line = first, last do out[#out + 1] = lines[line] end
  return out
end

local function unique_block(haystack, block, cancelled)
  local from, found = 1, false
  while true do
    if cancelled and cancelled() then return false end
    local start = haystack:find(block, from, true)
    if not start then return found end
    if start == 1 or haystack:sub(start - 1, start - 1) == "\n" then
      if found then return false end
      found = true
    end
    from = start + 1
  end
end

local function region_mapping(old, first, last, current, new_first, new_last, cancelled)
  local a, b = slice(old, first, last), slice(current, new_first, new_last)
  local region = { map = {}, a = table.concat(a), b = table.concat(b) }
  local old_line, new_line, run = first, new_first, nil
  for edit in diff.diff_iter(a, b) do
    if cancelled and cancelled() then return nil end
    if edit.tag == "equal" then
      if not run then run = { first = old_line } end
      run.last = old_line
      region.map[old_line] = { line = new_line, run = run }
    else
      -- Reindentation and replacement matches from the display diff are not identities.
      run = nil
    end
    if edit.a then old_line = old_line + 1 end
    if edit.b then new_line = new_line + 1 end
  end
  return region
end

local function occurrences(index, value, first, last)
  local count = 0
  for _, line in ipairs(index[value] or {}) do
    if line >= first and line <= last then count = count + 1 end
  end
  return count
end

local function map_snapshot(source, current, current_index, record, cancelled)
  local old, line = source.lines, record.line
  if not old[line] or text(old[line]) ~= record.text then return nil end
  if source.equal then return line end
  local before, after = source.before[line], source.after[line]
  local function anchor_position(anchor, boundary)
    if not anchor then return boundary end
    local matches = current_index[old[anchor]]
    if matches and #matches == 1 then return matches[1] end
  end
  local new_first = anchor_position(before, 1)
  local new_last = anchor_position(after, #current)
  if not new_first or not new_last or new_first > new_last then return nil end
  local first, last = before or 1, after or #old
  -- An added or removed copy makes the diff's chosen occurrence uncertain.
  if occurrences(source.index, old[line], first, last)
      ~= occurrences(current_index, old[line], new_first, new_last) then return nil end
  local key = tostring(first) .. ":" .. tostring(last)
  local region = source.regions[key]
  if not region then
    region = region_mapping(old, first, last, current, new_first, new_last, cancelled)
    if not region then return nil end
    source.regions[key] = region
  end
  local mapped = region.map[line]
  if not mapped then return nil end
  local run = mapped.run
  if run.unique == nil then
    local block = table.concat(old, "", run.first, run.last)
    run.unique = block:find("[^%s%p]") ~= nil
      and unique_block(region.a, block, cancelled) and unique_block(region.b, block, cancelled)
  end
  return run.unique and mapped.line or nil
end

function locations.resolve(lines, records, cancelled, snapshots)
  local fingerprint, current_index, index
  local sources = {}
  local results = {}
  for _, record in ipairs(records) do
    if cancelled and cancelled() then return nil end
    local best, tied = nil, false
    if not record.location_deleted and not record.recovery_unavailable then
      if record.snapshot then
        local snapshot = snapshots and snapshots[record.snapshot]
        if snapshot then
          local source = sources[record.snapshot]
          if not source then
            source = snapshot_source(snapshot, lines, cancelled)
            if not source then return nil end
            sources[record.snapshot] = source
          end
          if not source.equal and not current_index then
            current_index = line_index(lines, cancelled)
            if not current_index then return nil end
          end
          best = map_snapshot(source, lines, current_index, record, cancelled)
        end
      else
        if record.fingerprint and not fingerprint then
          fingerprint = encoding.fingerprint_lines(lines, locations.recovery_limit)
        end
        if fingerprint and record.fingerprint == fingerprint and record.status == "ready"
            and lines[record.line] and text(lines[record.line]) == record.text then
          best = record.line
        else
          if not index then
            index = {}
            for line, value in ipairs(lines) do
              if cancelled and cancelled() then return nil end
              value = text(value)
              local candidates = index[value] or {}
              candidates[#candidates + 1] = line
              index[value] = candidates
            end
          end
          for _, line in ipairs(index[record.text or ""] or {}) do
            if cancelled and cancelled() then return nil end
            local before_matches, before_content = context_matches(record.before, lines, line, -1)
            local after_matches, after_content = context_matches(record.after, lines, line, 1)
            local no_context = #(record.before or {}) == 0 and #(record.after or {}) == 0
            if before_matches and after_matches and (before_content or after_content or no_context) then
              if best then tied = true; break end
              best = line
            end
          end
        end
      end
    end
    local ready = best ~= nil and not tied
    local before, after
    if ready then before, after = locations.capture(lines, best) end
    results[#results + 1] = {
      id = record.id, line = ready and best or nil,
      status = ready and "ready" or "location_missing",
      text = record.text, before = before, after = after,
    }
  end
  return results
end

return locations
