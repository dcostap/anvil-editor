local locations = require "core.text_poi_locations"

local worker = {}

function worker.run(payload, context)
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
        if not context.send { type = "chunk", payload = candidates } then return end
        candidates = {}
      end
    end
  end
  if #candidates > 0 then context.send { type = "chunk", payload = candidates } end
end

return worker
