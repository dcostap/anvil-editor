local system = require "system"
local json = require "core.json"
local function same(a, b)
  return type(a) == "string" and a:gsub("\\", "/"):lower() == b:gsub("\\", "/"):lower()
end

return {run = function(payload, ctx)
  local found = {}
  for _, name in ipairs(system.list_dir(payload.directory) or {}) do
    if ctx.cancelled() or #found >= 128 then break end
    if name:match("^%d+%.json$") then
      local file = io.open(payload.directory .. "/" .. name, "rb")
      local text = file and file:read(8193)
      if file then file:close() end
      local ok, value = pcall(json.decode, text or "")
      if ok and text and #text <= 8192 and type(value) == "table" and value.version == 1
          and type(value.project) == "string" and same(value.executable, payload.executable)
          and type(value.url) == "string" and value.url:match("^http://127%.0%.0%.1:%d+$")
          and type(value.token) == "string" and #value.token == 64 and value.token:match("^[0-9a-f]+$") then
        found[#found + 1] = value
      end
    end
  end
  ctx.send {type = "result", payload = {endpoints = found}}
end}
