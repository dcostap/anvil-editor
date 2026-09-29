local scanner = require "core.local_find_scan"
local worker = {}

function worker.run(payload, context)
  local search, err = scanner.compile(payload.query, payload.regex, payload.case_sensitive)
  if not search then error(err) end
  local batch = {}
  local function flush()
    if #batch > 0 then context.send({ type = "chunk", payload = batch }); batch = {} end
  end
  scanner.line(payload.text, search, function(first, last)
    batch[#batch + 1], batch[#batch + 2] = first, last
    if #batch >= 1024 then flush() end
  end, function()
    if context.cancelled() then error("Find scan cancelled") end
  end)
  flush()
  context.send({ type = "complete" })
end

return worker
