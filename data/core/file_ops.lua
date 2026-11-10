-- Changes to files and folders: create, move, copy and delete, also to the Recycle Bin.
-- For a path in a Project on a Machine, each change is a request to the Machine (docs/machines.md),
-- and the calling coroutine waits for its reply. `file_ops.run` gives such code its coroutine.
-- The Machine server does its changes with the same functions, on its own disk.
local core = require "core"
local common = require "core.common"
local fs = require "core.fs"

local file_ops = {}

local function path_join(a, b)
  if a:sub(-1) == PATHSEP then return a .. b end
  return a .. PATHSEP .. b
end

local function parent_dir(path)
  return common.dirname(path)
end

local function copy_file(src, dest)
  local input, err = io.open(src, "rb")
  if not input then return nil, err end
  local output
  output, err = io.open(dest, "wb")
  if not output then input:close(); return nil, err end
  local function fail(message)
    input:close()
    output:close()
    local removed, remove_err = os.remove(dest)
    if not removed then
      return nil, tostring(message) .. "; incomplete copy remains at " .. dest .. ": " .. tostring(remove_err)
    end
    return nil, message
  end
  while true do
    local chunk, read_err = input:read(1024 * 1024)
    if read_err then return fail(read_err) end
    if not chunk then break end
    local ok
    ok, err = output:write(chunk)
    if not ok then return fail(err) end
  end
  local input_ok, input_err = input:close()
  local output_ok, output_err = output:close()
  if not input_ok or not output_ok then
    local removed, remove_err = os.remove(dest)
    err = input_err or output_err
    if not removed then
      err = tostring(err) .. "; incomplete copy remains at " .. dest .. ": " .. tostring(remove_err)
    end
    return nil, err
  end
  return true
end

local function copy_recursive(src, dest, entry_type)
  local info = system.get_file_info(src)
  if not info then return nil, "source does not exist: " .. src end
  if info.symlink then return nil, "copying links is not supported: " .. src end
  entry_type = entry_type or info.type
  if entry_type == "dir" then
    local entries, list_err = system.list_dir(src)
    if not entries then return nil, list_err or ("cannot list directory: " .. src) end
    local ok, err, path = common.mkdirp(dest)
    if not ok then return nil, string.format("mkdir failed: %s: %s", path or dest, err) end
    for _, name in ipairs(entries) do
      local child_src = path_join(src, name)
      local child_dest = path_join(dest, name)
      local child_info = system.get_file_info(child_src)
      if child_info then
        ok, err = copy_recursive(child_src, child_dest, child_info.type)
        if not ok then return nil, err end
      else
        return nil, "cannot inspect source: " .. child_src
      end
    end
    return true
  end

  local parent = parent_dir(dest)
  if parent and not system.get_file_info(parent) then
    local ok, err, path = common.mkdirp(parent)
    if not ok then return nil, string.format("mkdir failed: %s: %s", path or parent, err) end
  end
  return copy_file(src, dest)
end

local function delete_permanent(path)
  local info = system.get_file_info(path)
  if not info then return true end
  if info.type == "dir" then
    local ok, err, failed_path = common.rm(path, true)
    if not ok then return nil, string.format("%s: %s", failed_path or path, err) end
    return true
  end
  local ok, err = os.remove(path)
  if not ok then return nil, err end
  return true
end

local function ps_single_quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

local function shell_quote_arg(s)
  return '"' .. s:gsub('"', '\\"') .. '"'
end

local function wait_paths_gone(paths, timeout)
  local deadline = system.get_time() + (timeout or 30)
  while system.get_time() < deadline do
    local remaining = false
    for _, path in ipairs(paths) do
      if system.get_file_info(path) then remaining = true; break end
    end
    if not remaining then return true end
    system.sleep(0.05)
  end
  for _, path in ipairs(paths) do
    if system.get_file_info(path) then return nil, "Recycle Bin operation did not complete: " .. path end
  end
  return true
end

local ffi_defined = false

local function trash_windows_ffi(paths)
  local ok, ffi = pcall(require, "ffi")
  if not ok then return nil, "LuaJIT FFI unavailable" end
  local ok_bit, bit = pcall(require, "bit")
  if not ok_bit then return nil, "LuaJIT bit library unavailable" end

  if not ffi_defined then
    ffi.cdef[[
typedef void* HWND;
typedef unsigned int UINT;
typedef int BOOL;
typedef const wchar_t* LPCWSTR;
typedef struct _SHFILEOPSTRUCTW {
  HWND hwnd;
  UINT wFunc;
  LPCWSTR pFrom;
  LPCWSTR pTo;
  unsigned short fFlags;
  BOOL fAnyOperationsAborted;
  void* hNameMappings;
  LPCWSTR lpszProgressTitle;
} SHFILEOPSTRUCTW;
int SHFileOperationW(SHFILEOPSTRUCTW *lpFileOp);
int MultiByteToWideChar(UINT CodePage, unsigned long dwFlags, const char *lpMultiByteStr,
  int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
unsigned long GetLastError(void);
]]
    ffi_defined = true
  end

  local shell32 = ffi.load("shell32")
  local kernel32 = ffi.load("kernel32")
  local CP_UTF8 = 65001
  local FO_DELETE = 0x0003
  local FOF_SILENT = 0x0004
  local FOF_NOCONFIRMATION = 0x0010
  local FOF_ALLOWUNDO = 0x0040
  local FOF_NOCONFIRMMKDIR = 0x0200
  local FOF_NOERRORUI = 0x0400

  local converted, total = {}, 1
  for _, path in ipairs(paths) do
    local normalized = common.normalize_path(path):gsub("/", "\\")
    local len = kernel32.MultiByteToWideChar(CP_UTF8, 0, normalized, #normalized, nil, 0)
    if len <= 0 then
      return nil, string.format("MultiByteToWideChar length failed for %s (%s)", path, tonumber(kernel32.GetLastError()))
    end
    converted[#converted + 1] = { path = normalized, len = len }
    total = total + len + 1
  end

  local from = ffi.new("wchar_t[?]", total)
  local offset = 0
  for _, item in ipairs(converted) do
    local written = kernel32.MultiByteToWideChar(CP_UTF8, 0, item.path, #item.path, from + offset, item.len)
    if written ~= item.len then
      return nil, string.format("MultiByteToWideChar failed for %s (%s)", item.path, tonumber(kernel32.GetLastError()))
    end
    offset = offset + item.len
    from[offset] = 0
    offset = offset + 1
  end
  from[offset] = 0

  local op = ffi.new("SHFILEOPSTRUCTW")
  op.hwnd = nil
  op.wFunc = FO_DELETE
  op.pFrom = from
  op.pTo = nil
  op.fFlags = bit.bor(FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_SILENT, FOF_NOERRORUI, FOF_NOCONFIRMMKDIR)

  local rc = shell32.SHFileOperationW(op)
  if rc ~= 0 then return nil, "SHFileOperationW failed: " .. tostring(tonumber(rc)) end
  if op.fAnyOperationsAborted ~= 0 then return nil, "SHFileOperationW operation was aborted" end
  return wait_paths_gone(paths, 30)
end

local function trash_windows_powershell(paths)
  local dir = USERDIR .. PATHSEP .. "storage"
  common.mkdirp(dir)
  local script = path_join(dir, "trash-" .. tostring(system.get_time()):gsub("%W", "") .. ".ps1")
  local fp, err = io.open(script, "wb")
  if not fp then return nil, err end
  fp:write("$ErrorActionPreference = 'Stop'\r\n")
  fp:write("$paths = @(\r\n")
  for i, path in ipairs(paths) do
    fp:write("  " .. ps_single_quote(path) .. (i < #paths and "," or "") .. "\r\n")
  end
  fp:write(")\r\n")
  fp:write("$shell = New-Object -ComObject 'Shell.Application'\r\n")
  fp:write("foreach ($literal in $paths) {\r\n")
  fp:write("  if (-not (Test-Path -LiteralPath $literal)) { continue }\r\n")
  fp:write("  $path = Get-Item -LiteralPath $literal\r\n")
  fp:write("  $folder = $shell.NameSpace($path.DirectoryName)\r\n")
  fp:write("  if ($null -eq $folder) { throw 'Could not open parent shell namespace' }\r\n")
  fp:write("  $item = $folder.ParseName($path.Name)\r\n")
  fp:write("  if ($null -eq $item) { throw 'Could not resolve shell item' }\r\n")
  fp:write("  $item.InvokeVerb('delete')\r\n")
  fp:write("}\r\n")
  fp:write("$deadline = (Get-Date).AddSeconds(30)\r\n")
  fp:write("while ((Get-Date) -lt $deadline) {\r\n")
  fp:write("  $remaining = @($paths | Where-Object { Test-Path -LiteralPath $_ })\r\n")
  fp:write("  if ($remaining.Count -eq 0) { exit 0 }\r\n")
  fp:write("  Start-Sleep -Milliseconds 50\r\n")
  fp:write("}\r\n")
  fp:write("throw ('Recycle Bin operation did not complete: ' + (($paths | Where-Object { Test-Path -LiteralPath $_ }) -join ', '))\r\n")
  fp:close()
  local ok, why, code = os.execute("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " .. shell_quote_arg(script))
  os.remove(script)
  if ok ~= true and ok ~= 0 then
    return nil, string.format("PowerShell trash failed (%s %s)", tostring(why), tostring(code))
  end
  return true
end

local function trash_paths(paths, trash)
  if #paths == 0 then return true end
  if file_ops.trashes(trash) then
    local ok, err = trash_windows_ffi(paths)
    if ok then return true end
    core.log("SHFileOperationW trash failed, falling back to PowerShell: %s", err)
    local ps_ok, ps_err = trash_windows_powershell(paths)
    if ps_ok then return true end
    return nil, string.format("%s; PowerShell fallback: %s", err, ps_err)
  end
  for _, path in ipairs(paths) do
    local ok, err = delete_permanent(path)
    if not ok then return nil, err end
  end
  return true
end

-- A change on the Machine. Returns true, or nil and the error's message.
local function machine_change(method, params)
  local err = fs.wait(fs.change, method, params)
  if err then return nil, tostring(err.message or err.code) end
  return true
end

-- Runs `fn()` now for a path on this PC. For a path on a Machine it runs `fn` in a thread,
-- because each change there waits for a reply.
function file_ops.run(path, fn)
  if fs.on_machine(path) then core.add_thread(fn) else fn() end
end

-- `{type, size, modified}` of the path, nil when it does not exist, or nil and an error.
function file_ops.info(path)
  if not fs.on_machine(path) then
    local info, err, code = system.get_file_info(path)
    if code == "not_found" then return nil end
    return info, err
  end
  local err, results = fs.wait(fs.stat, {path})
  if err then return nil, tostring(err.message or err.code) end
  return results[1] or nil
end

-- Makes the folder and its missing parents. Returns true, or nil, the error and the path that failed.
function file_ops.mkdirp(path)
  if not fs.on_machine(path) then return common.mkdirp(path) end
  local ok, err = machine_change("files.mkdir", {path = path})
  if not ok then return nil, err, path end
  return true
end

-- Makes a file with the bytes, or an empty file. It fails when the path exists.
function file_ops.create(path, bytes)
  if fs.on_machine(path) then
    local err = fs.wait(fs.write, path, bytes or "", nil, nil)
    if err then return nil, tostring(err.code == "conflict" and "target already exists: " .. path or err.message or err.code) end
    return true
  end
  if system.get_file_info(path) then return nil, "target already exists: " .. path end
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  local ok
  ok, err = file:write(bytes or "")
  file:close()
  if not ok then os.remove(path); return nil, err end
  return true
end

-- Moves or renames a file or folder. It fails when the target exists.
function file_ops.move(from, to)
  if fs.on_machine(from) or fs.on_machine(to) then return machine_change("files.move", {from = from, to = to}) end
  if system.get_file_info(to) then return nil, "target already exists: " .. to end
  if common.path_belongs_to(to, from) then return nil, "cannot move a folder into itself: " .. to end
  return os.rename(from, to)
end

-- Copies a file, or a folder with its content. Links are not copied. It fails when the target exists.
function file_ops.copy(from, to)
  if fs.on_machine(from) or fs.on_machine(to) then return machine_change("files.copy", {from = from, to = to}) end
  if system.get_file_info(to) then return nil, "target already exists: " .. to end
  if common.path_belongs_to(to, from) then return nil, "cannot copy a folder into itself: " .. to end
  return copy_recursive(from, to)
end

-- Deletes the paths. `trash` moves them to the Recycle Bin on Windows. Missing paths are skipped.
function file_ops.delete(paths, trash)
  if #paths > 0 and fs.on_machine(paths[1]) then
    return machine_change("files.delete", {paths = paths, trash = trash or nil})
  end
  local present = {}
  for _, path in ipairs(paths) do
    if system.get_file_info(path) then present[#present + 1] = path end
  end
  return trash_paths(present, trash)
end

-- True when `delete` with `trash` uses the Recycle Bin, so a user sees "Trash" and not "Delete".
function file_ops.trashes(trash)
  return trash and PLATFORM == "Windows" or false
end

return file_ops
