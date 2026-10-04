local test = require "core.test"
local system = require "system"
local terminal = require "plugins.terminal"
local worker_pool = require "core.worker_pool"

test.describe("Terminal Session record cleanup", function()
  test.it("removes expired dead records, keeps recent and live records, and uses owned paths", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows process identities")
    local ffi = require "ffi"
    ffi.cdef [[
      typedef struct { unsigned long low, high; } CleanupFileTime;
      void * __stdcall CreateFileA(const char *path, unsigned long access, unsigned long share,
        void *security, unsigned long disposition, unsigned long flags, void *template_file);
      int __stdcall SetFileTime(void *file, const CleanupFileTime *created,
        const CleanupFileTime *accessed, const CleanupFileTime *modified);
      int __stdcall CloseHandle(void *handle);
    ]]
    local kernel = ffi.load("kernel32")
    local directory = USERDIR .. "/terminal-sessions/"
    system.mkdir(directory)
    local outside = USERDIR .. "/keep-outside-snapshot.txt"
    local function write(path, text)
      local file = assert(io.open(path, "wb")); file:write(text); file:close()
    end
    write(outside, "keep")
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local function saved_record()
      local file = assert(io.open(directory .. view.session_id .. ".lua", "rb"))
      local text = file:read("*a"); file:close()
      return assert(load(text, "record", "t", {}))()
    end
    local live = saved_record()
    local ids = { string.rep("a", 32), string.rep("b", 32), string.rep("c", 32) }
    local ok, err = pcall(function()
      for i, id in ipairs(ids) do
        write(directory .. id .. ".snapshot", "owned")
        write(directory .. id .. ".lua", string.format(
          "return {session_id=%q, host_pid=%d, host_creation_time=%q, snapshot_path=%q}",
          id, i == 3 and live.host_pid or 0x7fffffff,
          i == 3 and live.host_creation_time or "0000000000000001", outside))
        if i ~= 2 then
          local file = kernel.CreateFileA(directory .. id .. ".lua", 0x100, 7, nil, 3, 0x80, nil)
          test.ok(file ~= ffi.cast("void *", -1))
          local ticks = (os.time() - 31 * 86400 + 11644473600) * 10000000
          local modified = ffi.new("CleanupFileTime[1]")
          modified[0].low, modified[0].high = ticks % 4294967296, math.floor(ticks / 4294967296)
          test.ok(kernel.SetFileTime(file, nil, nil, modified) ~= 0); kernel.CloseHandle(file)
        end
      end
      terminal.cleanup_records()
      local deadline = system.get_time() + 5
      repeat worker_pool.system():drain(); coroutine.yield(0.01)
      until not system.get_file_info(directory .. ids[1] .. ".lua") or system.get_time() >= deadline
      test.equal(system.get_file_info(directory .. ids[1] .. ".lua"), nil, "expired dead record remained")
      test.equal(system.get_file_info(directory .. ids[1] .. ".snapshot"), nil)
      test.ok(system.get_file_info(directory .. ids[2] .. ".lua"), "recent dead record was removed")
      test.ok(system.get_file_info(directory .. ids[3] .. ".lua"), "live record was removed")
      test.ok(system.get_file_info(outside), "record supplied an unowned deletion path")
      terminal.cleanup_records(ids[2])
      deadline = system.get_time() + 5
      repeat worker_pool.system():drain(); coroutine.yield(0.01)
      until not system.get_file_info(directory .. ids[2] .. ".lua") or system.get_time() >= deadline
      test.equal(system.get_file_info(directory .. ids[2] .. ".lua"), nil, "explicit dead-session cleanup did not finish")
    end)
    view:on_close()
    for _, id in ipairs(ids) do os.remove(directory .. id .. ".lua"); os.remove(directory .. id .. ".snapshot") end
    os.remove(outside)
    test.ok(ok, err)
  end)
end)
