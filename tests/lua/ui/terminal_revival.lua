local ready = dofile("tests/fixtures/terminal_ready.lua")
local test = require "core.test"
local terminal = require "plugins.terminal"
local core = require "core"
local panes = require "core.panes"

local function wait_for(view, predicate, seconds)
  -- Shells start slowly on a loaded machine. The wait ends as soon as the predicate holds.
  local deadline = system.get_time() + (seconds or 30)
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

local function checkpoint_on_detach(view, state)
  local path = record(state.session_id).snapshot_path
  test.ok(wait_for(view, function() return record(state.session_id).attached end))
  -- A new file proves this detach saved the current model, not an older screen.
  os.remove(path)
  view:detach_session()
  test.ok(wait_for(nil, function() return not record(state.session_id).attached end))
  test.ok(system.get_file_info(path), "host acknowledged detach without saving its screen")
end

test.describe("Terminal revival", function()
  test.it("revives the latest disk screen after host loss and starts a usable new shell", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
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
      checkpoint_on_detach(view, state)
      test.ok(kernel.TerminateProcess(handle, 99) ~= 0)
      kernel.WaitForSingleObject(handle, 5000)
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

  test.it("revives a shell that quit ended in its Pane with the same session and screen", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local previous_quit = core.quit_request
    local restored
    local ok, err = pcall(function()
      test.ok(view.session:write("echo ANVIL_ENDED_SCREEN_MARKER\r"))
      test.ok(wait_for(view, function()
        local _, status = view.session:update()
        return status.busy == false and screen_text(view):find("ANVIL_ENDED_SCREEN_MARKER", 1, true)
      end), "the shell did not print the marker and go idle")
      core.quit(true)
      test.ok(core.nag_view.visible, "quit did not ask about the idle shell")
      for i, option in ipairs(core.nag_view.options) do
        if option.action == "end" then
          core.nag_view:change_hovered(i)
          test.ok(require("core.command").perform("core:select_dialog_entry"))
          break
        end
      end
      test.ok(core.quit_request ~= previous_quit, "End all did not accept quit")
      core.quit_request = previous_quit
      test.equal(view.state, "ended")
      require("terminal_native").finish_close_commands()
      test.equal(kernel.WaitForSingleObject(handle, 10000), 0, "quit did not end the host")
      restored = panes.place(function() return terminal.from_state(state) end, { placement = "current" })
      test.ok(wait_for(restored, function()
        return restored.state == "running" and screen_text(restored):find("ANVIL_ENDED_SCREEN_MARKER", 1, true)
      end), "the ended session did not revive: " .. screen_text(restored))
      test.equal(restored.session_id, state.session_id)
    end)
    core.quit_request = previous_quit
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("retires a lost session's record when a new shell replaces it", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local ok, err = pcall(function()
      checkpoint_on_detach(view, state)
      -- Without a saved screen the session cannot revive. A live host can save
      -- again, so remove the screen only after the host has ended.
      local snapshot = record(state.session_id).snapshot_path
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      os.remove(snapshot)
      restored = terminal.from_state(state)
      test.ok(wait_for(restored, function() return restored.state == "running" end), "no new shell started")
      test.ok(restored.session_id ~= state.session_id, "the lost session revived")
      local pool = require("core.worker_pool")
      test.ok(wait_for(restored, function()
        local current = pool.current_system()
        if current then current:drain({ max_ms = 5, max_messages = 64 }) end
        return not require("terminal_native").read_session_record(state.session_id)
      end), "the lost session's record stayed")
    end)
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("keeps input on the revived prompt through resize and reattachment", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" })
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local ok, err = pcall(function()
      test.ok(view.session:resize(80, 12, 8, 16))
      test.ok(wait_for(view, function() return screen_text(view):find("PS ", 1, true) end), "no first prompt")
      checkpoint_on_detach(view, state)
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      restored = terminal.from_state(state)
      local function after_marker()
        local text = screen_text(restored)
        local marker = text:find("Restored session", 1, true)
        return marker and text:sub(marker) or ""
      end
      test.ok(wait_for(restored, function()
        return restored.state == "running" and after_marker():find("PS ", 1, true)
      end), "revived shell showed no prompt: " .. screen_text(restored))
      local function type_on_prompt(text, expected)
        test.ok(restored.session:write(text))
        test.ok(wait_for(restored, function()
          local capture = restored.session:text_capture()
          if not capture then return false end
          local lines = {}
          for line in (capture.text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
          local line = lines[capture.cursor_line] or ""
          return line:find("PS .*" .. expected) and after_marker():find(expected, 1, true)
        end), "typed input left the new prompt: " .. screen_text(restored))
      end
      -- A short Pane puts the prompt at the bottom. Growing must not pull
      -- saved history into the live screen and move it away from shell input.
      test.ok(restored.session:resize(140, 1, 8, 16))
      type_on_prompt("ANVIL_TYPED", "ANVIL_TYPED")
      test.ok(restored.session:resize(140, 30, 8, 16))
      type_on_prompt("_GROWN", "ANVIL_TYPED_GROWN")
      local grown_state = restored:get_state()
      restored:detach_session()
      restored = ready(terminal.from_state(grown_state))
      type_on_prompt("_ATTACHED", "ANVIL_TYPED_GROWN_ATTACHED")
    end)
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("gives the revived shell the restored screen size", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local ok, err = pcall(function()
      test.ok(view.session:resize(100, 30, 8, 16))
      checkpoint_on_detach(view, state)
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      restored = terminal.from_state(state)
      test.ok(wait_for(restored, function() return restored.state == "running" end), "terminal did not revive")
      -- The View asks for the size it had before the host ended.
      test.ok(restored.session:resize(100, 30, 8, 16))
      test.ok(restored.session:write(
        "powershell.exe -NoProfile -Command \"'ANVIL_COLS=' + [Console]::WindowWidth\"\r"))
      test.ok(wait_for(restored, function()
        return screen_text(restored):find("ANVIL_COLS=%d")
      end), "shell did not report its width: " .. screen_text(restored))
      test.equal(screen_text(restored):match("ANVIL_COLS=(%d+)"), "100")
    end)
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("returns the interrupted command to the revived prompt and runs it only on Enter", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local counter = USERDIR .. "/rerun-count.txt"
    local script = system.getcwd() .. "/tests/fixtures/terminal_interrupted_command.ps1"
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" })
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local function count()
      local file = io.open(counter, "rb")
      if not file then return nil end
      local value = file:read("*a"); file:close(); return value
    end
    local typed = string.format("powershell.exe -NoProfile -File '%s' -CounterPath '%s'", script, counter)
    local ok, err = pcall(function()
      test.ok(wait_for(view, function() return screen_text(view):find("PS ", 1, true) end), "no first prompt")
      test.ok(view.session:write(typed .. "\r"))
      test.ok(wait_for(view, function()
        return count() == "1" and record(state.session_id).interrupted_input == typed
      end), "the typed command was not saved")
      checkpoint_on_detach(view, state)
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      restored = panes.place(function() return terminal.from_state(state) end, { placement = "current" })
      -- The new prompt follows the marker. A narrow View wraps the long command.
      local function new_prompt()
        local text = screen_text(restored)
        local marker = text:find("Restored session", 1, true)
        return marker and text:sub(marker):gsub("\r?\n", "") or ""
      end
      test.ok(wait_for(restored, function()
        return new_prompt():find("PS .*" .. typed:gsub("%p", "%%%0"))
      end), "the command did not return to the revived prompt: " .. screen_text(restored))
      test.ok(not core.nag_view.visible, "revival asked about the command")
      wait_for(restored, function() return false end, 1)
      test.equal(count(), "1", "revival ran the command without Enter")
      test.ok(restored.session:write("\r"))
      test.ok(wait_for(restored, function() return count() == "2" end), "Enter did not run the command")
    end)
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
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local previous_pid = view.session:stats().host_pid
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, previous_pid)
    local ok, err = pcall(function()
      test.ok(view.session:write(string.format('powershell.exe -NoProfile -Command "[Console]::Write([char]27 + \']7;%s\' + [char]7); [Console]::WriteLine(\'OSC7_\' + \'SAVED\')"\r', uri)))
      test.ok(wait_for(view, function() return screen_text(view):find("OSC7_SAVED", 1, true) end))
      local state = view:get_state()
      checkpoint_on_detach(view, state)
      view = terminal.from_state(state)
      test.ok(wait_for(view, function()
        local saved = record(view.session_id)
        return view.state == "running" and saved.cwd:gsub("\\", "/"):lower() == cwd:gsub("\\", "/"):lower()
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
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local ok, err = pcall(function()
      local saved = record(state.session_id)
      checkpoint_on_detach(view, state)
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
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
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
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
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local restored
    local ok, err = pcall(function()
      local script = view:get_cwd() .. "/tests/fixtures/terminal_alternate_snapshot.ps1"
      test.ok(view.session:write(string.format('powershell.exe -NoProfile -File "%s"\r', script)))
      test.ok(wait_for(view, function() return screen_text(view):find("ALTERNATE_SCREEN_SAVED", 1, true) end),
        "alternate screen did not arrive: " .. screen_text(view))
      checkpoint_on_detach(view, state)
      kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
      restored = terminal.from_state(state)
      test.ok(wait_for(restored, function()
        local text = screen_text(restored)
        local old = text:find("ALTERNATE_SCREEN_SAVED", 1, true)
        local marker = text:find("Restored session", 1, true)
        return restored.state == "running" and old and marker and old < marker
      end), "visible alternate screen was lost during revival")
    end)
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)
end)
