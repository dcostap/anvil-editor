-- Read a whole file away from the UI thread. The result is the file's bytes, or an error.
local worker = {}

function worker.run(payload, context)
  local file, err = io.open(payload.path, "rb")
  if not file then
    context.send { type = "final", payload = { error = err or "Cannot open file" } }
    return
  end
  local bytes = file:read("*a")
  file:close()
  if context.cancelled() then return end
  context.send { type = "final", payload = { bytes = bytes or "" } }
end

return worker
