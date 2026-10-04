local test = require "core.test"
local terminal = require "plugins.terminal"
local core = require "core"
local command = require "core.command"
local panes = require "core.panes"

local function wait_for(view, predicate, seconds)
  local deadline = system.get_time() + (seconds or 10)
  repeat
    if view and view.session then view:service_session(true) end
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return false
end

local function record(id)
  local text = assert(require("terminal_native").read_session_record(id))
  return assert(load(text, "session record", "t", {}))()
end

local function screen_text(view)
  local capture = view.session and view.session:text_capture()
  return capture and capture.text or ""
end

test.describe("Terminal revival", function()
  test.it("revives the latest disk screen after host loss and starts a usable new shell", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local state = view:get_state()
    local ffi = require "ffi"
    ffi.cdef [[
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      int __stdcall TerminateProcess(void *process, unsigned int code);
      unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
      int __stdcall CloseHandle(void *handle);
    ]]
    local kernel = ffi.load("kernel32")
    local old_pid = view.session:stats().host_pid
    local handle = kernel.OpenProcess(0x100001, 0, old_pid)
    local restored
    local ok, err = pcall(function()
      test.ok(view.session:write("echo ANVIL_DISK_SCREEN_MARKER\r"))
      test.ok(wait_for(view, function()
        return screen_text(view):find("ANVIL_DISK_SCREEN_MARKER", 1, true)
      end))
      -- Allow the documented periodic checkpoint to include this output.
      local saved_after = system.get_time() + 2.2
      test.ok(wait_for(view, function()
        local info = system.get_file_info(record(state.session_id).snapshot_path)
        return system.get_time() >= saved_after and info and info.size > 0
      end), "host did not publish a disk snapshot")
      test.ok(kernel.TerminateProcess(handle, 99) ~= 0)
      kernel.WaitForSingleObject(handle, 5000)
      view:detach_session()
      local started = system.get_time()
      restored = terminal.from_state(state)
      test.ok(system.get_time() - started < 0.8, "revival blocked Workspace restore")
      test.ok(wait_for(restored, function()
        local text = screen_text(restored)
        return restored.state == "running" and text:find("Restored session", 1, true)
          and text:find("ANVIL_DISK_SCREEN_MARKER", 1, true)
      end), "saved screen did not revive: " .. screen_text(restored))
      local text = screen_text(restored)
      local before = text:find("ANVIL_DISK_SCREEN_MARKER", 1, true)
      local marker = text:find("Restored session", 1, true)
      test.ok(before and before < marker, "old output did not precede the revival marker")
      test.ok(restored.session:stats().host_pid ~= old_pid)
      test.ok(restored.session:write("echo ANVIL_REVIVED_INPUT\r"))
      test.ok(wait_for(restored, function()
        return screen_text(restored):find("ANVIL_REVIVED_INPUT", 1, true)
      end), "revived shell did not accept input")
      local path = record(restored.session_id).snapshot_path
      restored:on_close()
      require("terminal_native").finish_close_commands()
      test.ok(wait_for(nil, function() return not system.get_file_info(path) end), "close kept a disk snapshot")
    end)
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("offers the interrupted child command without running it until approval", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local counter = USERDIR .. "/rerun-count.txt"
    local script = system.getcwd() .. "/tests/fixtures/terminal_interrupted_command.ps1"
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local function count()
      local file = io.open(counter, "rb")
      if not file then return nil end
      local value = file:read("*a"); file:close(); return value
    end
    local ok, err = pcall(function()
      test.ok(view.session:write(string.format('powershell.exe -NoProfile -File "%s" -CounterPath "%s"\r', script, counter)))
      test.ok(wait_for(view, function()
        local saved = record(state.session_id)
        return count() == "1" and saved.interrupted_command and saved.interrupted_command:find("terminal_interrupted_command", 1, true)
      end), "busy child command was not saved")
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      view:detach_session()
      restored = panes.place(function() return terminal.from_state(state) end, { placement = "current" })
      test.ok(wait_for(restored, function()
        local option = core.nag_view.options and core.nag_view.options[1]
        return option and option.text:find("Rerun ", 1, true) == 1
      end), "revival did not offer the interrupted command")
      test.equal(count(), "1", "revival reran the command without approval")
      core.nag_view.hovered_item = 1
      test.ok(command.perform("core:select_dialog_entry"))
      test.ok(wait_for(restored, function() return count() == "2" end), "approved command did not run")
    end)
    if core.nag_view.options and core.nag_view.options[1] and core.nag_view.options[1].rerun then
      core.nag_view.hovered_item = 2; command.perform("core:select_dialog_entry")
    end
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    os.remove(counter)
    test.ok(ok, err)
  end)

  test.it("revives an open View in the saved OSC 7 directory after its host ends", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local cwd = USERDIR .. "/revival cwd"
    system.mkdir(cwd)
    local uri = "file:///" .. cwd:gsub("\\", "/"):gsub(" ", "%%20")
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local previous_pid = view.session:stats().host_pid
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, previous_pid)
    local ok, err = pcall(function()
      test.ok(view.session:write(string.format('powershell.exe -NoProfile -Command "[Console]::Write([char]27 + \']7;%s\' + [char]7); [Console]::WriteLine(\'OSC7_SAVED\')"\r', uri)))
      test.ok(wait_for(view, function()
        local saved = record(view.session_id)
        return saved.cwd:gsub("\\", "/"):lower() == cwd:gsub("\\", "/"):lower()
          and system.get_file_info(saved.snapshot_path)
      end), "host did not save the OSC 7 directory")
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      test.ok(wait_for(view, function()
        return view.state == "running" and view.session:stats().host_pid ~= previous_pid
          and screen_text(view):find("Restored session", 1, true)
      end), "open View did not revive")
      test.ok(view.session:write("cd\r"))
      test.ok(wait_for(view, function()
        return screen_text(view):gsub("\\", "/"):lower():find(cwd:gsub("\\", "/"):lower(), 1, true)
      end), "new shell did not start in the saved directory")
    end)
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("rejects a corrupt disk snapshot asynchronously without a replacement shell", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local ok, err = pcall(function()
      local saved = record(state.session_id)
      test.ok(wait_for(view, function() return system.get_file_info(saved.snapshot_path) end))
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      view:detach_session()
      local file = assert(io.open(saved.snapshot_path, "wb")); file:write("truncated snapshot"); file:close()
      local started = system.get_time()
      restored = terminal.from_state(state)
      test.ok(system.get_time() - started < 0.8, "corrupt disk validation blocked the UI")
      test.ok(wait_for(restored, function() return restored.state == "failed" end))
      test.equal(restored:get_state().session_id, state.session_id)
      test.equal(restored.session:stats().attach_count, 0, "corrupt revival started a replacement shell")
      restored:on_close()
      local pool = require("core.worker_pool").system()
      local deadline = system.get_time() + 5
      repeat pool:drain(); coroutine.yield(0.01)
      until not system.get_file_info(saved.snapshot_path) or system.get_time() >= deadline
      test.equal(system.get_file_info(saved.snapshot_path), nil, "failed terminal close left its snapshot")
    end)
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("keeps the final shell output for revival after a normal shell exit", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local ok, err = pcall(function()
      test.ok(view.session:write("echo FINAL_SHELL_OUTPUT_MARKER & exit\r"))
      test.ok(wait_for(view, function() return kernel.WaitForSingleObject(handle, 0) == 0 end), "exited host did not finish")
      test.equal(record(state.session_id).status, "exited")
      view:detach_session()
      restored = terminal.from_state(state)
      test.ok(wait_for(restored, function()
        local text = screen_text(restored)
        return restored.state == "running" and text:find("FINAL_SHELL_OUTPUT_MARKER", 1, true)
          and text:find("Restored session", 1, true)
      end), "shell exit did not retain its final output")
    end)
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("keeps the visible alternate screen above the revival marker", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" }
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local ok, err = pcall(function()
      local script = system.getcwd() .. "/tests/fixtures/terminal_alternate_snapshot.ps1"
      test.ok(view.session:write(string.format('powershell.exe -NoProfile -File "%s"\r', script)))
      test.ok(wait_for(view, function() return screen_text(view):find("ALTERNATE_SCREEN_SAVED", 1, true) end))
      local saved_after = system.get_time() + 2.2
      test.ok(wait_for(view, function() return system.get_time() >= saved_after and system.get_file_info(record(state.session_id).snapshot_path) end))
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      view:detach_session()
      restored = terminal.from_state(state)
      test.ok(wait_for(restored, function()
        local text = screen_text(restored)
        local old = text:find("ALTERNATE_SCREEN_SAVED", 1, true)
        local marker = text:find("Restored session", 1, true)
        return restored.state == "running" and old and marker and old < marker
      end), "visible alternate screen was lost during revival")
    end)
    if core.nag_view.options and core.nag_view.options[1] and core.nag_view.options[1].rerun then
      core.nag_view.hovered_item = 2; command.perform("core:select_dialog_entry")
    end
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)
end)
