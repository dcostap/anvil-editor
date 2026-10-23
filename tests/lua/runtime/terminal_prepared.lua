local test = require "core.test"

local function wait_for(session, predicate)
  local deadline = system.get_time() + 30
  repeat
    local _, status = session:update()
    if predicate(status) then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return false
end

test.describe("Prepared Terminal Session", function()
  test.it("keeps a prepared shell private until a view takes it", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local native = require "terminal_native"
    local session = assert(native.new {
      cwd = system.getcwd(), shell = "cmd.exe /D /Q", prepared = true,
    })
    local ok, err = pcall(function()
      test.ok(wait_for(session, function(status) return status.kind == "running" and not status.replaying end))
      local before = session:stats()
      test.is_nil(native.read_session_record(before.session_id), "unused shell appeared in saved sessions")
      test.ok(session:activate())
      test.ok(wait_for(session, function(status)
        return status.busy == false and native.read_session_record(before.session_id) ~= nil
      end), "activated shell did not report its idle status")
      test.equal(session:stats().shell_pid, before.shell_pid, "activation started another shell")
      test.ok(session:write("echo PREPARED_SESSION_INPUT\r"))
      test.ok(wait_for(session, function()
        return session:text_capture().text:find("PREPARED_SESSION_INPUT", 1, true)
      end))
    end)
    session:close()
    native.finish_close_commands()
    test.ok(ok, err)
  end)

  test.it("rejects a prepared shell after its launch environment changes", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local native = require "terminal_native"
    local key = "ANVIL_PREPARED_ENV_TEST"
    local previous = os.getenv(key) or ""
    system.setenv(key, "before")
    local session = assert(native.new { cwd = system.getcwd(), shell = "cmd.exe /D /Q", prepared = true })
    local ok, err = pcall(function()
      test.ok(wait_for(session, function(status) return status.kind == "running" and not status.replaying end))
      system.setenv(key, "after")
      test.not_ok(session:activate(), "a shell with stale environment was accepted")
    end)
    system.setenv(key, previous)
    session:close()
    native.finish_close_commands()
    test.ok(ok, err)
  end)

  test.it("keeps an activated shell when detach interrupts its transport", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local native = require "terminal_native"
    local session = assert(native.new { cwd = system.getcwd(), shell = "cmd.exe /D /Q", prepared = true })
    local restored
    local ok, err = pcall(function()
      test.ok(wait_for(session, function(status) return status.kind == "running" and not status.replaying end))
      local before = session:stats()
      test.ok(session:activate())
      native._break_transport_for_tests(session)
      session:detach()
      local deadline = system.get_time() + 30
      local record
      repeat
        local text = native.read_session_record(before.session_id)
        record = text and assert(load(text, "record", "t", {}))()
        if record and not record.attached then break end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      test.ok(record and not record.attached, "immediate detach lost the activated shell")
      restored = assert(native.new {
        session_id = record.session_id, host_pid = record.host_pid,
        host_creation_time = record.host_creation_time, pipe_name = record.pipe_name,
      })
      test.ok(wait_for(restored, function(status) return status.kind == "running" and not status.replaying end))
      test.equal(restored:stats().shell_pid, before.shell_pid)
    end)
    if restored then restored:close() end
    session:close()
    native.finish_close_commands()
    test.ok(ok, err)
  end)

  for _, action in ipairs { "detach", "disconnect" } do
    test.it("ends an unused shell on " .. action .. " instead of saving it", function()
      test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
      local native = require "terminal_native"
      local ffi = require "ffi"
      ffi.cdef [[
        void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
        unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
        int __stdcall CloseHandle(void *handle);
      ]]
      local kernel = ffi.load("kernel32")
      local session = assert(native.new { cwd = system.getcwd(), shell = "cmd.exe /D /Q", prepared = true })
      local handle
      local ok, err = pcall(function()
        test.ok(wait_for(session, function(status) return status.kind == "running" and not status.replaying end))
        local stats = session:stats()
        handle = kernel.OpenProcess(0x100000, 0, stats.host_pid)
        test.ok(handle ~= nil)
        if action == "detach" then session:detach()
        else native._break_transport_for_tests(session) end
        local deadline = system.get_time() + 30
        while kernel.WaitForSingleObject(handle, 0) == 258 and system.get_time() < deadline do
          if action == "disconnect" then session:update() end
          coroutine.yield(0.01)
        end
        test.equal(kernel.WaitForSingleObject(handle, 0), 0, "unused host remained alive")
        test.is_nil(native.read_session_record(stats.session_id))
        test.is_nil(system.get_file_info(USERDIR .. "/terminal-sessions/" .. stats.session_id .. ".snapshot"))
      end)
      session:close()
      if handle ~= nil then kernel.CloseHandle(handle) end
      native.finish_close_commands()
      test.ok(ok, err)
    end)
  end
end)
