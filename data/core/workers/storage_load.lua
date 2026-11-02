-- Read one storage key away from the UI thread.
local worker = {}

function worker.run(payload, context)
  USERDIR = payload.userdir
  local storage = require "core.storage"
  context.send { type = "final", payload = { value = storage.load(payload.module, payload.key) } }
end

return worker
