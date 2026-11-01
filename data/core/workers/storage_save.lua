-- Write one storage key away from the UI thread.
local worker = {}

function worker.run(payload, context)
  if context.cancelled() then return end
  USERDIR = payload.userdir
  local storage = require "core.storage"
  local success, err = storage.save(payload.module, payload.key, payload.value)
  context.send { type = "final", payload = { success = success, error = err } }
end

return worker
