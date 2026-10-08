local storage = require "core.storage"
local worker = {}

-- Flush and Project close also use this writer after pending worker writes finish.
function worker.write(key, saved)
  for index, lines in ipairs(saved.snapshots) do saved.snapshots[index] = table.concat(lines) end
  return storage.save("bookmarks", key, saved)
end

function worker.run(payload, context)
  if context.cancelled() then return end
  USERDIR = payload.userdir
  local success, err = worker.write(payload.key, payload.saved)
  context.send { type = "result", payload = { success = success, error = err } }
end

return worker
