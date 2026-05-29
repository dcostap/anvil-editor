local core = require "core"
local common = require "core.common"

local function module_key_to_path(module, key)
  local path = USERDIR .. PATHSEP .. "storage"
  if module then
    path = path .. PATHSEP .. common.encode_filename_component(module)
    if key then
      path = path .. PATHSEP .. common.encode_filename_component(key)
    end
  end
  return path
end


---Provides persistent storage between restarts of the application.
---@class storage
local storage = {}


---Loads data from a persistent storage file.
---
---@param module string The module under which the data is stored.
---@param key string The key under which the data is stored.
---@return string|table|number? data The stored data present for this module, at this key.
local function latest_backup_for(path)
  local dir = common.dirname(path)
  local base = common.basename(path)
  local items = system.list_dir(dir)
  if not items then return nil end
  local prefix = base .. ".bak-"
  local best, best_time
  for _, item in ipairs(items) do
    if item:sub(1, #prefix) == prefix then
      local backup = dir .. PATHSEP .. item
      local info = system.get_file_info(backup)
      if info and (not best_time or info.modified > best_time) then
        best, best_time = backup, info.modified
      end
    end
  end
  return best
end

function storage.load(module, key)
  local path = module_key_to_path(module, key)
  if not system.get_file_info(path) then
    local backup = latest_backup_for(path)
    if backup then
      local restored, err = os.rename(backup, path)
      if restored then
        core.log("restored storage backup %s", backup)
      else
        core.error("error restoring storage backup %s: %s", backup, err)
      end
    end
  end
  if system.get_file_info(path) then
    local func, err = loadfile(path)
    if func then
      return func()
    else
      core.error("error loading storage file for %s[%s]: %s", module, key, err)
    end
  end
  return nil
end


---Saves data to a persistent storage file.
---
---@param module string The module under which the data is stored.
---@param key string The key under which the data is stored.
---@param value table|string|number The value to store.
function storage.save(module, key, value)
  local path = module_key_to_path(module, key)
  local dir = common.dirname(path)
  if not system.get_file_info(dir) then
    local status, err = common.mkdirp(dir)
    if not status then
      core.error("error creating storage directory for %s at %s: %s", module, dir, err)
    end
  end
  local function check_io(ok, err)
    if not ok then error(err or "I/O error") end
    return ok
  end
  local tmp = path .. ".tmp-" .. tostring(math.floor(system.get_time() * 1000000))
  local f, err = io.open(tmp, "wb")
  if f then
    local ok, write_err = pcall(function()
      check_io(f:write("return " .. common.serialize(value, {pretty = true})))
      check_io(f:flush())
      check_io(f:close())
    end)
    if ok then
      local renamed, rename_err = os.rename(tmp, path)
      if not renamed and system.get_file_info(path) then
        local backup = path .. ".bak-" .. tostring(math.floor(system.get_time() * 1000000))
        local moved_old, move_old_err = os.rename(path, backup)
        if moved_old then
          renamed, rename_err = os.rename(tmp, path)
          if renamed then
            local removed, remove_err = os.remove(backup)
            if not removed then core.error("error deleting storage backup %s: %s", backup, remove_err) end
          else
            pcall(os.rename, backup, path)
          end
        else
          rename_err = move_old_err
        end
      end
      if not renamed then
        os.remove(tmp)
        core.error("error replacing storage file %s: %s", path, rename_err)
      end
    else
      pcall(function() f:close() end)
      os.remove(tmp)
      core.error("error writing storage file %s: %s", path, write_err)
    end
  else
    core.error("error opening storage file %s for writing: %s", tmp, err)
  end
end


---Gets the list of keys saved under a module.
---
---@param module string The module under which the data is stored.
---@return table A table of keys under which data is stored for this module.
function storage.keys(module)
  local keys = system.list_dir(module_key_to_path(module)) or {}
  for i, key in ipairs(keys) do
    keys[i] = common.decode_filename_component(key)
  end
  return keys
end


---Clears data for a particular module and optionally key.
---
---@param module string The module under which the data is stored.
---@param key? string The key under which the data is stored. If omitted, will clear the entire store for this module.
function storage.clear(module, key)
  local path = module_key_to_path(module, key)
  if system.get_file_info(path) then
    common.rm(path, true)
  end
end


return storage
