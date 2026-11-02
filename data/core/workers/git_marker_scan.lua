-- Look for Git markers away from the UI thread. `found[i]` is true when `paths[i]` has a `.git` entry.
local worker = {}

function worker.run(payload, context)
  local found = {}
  for index, path in ipairs(payload.paths) do
    if context.cancelled() then return end
    local info = system.get_file_info(path .. PATHSEP .. ".git")
    found[index] = info ~= nil and info.type ~= nil
  end
  context.send { type = "final", payload = { found = found } }
end

return worker
