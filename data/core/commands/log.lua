local core = require "core"
local command = require "core.command"
local common = require "core.common"

local function temp_dir()
  return os.getenv("TEMP") or os.getenv("TMP") or "."
end

local function timestamp_name()
  local t = os.date("*t")
  return string.format(
    "anvil_debug_%04d%02d%02d_%02d%02d%02d.txt",
    t.year, t.month, t.day, t.hour, t.min, t.sec
  )
end

local function write_section(fp, title)
  fp:write("\n\n==== ", title, " ====\n")
end

local function read_file_tail(path, max_bytes)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local size = fp:seek("end") or 0
  local offset = math.max(0, size - max_bytes)
  fp:seek("set", offset)
  local data = fp:read("*a") or ""
  fp:close()
  if offset > 0 then
    data = string.format("[truncated: showing last %d of %d bytes]\n", #data, size) .. data
  end
  return data, size
end

local function known_diagnostic_file(name)
  return name:match("^anvil_.*%.csv$")
      or name:match("^anvil_.*%.txt$")
      or name:match("^anvil_.*%.log$")
end

local function dump_file_section(fp, path, max_bytes)
  local data, size = read_file_tail(path, max_bytes)
  if not data then return false end
  write_section(fp, path)
  fp:write(string.format("size: %d bytes\n\n", size or #data))
  fp:write(data)
  if data:sub(-1) ~= "\n" then fp:write("\n") end
  return true
end

local function dump_debug_logs()
  local dir = temp_dir()
  local path = dir .. PATHSEP .. timestamp_name()
  local fp = assert(io.open(path, "wb"))

  write_section(fp, "Anvil debug dump")
  fp:write("created: ", os.date(), "\n")
  fp:write("version: ", tostring(VERSION), " mod-version: ", tostring(MOD_VERSION_STRING), "\n")
  fp:write("platform: ", tostring(PLATFORM), "\n")
  fp:write("exe: ", tostring(EXEFILE), "\n")
  fp:write("exedir: ", tostring(EXEDIR), "\n")
  fp:write("datadir: ", tostring(DATADIR), "\n")
  fp:write("userdir: ", tostring(USERDIR), "\n")
  fp:write("cwd: ", tostring(system.getcwd()), "\n")
  if core.root_project and core.root_project() then
    fp:write("project: ", tostring(core.root_project().path), "\n")
  end
  fp:write("args: ", table.concat(ARGS or {}, " | "), "\n")

  write_section(fp, "Environment diagnostics")
  local env_names = {
    "ANVIL_RENDERER", "ANVIL_D3D11_STATS", "ANVIL_D3D11_STATS_FILE",
    "ANVIL_RESIZE_STATS", "ANVIL_RESIZE_STATS_FILE",
    "ANVIL_LUA_RESIZE_STATS", "ANVIL_LUA_RESIZE_STATS_FILE",
    "ANVIL_FRAME_PACING_STATS", "ANVIL_FRAME_PACING_STATS_FILE",
    "ANVIL_DISABLE_PLUGINS", "ANVIL_SCALE", "TEMP", "TMP",
  }
  for _, name in ipairs(env_names) do
    fp:write(name, "=", tostring(os.getenv(name) or ""), "\n")
  end

  write_section(fp, "In-memory core log")
  fp:write(core.get_log())
  fp:write("\n")

  dump_file_section(fp, USERDIR .. PATHSEP .. "error.txt", 512 * 1024)
  dump_file_section(fp, USERDIR .. PATHSEP .. "appstate.lua", 256 * 1024)

  write_section(fp, "Recent temp Anvil diagnostic files")
  local files = {}
  for _, name in ipairs(system.list_dir(dir) or {}) do
    if name ~= common.basename(path) and known_diagnostic_file(name) then
      table.insert(files, name)
    end
  end
  table.sort(files)
  local first = math.max(1, #files - 9)
  if #files == 0 then
    fp:write("none found in ", dir, "\n")
  else
    for i = first, #files do
      local diagnostic_path = dir .. PATHSEP .. files[i]
      fp:write(diagnostic_path, "\n")
    end
    for i = first, #files do
      dump_file_section(fp, dir .. PATHSEP .. files[i], 512 * 1024)
    end
  end

  fp:close()
  system.set_clipboard(path)
  core.log("Debug log dump saved and copied to clipboard: %s", path)
  return path
end

command.add(nil, {
  ["log:open-as-doc"] = function()
    local doc = core.open_doc("logs.txt")
    core.root_panel:open_doc(doc)
    doc:insert(1, 1, core.get_log())
    doc.new_file = false
    doc:clean()
  end,
  ["log:copy-to-clipboard"] = function()
    system.set_clipboard(core.get_log())
  end,
  ["log:dump-debug-logs"] = function()
    dump_debug_logs()
  end
})
