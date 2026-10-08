-- Resolve saved locations without choosing between equally plausible lines.
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
  local content, score = false, 0
  for offset, value in ipairs(saved or {}) do
    -- Blank lines and punctuation alone do not identify a saved location.
    if value:find("[^%s%p]") then
      local matches = lines[line + offset * direction] and text(lines[line + offset * direction]) == value
      if not content and not matches then return false, true, score end
      content = true
      if matches then score = score + 1 end
    end
  end
  return true, content, score
end

function locations.resolve(lines, records, cancelled)
  local fingerprint = encoding.fingerprint_lines(lines, locations.recovery_limit)
  local index = {}
  for line, value in ipairs(lines) do
    if cancelled and cancelled() then return nil end
    value = text(value)
    local candidates = index[value] or {}
    candidates[#candidates + 1] = line
    index[value] = candidates
  end
  local results = {}
  for _, record in ipairs(records) do
    local best, tied, score = nil, false, -1
    if not record.location_deleted then
      if fingerprint and record.fingerprint == fingerprint and record.status == "ready"
          and lines[record.line] and text(lines[record.line]) == record.text then
        best = record.line
      else
        for _, line in ipairs(index[record.text or ""] or {}) do
          if cancelled and cancelled() then return nil end
          local before_matches, before_content, before_score = context_matches(record.before, lines, line, -1)
          local after_matches, after_content, after_score = context_matches(record.after, lines, line, 1)
          local no_context = #(record.before or {}) == 0 and #(record.after or {}) == 0
          if before_matches and after_matches and (before_content or after_content or no_context) then
            local candidate_score = before_score + after_score
            if candidate_score > score then best, score, tied = line, candidate_score, false
            elseif candidate_score == score then tied = true end
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
      fingerprint = ready and fingerprint or nil,
    }
  end
  return results
end

return locations
