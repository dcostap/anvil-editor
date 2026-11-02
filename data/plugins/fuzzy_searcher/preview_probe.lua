-- Preview probe: decide on a worker if a selected file can have a text preview.
-- The probe reads the file's size and first bytes. A busy disk or a virus scan can make
-- that take seconds, so the UI thread must not do it.
-- This module runs in worker Lua states. It must not require UI modules.
local common = require "core.common"

local probe = {}

local HEAD_BYTES = 8192

---Return true and a reason when the first bytes of a file show that it is not text.
function probe.classify(head)
  if head:sub(1, 4) == "%PDF" then return true, "PDF file" end
  if head:sub(1, 2) == "MZ" then return true, "Windows executable" end
  if head:sub(1, 4) == "PK\003\004" then return true, "ZIP container" end
  if head:sub(1, 4) == "\127ELF" then return true, "ELF binary" end
  if common.is_binary(head) then return true, "Binary file" end
  return false, nil
end

---Worker job. `payload.path` is the file and `payload.max_bytes` the largest text preview.
function probe.run(payload, context)
  local result = { blocked = false }
  local info = system.get_file_info(payload.path)
  if info and info.size and info.size > payload.max_bytes then
    result.blocked, result.reason = true, string.format("Large file (%.1f MB)", info.size / 1024 / 1024)
  else
    local file = io.open(payload.path, "rb")
    if not file then
      result.blocked, result.reason = true, "Cannot open file"
    else
      local head = file:read(HEAD_BYTES) or ""
      file:close()
      result.blocked, result.reason = probe.classify(head)
    end
  end
  context.send { type = "final", payload = result }
end

return probe
