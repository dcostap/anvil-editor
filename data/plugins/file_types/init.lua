-- mod-version:3
-- File Types: the Windows file types that this anvil.exe opens.
-- Registration adds Anvil to "Open with" and to its own page in Windows Settings for each extension.
-- Windows does not let an app make itself the default, so the user picks Anvil as the default there.
-- All keys are under HKEY_CURRENT_USER, so registration needs no admin rights.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"

local M = {}

-- The key under HKEY_CURRENT_USER that holds Classes, the app's Capabilities and RegisteredApplications.
-- Tests use another key.
M.root = "Software"

-- The name of Anvil's entry in RegisteredApplications. The Settings page finds the app by this name.
local APP = "Anvil"

local function classes_key(path) return M.root .. "\\Classes\\" .. path end
local function capabilities_key() return M.root .. "\\" .. APP .. "\\Capabilities" end
local function associations_key() return capabilities_key() .. "\\FileAssociations" end
local function progid(extension) return APP .. "." .. extension end
local function open_command_key(extension) return classes_key(progid(extension) .. "\\shell\\open\\command") end

-- The executable in an open command such as `"C:\Anvil\anvil.exe" "%1"`.
local function command_executable(open_command)
  return open_command and (open_command:match('^"([^"]+)"') or open_command:match("^(%S+)"))
end

-- Which executable opens an extension: "this", "other", or nil when Anvil does not open it.
local function owner(extension, registered)
  if not registered["." .. extension] then return nil end
  local values = system.get_registry_values(open_command_key(extension))
  local executable = command_executable(values and values[""])
  if executable and common.path_compare_key(executable) == common.path_compare_key(EXEFILE) then return "this" end
  return "other"
end

---The file types in `config.plugins.file_types.types`, then each other extension that Anvil opens.
---A type is `checked` when this anvil.exe opens one of its extensions. It is `other` when another anvil.exe
---opens one of them and this one opens none.
---@return { name: string, extensions: string[], checked: boolean, other: boolean }[]
function M.types()
  local registered = system.get_registry_values(associations_key()) or {}
  local result, listed = {}, {}
  local function add(name, extensions)
    local row = { name = name, extensions = extensions, checked = false, other = false }
    for _, extension in ipairs(extensions) do
      listed[extension] = true
      local state = owner(extension, registered)
      row.checked = row.checked or state == "this"
      row.other = row.other or state == "other"
    end
    row.other = row.other and not row.checked
    result[#result + 1] = row
  end
  for _, file_type in ipairs(config.plugins.file_types.types) do
    local extensions = {}
    for _, extension in ipairs(file_type.extensions) do extensions[#extensions + 1] = extension:lower() end
    add(file_type.name, extensions)
  end
  -- An extension that left the list keeps a row, so the user can remove it.
  local others = {}
  for name in pairs(registered) do
    local extension = name:match("^%.(.+)$")
    if extension and not listed[extension:lower()] then others[#others + 1] = extension:lower() end
  end
  table.sort(others)
  for _, extension in ipairs(others) do add("." .. extension, { extension }) end
  return result
end

local function register_extension(name, extension)
  local key = classes_key(progid(extension))
  return system.set_registry_value(key, "", name .. " File")
    and system.set_registry_value(key .. "\\DefaultIcon", "", EXEFILE .. ",0")
    and system.set_registry_value(open_command_key(extension), "", '"' .. EXEFILE .. '" "%1"')
    and system.set_registry_value(classes_key("." .. extension .. "\\OpenWithProgids"), progid(extension), "")
    and system.set_registry_value(associations_key(), "." .. extension, progid(extension))
end

local function unregister_extension(extension)
  return system.delete_registry_key(classes_key(progid(extension)))
    and system.delete_registry_value(classes_key("." .. extension .. "\\OpenWithProgids"), progid(extension))
    and system.delete_registry_value(associations_key(), "." .. extension)
end

-- The app's entry in Windows Settings exists while it opens at least one extension.
local function update_app_entry()
  local registered = system.get_registry_values(associations_key())
  if registered and next(registered) then
    local key = capabilities_key()
    return system.set_registry_value(key, "ApplicationName", APP)
      and system.set_registry_value(key, "ApplicationDescription", "Anvil text editor")
      and system.set_registry_value(key, "ApplicationIcon", EXEFILE .. ",0")
      and system.set_registry_value(M.root .. "\\RegisteredApplications", APP, key)
  end
  return system.delete_registry_value(M.root .. "\\RegisteredApplications", APP)
    and system.delete_registry_key(M.root .. "\\" .. APP)
end

---Make this anvil.exe open the type's extensions, or stop opening them. Returns false when a registry write fails.
---@param file_type { name: string, extensions: string[] }
function M.set(file_type, open)
  local ok = true
  for _, extension in ipairs(file_type.extensions) do
    if open then
      ok = register_extension(file_type.name, extension) and ok
    else
      ok = unregister_extension(extension) and ok
    end
  end
  ok = update_app_entry() and ok
  system.notify_file_types_changed()
  core.log_quiet("File Types: %s %s (%s)%s", open and "registered" or "removed", file_type.name,
    table.concat(file_type.extensions, " "), ok and "" or ", a registry write failed")
  return ok
end

---Open Anvil's page in Windows Settings, where the user makes Anvil the default app.
function M.open_settings()
  return system.open_in_system("ms-settings:defaultapps?registeredAppUser=" .. APP)
end

---Open the File Types Dialog.
function M.open()
  return require("plugins.file_types.dialog").open()
end

command.add(function() return PLATFORM == "Windows" end, {
  ["file_types:manage"] = command.palette(function()
    M.open()
  end, {
    keywords = { "default app", "associations", "extensions", "open with", "register" },
  }),
})

return M
