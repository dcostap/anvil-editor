local common = require "core.common"

local system_link = {}

-- Keep link activation separate from explicit system actions, such as Open with Default App.
function system_link.scheme(uri)
  if type(uri) ~= "string" or #uri > 32768 or uri:find("[%z%c]") then return nil end
  local scheme = uri:match("^([%a][%w+.-]*):")
  scheme = scheme and scheme:lower()
  if scheme == "http" or scheme == "https" or scheme == "mailto" or scheme == "file" then
    return scheme
  end
end

local executable_extensions = {}
for extension in ("exe com bat cmd scr pif msi msp mst cpl msc hta js jse vbs vbe vb wsf wsh wsc sct "
  .. "ps1 ps1xml ps2 ps2xml psc1 psc2 reg inf ins isp lnk url application appref-ms gadget chm jar "
  .. "sh bash desktop command workflow run py pyw pl rb lua"):gmatch("%S+") do
  executable_extensions[extension] = true
end

local function file_path(uri)
  local authority, path = uri:match("^[Ff][Ii][Ll][Ee]://([^/]*)(/[^?#]*)")
  if not path or authority:find("[^%w._%-]") then return nil end
  path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  if authority ~= "" and authority:lower() ~= "localhost" then
    path = "//" .. authority .. path
  elseif path:match("^/%a:") then
    path = path:sub(2)
  end
  return path
end

-- Return true when opened or when confirmation is pending. Never remember approval for later links.
function system_link.open(target)
  if type(target) ~= "string" or target == "" or #target > 32768 or target:find("[%z%c]") then return false end
  local scheme = system_link.scheme(target)
  if scheme == "http" or scheme == "https" or scheme == "mailto" then
    return common.open_in_system(target)
  end
  local path = scheme == "file" and file_path(target) or target
  if not path or path:find("[%z%c]") or not common.is_absolute_path(path) then return false end
  if PLATFORM == "Windows" then
    -- Refuse device paths and alternate data streams. Windows removes final spaces and dots.
    if path:match("^[/\\][/\\][?.]") or path:gsub("^%a:", ""):find(":", 1, true) then return false end
    path = path:gsub("[ .]+$", "")
  end
  local info = system.get_file_info(path)
  if not info or (info.type ~= "file" and info.type ~= "dir") then return false end
  local extension = (path:match("%.([^./\\]+)$") or ""):lower()
  if info.type == "file" and executable_extensions[extension] then
    local core = require "core"
    core.nag_view:show("Open Executable File", string.format("This link can run a program:\n%s\n\nOpen it?", path), {
      { text = "Cancel", action = "cancel", default_yes = true, default_no = true },
      { text = "Open", action = "open" },
    }, function(option)
      if option.action == "open" and not common.open_in_system(path) then
        core.error("Could not open %s", path)
      end
    end)
    return true
  end
  return common.open_in_system(path)
end

return system_link
