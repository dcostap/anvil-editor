-- Folder listings of a Project on a Machine, for code that lists folders without a wait, such as the File Tree.
-- A listing that is not here yet comes from `files.list_dir`. A watch (same methods as `core.dirwatch`) then
-- reports the folder, so its owner lists it again. Change notices of `core.project_files` make listings stale.
local common = require "core.common"
local core = require "core"
local fs = require "core.fs"
local project_files = require "core.project_files"

local machine_folders = {}

local listings, folder_paths, loading, subscribed = {}, {}, {}, {}
local watches = setmetatable({}, { __mode = "k" })

local function key(path) return common.path_compare_key(common.normalize_path(path)) end

local function report(path)
  local folder = key(path)
  for watch in pairs(watches) do
    if watch.dirs[folder] then watch.pending[folder] = watch.dirs[folder] end
  end
end

local function fetch(path)
  local folder = key(path)
  if loading[folder] then return end
  loading[folder], folder_paths[folder] = true, common.normalize_path(path)
  fs.list_dir(path, function(err, entries)
    loading[folder] = nil
    if err then core.log_quiet("Machine folder listing failed: %s: %s", path, tostring(err.message or err.code)) end
    -- A folder that the Machine cannot list shows empty.
    listings[folder] = entries or {}
    report(path)
  end)
end

-- Change notices name changed paths. Each changed path makes its folder's listing stale.
local function subscribe(root)
  local root_key = key(root)
  if subscribed[root_key] then return end
  subscribed[root_key] = root
  project_files.subscribe(root, "machine-folders", function(paths)
    for name, value in pairs(paths) do
      local path = type(name) == "number" and value or name
      if type(path) == "string" then
        local folder = common.dirname(path)
        if folder and listings[key(folder)] ~= nil then fetch(folder) end
      end
    end
  end)
  -- The Machine's change notices start after the first scan of the Project.
  core.add_thread(function() project_files.list(root) end)
end

local function root_of(path)
  for _, root in ipairs(fs.roots or {}) do
    if common.path_equals(path, root) or common.path_belongs_to(path, root) then return root end
  end
end

-- Returns the entries of the folder as `system.list_dir_info` does, or nil while the listing loads.
function machine_folders.list(path)
  local root = root_of(path)
  if root then subscribe(root) end
  local listing = listings[key(path)]
  if listing == nil then fetch(path) end
  return listing
end

-- Waits in this coroutine until the folder's listing arrives, and returns it.
function machine_folders.wait(path)
  local listing = machine_folders.list(path)
  while listing == nil do
    coroutine.yield(0.02)
    listing = machine_folders.list(path)
  end
  return listing
end

local Watch = {}
Watch.__index = Watch

function Watch:watch(path) self.dirs[key(path)] = common.normalize_path(path) end
function Watch:unwatch(path) self.dirs[key(path)], self.pending[key(path)] = nil, nil end

-- Calls `on_change(dir, path, precise, kind)` for each watched folder whose listing arrived or changed.
function Watch:check(on_change)
  local pending = self.pending
  self.pending = {}
  for _, path in pairs(pending) do on_change(path, path, true, "unknown") end
end

function machine_folders.watch()
  local watch = setmetatable({ dirs = {}, pending = {} }, Watch)
  watches[watch] = true
  return watch
end

-- After a reconnect, each listing can be old. The old listing stays until the new one arrives.
fs.on_reconnect(function()
  for _, path in pairs(folder_paths) do fetch(path) end
end)

-- Forgets all listings, for example when the Project process stops using its Machine.
function machine_folders.clear()
  for _, root in pairs(subscribed) do project_files.unsubscribe(root, "machine-folders") end
  listings, folder_paths, loading, subscribed = {}, {}, {}, {}
end

return machine_folders
