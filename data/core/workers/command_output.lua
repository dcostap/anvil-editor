local locations = require "core.text_poi_locations"
local location_list = require "core.file_location_list"

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
  local count = 0
  for _, candidate in ipairs(candidates) do
    if candidate.line > 1 then
      count = count + 1
      candidates[count] = candidate
    end
  end
  for index = #candidates, count + 1, -1 do candidates[index] = nil end
  local points = location_list.new(candidates, payload.root, "terminal-location", context.cancelled)
  if points then
    context.send { type = "final", payload = { text = text, locations = location_list.encode(points) } }
  end
end

return worker
