local locations = require "core.text_poi_locations"

local worker = {}

local function publish(candidates, payload, context)
  local points = locations.resolve_candidates(candidates, payload.roots, "editor-file-location", context.cancelled)
  if not points then return false end
  return context.send { type = "chunk", payload = {
    candidates = payload.lines and candidates or nil,
    points = points,
  } }
end

function worker.run(payload, context)
  if payload.candidates then
    local batch = {}
    for _, candidate in ipairs(payload.candidates) do
      batch[#batch + 1] = candidate
      if #batch >= 128 then
        if not publish(batch, payload, context) then return end
        batch = {}
      end
    end
    if #batch > 0 then publish(batch, payload, context) end
    return
  end
  local candidates, count = {}, 0
  for index, text in ipairs(payload.lines) do
    if context.cancelled() or count >= payload.limit then return end
    local found = locations.extract_line_candidates(
      text, payload.first + index - 1, payload.limit - count
    )
    for _, candidate in ipairs(found) do
      candidates[#candidates + 1] = candidate
      count = count + 1
      if #candidates >= 128 then
        if not publish(candidates, payload, context) then return end
        candidates = {}
      end
    end
  end
  if #candidates > 0 then publish(candidates, payload, context) end
end

return worker
