-- mod-version:3
-- Counts direct children outside the draw loop.
local core = require "core"
local common = require "core.common"
local counts = {}
local cache, pending, queue = {}, {}, {}
local running = false

function counts.get(path, modified, show_hidden)
  local key = (show_hidden and "1" or "0") .. "\0" .. common.path_compare_key(path)
  local cached = cache[key]
  if cached and cached.modified == modified then return cached end
  if not pending[key] then
    local task = { path = path, key = key, modified = modified, show_hidden = show_hidden }
    pending[key] = task
    queue[#queue + 1] = task
  end
  if not running then
    running = true
    core.add_thread(function()
      while #queue > 0 do
        local task = table.remove(queue, 1)
        local info = system.get_file_info(task.path)
        if info and info.type == "dir" and info.modified == task.modified then
          local entries, err = system.list_dir_info(task.path, 2147483647, nil, nil, true)
          local total, start = 0, system.get_time()
          for _, entry in ipairs(entries or {}) do
            if entry.modified ~= nil and (task.show_hidden or entry.name:sub(1, 1) ~= ".")
                and (entry.type == "file" or entry.type == "dir") then
              total = total + 1
            end
            if system.get_time() - start >= 0.004 then
              coroutine.yield(0)
              start = system.get_time()
            end
          end
          local latest = system.get_file_info(task.path)
          if latest and latest.type == "dir" and latest.modified == task.modified then
            cache[task.key] = { modified = task.modified, count = entries and total or nil, error = err }
            if not entries then
              core.log_quiet("Folder count failed for %s: %s", task.path, err or "cannot list directory")
            end
            core.redraw = true
          end
        end
        pending[task.key] = nil
        coroutine.yield(0)
      end
      running = false
    end)
  end
  return nil, true
end

return counts
