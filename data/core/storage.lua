local common = require "core.common"

-- Workers use the same replacement rules without loading editor or UI state.
-- Worker callers report returned errors on the UI thread.
local function log(level, ...)
  local core = package.loaded.core
  if type(core) == "table" and core[level] then core[level](...) end
end

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


-- While another process replaces a file, Windows refuses to open it for a moment.
local OPEN_RETRY_DELAYS = { 0.005, 0.01, 0.02, 0.04 }

local function load_file(path)
  local func, err = loadfile(path)
  for _, delay in ipairs(OPEN_RETRY_DELAYS) do
    if func or not tostring(err):find("cannot open", 1, true) or not system.get_file_info(path) then break end
    system.sleep(delay)
    func, err = loadfile(path)
  end
  return func, err
end


---Loads data from a persistent storage file.
---
---@param module string The module under which the data is stored.
---@param key string The key under which the data is stored.
---@return string|table|number? data The stored data present for this module, at this key.
function storage.load(module, key)
  local path = module_key_to_path(module, key)
  if system.get_file_info(path) then
    local func, err = load_file(path)
    if func then
      return func()
    else
      log("error", "error loading storage file for %s[%s]: %s", module, key, err)
    end
  end
  return nil
end


---Saves data to a persistent storage file.
---
---@param module string The module under which the data is stored.
---@param key string The key under which the data is stored.
---@param value table|string|number The value to store.
---@return boolean success
---@return string? error
function storage.save(module, key, value)
  local path = module_key_to_path(module, key)
  local dir = common.dirname(path)
  if not system.get_file_info(dir) then
    local status, err = common.mkdirp(dir)
    if not status then
      log("error", "error creating storage directory for %s at %s: %s", module, dir, err)
      return false, err
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
      -- Other processes read some keys while they change, so the file must never be missing during a replace.
      local renamed, rename_err = system.replace_file(tmp, path)
      if not renamed then
        os.remove(tmp)
        log("error", "error replacing storage file %s: %s", path, rename_err)
        return false, rename_err
      end
      return true
    else
      pcall(function() f:close() end)
      os.remove(tmp)
      log("error", "error writing storage file %s: %s", path, write_err)
      return false, write_err
    end
  else
    log("error", "error opening storage file %s for writing: %s", tmp, err)
    return false, err
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
