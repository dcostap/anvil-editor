local common = require "core.common"
local Object = require "core.object"
local project_files = require "core.project_files"

---Core projects class.
---@class core.project : core.object
---@overload fun(path:string):core.project
---@field path string
---@field name string
local Project = Object:extend()


---Constructor
function Project:new(path)
  self.path = common.normalize_volume(common.normalize_path(path) or path)
  self.name = common.basename(self.path)
end


---The method works like system.absolute_path except it doesn't fail if the
---file does not exist. We consider that the current dir is core.project_dir
---so relative filename are considered to be in core.project_dir.
---
---Please note that .. or . in the filename are not taken into account.
---This function should get only filenames normalized using
---common.normalize_path function.
---@param filename string
---@return string|nil
function Project:absolute_path(filename)
  if common.is_absolute_path(filename) then
    return common.normalize_path(filename)
  elseif not self or not self.path then
    local cwd = system.absolute_path(".")
    return cwd .. PATHSEP .. common.normalize_path(filename)
  else
    return self.path .. PATHSEP .. filename
  end
end


---Same as common.normalize_path() with the addition of making the filename
---relative when it belongs to the project.
---@param filename string|nil
---@return string|nil
function Project:normalize_path(filename)
  filename = common.normalize_path(filename)
  if common.path_belongs_to(filename or "", self.path) then
    filename = common.relative_path(self.path, filename or "")
  end
  return filename
end


---Checks if the given path belongs to the project.
---@param path string
---@return boolean
function Project:path_belongs_to(path)
  if not common.is_absolute_path(path) then
    path = common.normalize_path(self.path .. PATHSEP .. path)
    if not path or not system.get_file_info(path) then
      return false
    end
    return true
  end
  if common.path_belongs_to(path, self.path) then
    return true
  end
  return false
end


---Compute a file's info entry completed with "filename" to be used
---in project scan or false if it shouldn't appear in the list.
---@param path string
---@return system.fileinfo|false
function Project:get_file_info(path)
  local info = system.get_file_info(path)
  -- info can be not nil but info.type may be nil if is neither a file neither
  -- a directory, for example for /dev/* entries on linux.
  if info and info.type then
    info.filename = common.relative_path(self.path, path)
    local included = project_files.contains(self.path, path, info.type)
    return included == false and false or info
  end
  return false
end

---Returns iterator of all project files.
---@return fun():core.project,string
function Project:files()
  return coroutine.wrap(function()
    local files = project_files.list(self.path) or {}
    for _, file in ipairs(files) do
      local info = system.get_file_info(file.path)
      if info and info.type == "file" then
        info.filename = file.path
        coroutine.yield(self, info)
      end
    end
  end)
end


return Project
