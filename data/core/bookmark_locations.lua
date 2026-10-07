-- Resolve saved locations without choosing between equally plausible lines.
local locations = {}

local function text(line)
  return (line or ""):gsub("[\r\n]+$", "")
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
    for _, line in ipairs(index[record.text or ""] or {}) do
      local candidate_score = 0
      if record.before ~= nil and text(lines[line - 1]) == record.before then candidate_score = candidate_score + 1 end
      if record.after ~= nil and text(lines[line + 1]) == record.after then candidate_score = candidate_score + 1 end
      if candidate_score > score then best, score, tied = line, candidate_score, false
      elseif candidate_score == score then tied = true end
    end
    results[#results + 1] = {
      id = record.id, line = not tied and best or nil,
      status = best and not tied and "ready" or "location_missing",
      text = record.text, before = record.before, after = record.after,
    }
  end
  return results
end

return locations
