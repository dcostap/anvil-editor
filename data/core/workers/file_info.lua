-- Read the information of many files away from the UI thread.
-- `infos[i]` belongs to `paths[i]`. It is false for a path that does not exist.
local worker = {}

function worker.run(payload, context)
  local infos = {}
  for index, path in ipairs(payload.paths) do
    if context.cancelled() then return end
    local info = system.get_file_info(path)
    infos[index] = info and { type = info.type, size = info.size, modified = info.modified } or false
  end
  context.send { type = "final", payload = { infos = infos } }
end

return worker
