local common = require "core.common"

local worker = {}

function worker.run(payload, context)
  if payload.operation == "stat" then
    local info = {}
    for _, path in ipairs(payload.paths) do
      if context.cancelled() then return end
      info[path] = system.get_file_info(path) or false
    end
    context.send { type = "result", payload = info }
    return
  end

  assert(payload.operation == "directories", "Unknown Project file operation")
  local pending = { payload.root }
  local chunk = {}
  while #pending > 0 do
    if context.cancelled() then return end
    local directory = table.remove(pending)
    -- Enumeration supplies metadata on Windows. Avoid opening each directory again.
    local metadata = PLATFORM == "Windows"
    local entries, err = system.list_dir_info(directory, 2147483647, "dir", nil, metadata)
    if not entries and directory == payload.root then error(err or "Cannot list Project root") end
    for _, entry in ipairs(entries or {}) do
      if context.cancelled() then return end
      local name = entry.name
      if name and name ~= "" and name:sub(1, 1) ~= "." then
        local path = common.normalize_path(directory .. PATHSEP .. name)
        local info = metadata and entry or system.get_file_info(path)
        local key = common.path_compare_key(path)
        if info and info.type == "dir" and info.symlink ~= nil and not payload.hidden_paths[key] then
          local ignored = payload.ignored_paths[key] == true
          local searchable = not info.symlink and not ignored
          chunk[#chunk + 1] = { path = path, key = key, searchable = searchable, ignored = ignored }
          if searchable then pending[#pending + 1] = path end
          if #chunk >= 64 then
            if not context.send { type = "result", payload = chunk } then return end
            chunk = {}
          end
        end
      end
    end
  end
  if #chunk > 0 then context.send { type = "result", payload = chunk } end
end

return worker
