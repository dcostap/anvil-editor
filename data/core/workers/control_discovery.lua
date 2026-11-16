local system = require "system"
local json = require "core.json"
local function same(a, b)
  return type(a) == "string" and a:gsub("\\", "/"):lower() == b:gsub("\\", "/"):lower()
end

local function read(path)
  local file = io.open(path, "rb")
  local text = file and file:read(8193)
  if file then file:close() end
  local ok, value = pcall(json.decode, text or "")
  if ok and text and #text <= 8192 and type(value) == "table" and value.version == 1 then return value end
end

-- A Project process that ends without its exit path, such as in a crash or a Windows shutdown, leaves its record.
-- Only a process that runs with the record's ID and creation time serves the record. A record whose process
-- ended goes, with the Terminal records that name its endpoint. A record that this check cannot prove stays.
return {run = function(payload, ctx)
  local found, ended, live = {}, {}, {}
  for _, name in ipairs(system.list_dir(payload.directory) or {}) do
    if ctx.cancelled() or #found >= 128 then break end
    local path = payload.directory .. "/" .. name
    local value = name:match("^%d+%.json$") and read(path)
    if value and type(value.pid) == "number" and value.pid == math.floor(value.pid) then
      local state = system.process_state(value.pid, type(value.created) == "string" and value.created or nil)
      if state == "ended" then
        os.remove(path)
        if type(value.url) == "string" then ended[value.url] = true end
      elseif type(value.url) == "string" then
        live[value.url] = true
        if state == "running" and type(value.project) == "string" and same(value.executable, payload.executable)
            and value.url:match("^http://127%.0%.0%.1:%d+$")
            and type(value.token) == "string" and #value.token == 64 and value.token:match("^[0-9a-f]+$") then
          found[#found + 1] = value
        end
      end
    end
  end
  if next(ended) then
    local directory = payload.directory .. "/terminals"
    for _, name in ipairs(system.list_dir(directory) or {}) do
      local value = name:match("^[0-9a-f]+%.json$") and read(directory .. "/" .. name)
      if value and ended[value.url] and not live[value.url] then os.remove(directory .. "/" .. name) end
    end
  end
  ctx.send {type = "result", payload = {endpoints = found}}
end}
