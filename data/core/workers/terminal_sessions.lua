local ffi = require "ffi"
local system = require "system"

ffi.cdef [[
  typedef struct { unsigned long low, high; } AnvilSessionFileTime;
  void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
  unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
  unsigned long __stdcall GetLastError(void);
  int __stdcall GetProcessTimes(void *handle, AnvilSessionFileTime *created,
    AnvilSessionFileTime *exited, AnvilSessionFileTime *kernel, AnvilSessionFileTime *user);
  int __stdcall CloseHandle(void *handle);
  void * __stdcall CreateMutexA(void *security, int owner, const char *name);
  int __stdcall ReleaseMutex(void *handle);
]]
local kernel = ffi.load("kernel32")

local function dead(record)
  if type(record.host_pid) ~= "number" or record.host_pid % 1 ~= 0 or
      record.host_pid <= 0 or record.host_pid > 0xffffffff or
      type(record.host_creation_time) ~= "string" or #record.host_creation_time ~= 16 or
      record.host_creation_time:find("[^0-9a-f]") then return false end
  local process = kernel.OpenProcess(0x100000 + 0x1000, 0, record.host_pid)
  if process == nil then return kernel.GetLastError() == 87 end -- Invalid PID, not access denied.
  local ended = kernel.WaitForSingleObject(process, 0) == 0
  if not ended and type(record.host_creation_time) == "string" then
    local times = ffi.new("AnvilSessionFileTime[4]")
    if kernel.GetProcessTimes(process, times, times + 1, times + 2, times + 3) ~= 0 then
      local created = string.format("%08x%08x", tonumber(times[0].high), tonumber(times[0].low))
      ended = created ~= record.host_creation_time
    end
  end
  kernel.CloseHandle(process)
  return ended
end

return { run = function(payload, ctx)
  local directory = payload.userdir .. "/terminal-sessions/"
  local entries = payload.id and { payload.id .. ".lua" } or system.list_dir(directory) or {}
  local removed = 0
  for _, name in ipairs(entries) do
    if ctx.cancelled() then break end
    local id = name:match("^([0-9a-f]+)%.lua$")
    if id and #id == 32 then
      local mutex = kernel.CreateMutexA(nil, 0, "Local\\AnvilTerminalRecord-" .. id)
      local waited = mutex ~= nil and kernel.WaitForSingleObject(mutex, 5000) or -1
      if waited == 0 or waited == 0x80 then
        -- The host uses this mutex before revival and each record replacement.
        local path = directory .. name
        local info = system.get_file_info(path)
        if info and (payload.id or info.modified < os.time() - 30 * 24 * 60 * 60) then
          local file = io.open(path, "rb")
          local text = file and file:read(1024 * 1024 + 1)
          if file then file:close() end
          local chunk = text and #text <= 1024 * 1024 and load(text, "@" .. path, "t", {})
          local ok, record = pcall(chunk or function() end)
          if ok and type(record) == "table" and record.session_id == id and dead(record) then
            os.remove(directory .. id .. ".snapshot")
            if os.remove(path) then removed = removed + 1 end
          end
        end
        kernel.ReleaseMutex(mutex)
      end
      if mutex ~= nil then kernel.CloseHandle(mutex) end
    end
  end
  ctx.send { type = "result", payload = { removed = removed } }
end }
