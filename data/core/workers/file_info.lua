-- Read the information of many files away from the UI thread.
-- `infos[i]` belongs to `paths[i]`. It is false for a path that does not exist.
local worker = {}

local function has_line(path, line, context)
  local file = io.open(path, "rb")
  if not file then return false end
  local found = false
  while not context.cancelled() do
    local text = file:read(65536)
    if not text then break end
    local _, breaks = text:gsub("\n", "")
    if breaks + (text:sub(-1) ~= "\n" and 1 or 0) >= line then found = true; break end
    line = line - breaks
  end
  file:close()
  return found
end

function worker.run(payload, context)
  local infos = {}
  for index, path in ipairs(payload.paths) do
    if context.cancelled() then return end
    local info = system.get_file_info(path)
    if info and payload.line and not has_line(path, payload.line, context) then info = nil end
    infos[index] = info and { type = info.type, size = info.size, modified = info.modified } or false
  end
  context.send { type = "final", payload = { infos = infos } }
end

return worker
