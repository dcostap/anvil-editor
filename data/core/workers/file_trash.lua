local worker = {}

function worker.run(payload, context)
  if context.cancelled() then return end
  local success, err = system.trash_files(payload.paths)
  context.send { type = "final", payload = { success = success, error = err } }
end

return worker
