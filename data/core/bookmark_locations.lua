-- Resolve saved locations without choosing between equally plausible lines.
local locations = {}

local function text(line)
  return (line or ""):gsub("[\r\n]+$", "")
end

local function context_matches(saved, line)
  -- Blank lines and punctuation alone do not identify a saved location.
  return saved ~= nil and saved:find("[^%s%p]") ~= nil and text(line) == saved
end

function locations.resolve(lines, records, cancelled)
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
    local best, score, tied = nil, -1, false
    for _, line in ipairs(not record.location_deleted and index[record.text or ""] or {}) do
      local candidate_score = 0
      if context_matches(record.before, lines[line - 1]) then candidate_score = candidate_score + 1 end
      if context_matches(record.after, lines[line + 1]) then candidate_score = candidate_score + 1 end
      if candidate_score > score then best, score, tied = line, candidate_score, false
      elseif candidate_score == score then tied = true end
    end
    local has_context = record.before ~= nil or record.after ~= nil
    local ready = best ~= nil and not tied and (not has_context or score > 0)
    results[#results + 1] = {
      id = record.id, line = ready and best or nil,
      status = ready and "ready" or "location_missing",
      text = record.text, before = record.before, after = record.after,
    }
  end
  return results
end

return locations
