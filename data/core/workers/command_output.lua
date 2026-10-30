local locations = require "core.text_poi_locations"

local worker = {}

-- The command line remains first, so its own file arguments are not results.
local function latest_run_text(text, command)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  for index = #lines, 1, -1 do
    if lines[index]:find(command, 1, true) then return table.concat(lines, "\n", index) end
  end
  return command .. "\n" .. text
end

function worker.run(payload, context)
  local text = latest_run_text(payload.text, payload.command)
  if context.cancelled() then return end
  local candidates = locations.extract_candidates(text)
  if context.cancelled() then return end
  local points = {}
  for _, candidate in ipairs(candidates) do
    if context.cancelled() then return end
    if candidate.line > 1 then
      local point = locations.resolve_candidate(candidate, payload.root, "terminal-location")
      if point then points[#points + 1] = point end
    end
  end
  context.send { type = "result", payload = { text = text, points = points } }
end

return worker
