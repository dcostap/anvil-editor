-- mod-version:3
-- Seam: public Sidebar snapshots and actions in an owned Anvil Window.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^sidebar%-") then return end
local core = require "core"
local common = require "core.common"
local ffi = require "ffi"
ffi.cdef [[
  unsigned long __stdcall GetCurrentProcessId(void);
  void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
  unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long timeout);
  int __stdcall CloseHandle(void *handle);
  int __stdcall PostMessageW(void *window, unsigned int message, uintptr_t wparam, intptr_t lparam);
  int __stdcall IsIconic(void *window);
  int __stdcall IsWindowVisible(void *window);
  int __stdcall TerminateProcess(void *handle, unsigned int code);
  long __stdcall NtSuspendProcess(void *handle);
  long __stdcall NtResumeProcess(void *handle);
  unsigned long __stdcall GetWindowThreadProcessId(void *window, unsigned long *pid);
  intptr_t __stdcall SendMessageW(void *window, unsigned int message, uintptr_t wparam, intptr_t lparam);
  unsigned long __stdcall GetProcessId(void *process);
  int __stdcall GetExitCodeProcess(void *process, unsigned long *code);
  long __stdcall NtQuerySystemInformation(int kind, void *buffer, unsigned long size, unsigned long *needed);
]]
local kernel, user32 = ffi.load("kernel32"), ffi.load("user32")
local ntdll = ffi.load("ntdll")
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local function save(name, value)
  local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
  file:write("return ", common.serialize(value)); file:close()
end
local function read(name)
  local file = io.open(root .. "/" .. name .. ".lua", "rb")
  if not file then return end
  local text = file:read("*a"); file:close()
  return assert(loadstring(text))()
end
-- Diagnostics: time from each Sidebar termination request until its process object is signaled.
local exits = {}
local function track_exit(handle, label)
  exits[#exits + 1] = {handle = handle, label = label, start = system.get_time()}
end
-- Thread states and wait reasons of a process that has not finished terminating.
local function thread_states(pid)
  local size = 4 * 1024 * 1024
  local buffer, needed = ffi.new("uint8_t[?]", size), ffi.new("unsigned long[1]")
  if ntdll.NtQuerySystemInformation(5, buffer, size, needed) ~= 0 then return "query failed" end
  local offset = 0
  repeat
    local entry = buffer + offset
    if tonumber(ffi.cast("uintptr_t *", entry + 0x50)[0]) == pid then
      local count, states = ffi.cast("uint32_t *", entry + 4)[0], {}
      for i = 0, count - 1 do
        local thread = entry + 0x100 + i * 0x50
        local u = ffi.cast("int32_t *", thread)
        states[#states + 1] = u[0x44 / 4] .. ":" .. u[0x48 / 4] .. ":" .. u[0x38 / 4] .. "/" .. u[0x3c / 4]
      end
      return count .. " threads (state:wait_reason:priority/base) " .. table.concat(states, " ")
    end
    local next_offset = ffi.cast("uint32_t *", entry)[0]
    offset = offset + next_offset
  until next_offset == 0
  return "not listed"
end
local function poll_exits()
  for _, item in ipairs(exits) do
    if not item.ms and kernel.WaitForSingleObject(item.handle, 0) == 0 then
      item.ms = math.floor((system.get_time() - item.start) * 1000 + .5)
    elseif not item.ms and not item.threads and system.get_time() - item.start > 1 then
      local code = ffi.new("unsigned long[1]"); kernel.GetExitCodeProcess(item.handle, code)
      item.threads = "exit_code=" .. tonumber(code[0]) .. " " .. thread_states(tonumber(kernel.GetProcessId(item.handle)))
    end
  end
end
local function save_exits()
  local list = {}
  for _, item in ipairs(exits) do list[#list + 1] = {label = item.label, ms = item.ms or -1, threads = item.threads} end
  save("sidebar-exit-times", list)
end
local function wait(fn, seconds, message)
  local deadline = system.get_time() + seconds
  repeat
    poll_exits()
    if read("model-error") then error(read("model-error").error) end
    local value = fn(); if value then return value end
    coroutine.yield(.01)
  until system.get_time() > deadline
  error(message or "Sidebar model probe timed out")
end
-- Waits for the driver's finish signal. Each driver step, not the whole sequence, must finish within `seconds`.
local function wait_finish(seconds)
  local last
  repeat
    last = read("sidebar-progress")
    wait(function() return read("sidebar-process-finish") or read("sidebar-progress") ~= last end, seconds,
      "Sidebar driver made no progress")
  until read("sidebar-process-finish")
end
local function snapshot()
  assert(type(core.request_project_sidebar) == "function", "Project Sidebar snapshot API is unavailable")
  wait(function() return not core.project_sidebar_request end, 5)
  local previous = core.project_sidebar
  assert(core.request_project_sidebar(true))
  local model = wait(function() return core.project_sidebar ~= previous and core.project_sidebar end, 5)
  -- The Scratch Project is always listed. These cases check the Projects from the recent list and runtimes.
  local listed = {}
  for key, value in pairs(model) do if type(key) ~= "number" then listed[key] = value end end
  for _, project in ipairs(model) do if not project.scratch then listed[#listed + 1] = project end end
  return listed
end
local function row(model, name)
  for _, project in ipairs(model) do
    if project.path:gsub("\\", "/") == root .. "/" .. name then return project end
  end
end
local function model_until(fn, message)
  return wait(function()
    local model = snapshot()
    return fn(model) and model
  end, 15, message)
end
local function state() return {pid = tonumber(kernel.GetCurrentProcessId()), shell_pid = system.get_window_process_id()} end
local function quit() core.exit(function() core.quit_request = true end, true) end
local function window(pid)
  local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
  local text = file:read("*a"); file:close()
  local hex = assert(text:match("shell%[" .. pid .. "%] Shell window hwnd=(%x+)"))
  local hwnd = ffi.cast("void *", tonumber(hex, 16))
  local owner = ffi.new("unsigned long[1]")
  user32.GetWindowThreadProcessId(hwnd, owner); assert(tonumber(owner[0]) == pid)
  return hwnd
end
local directory = core.root_project().path:gsub("\\", "/")
core.add_background_thread(function()
  if directory:match("/driver$") then
    local subject, handles
    handles = {}
    local ok, err = pcall(function()
      local process = require "core.process"
      subject = assert(process.start({EXEFILE, "--shell", root .. "/Project"}, {
        stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD}))
      local a = wait(function() return read("a-started") end, 15)
      handles[1] = kernel.OpenProcess(0x100000, 0, a.pid)
      assert(handles[1] ~= nil, "Cannot retain owned A process")
      local hwnd = window(a.shell_pid)
      if action == "sidebar-idle" then
        wait(function() return read("idle-ready") end, 15)
        coroutine.yield(2)
        assert(os.rename(root .. "/Recent", root .. "/RecentMoved"))
        coroutine.yield(6)
        user32.PostMessageW(hwnd, 0x804d, 0, 0)
        local page = wait(function() return read("sidebar-0") end, 3)
        local recent
        for _, item in ipairs(page.items) do
          if item.kind == "project" and item.path:gsub("\\", "/") == root .. "/Recent" then recent = item end
        end
        assert(recent and recent.exists, "Idle Sidebar refreshed unchanged sources without a registry change")
        assert(os.rename(root .. "/RecentMoved", root .. "/Recent"))
        local record_path = USERDIR .. "/terminal-sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.lua"
        local file = assert(io.open(record_path, "rb"))
        local record = assert(loadstring(file:read("*a")))(); file:close()
        record.cwd = "REGISTRY_NOTIFICATION_CWD"
        file = assert(io.open(record_path, "wb"))
        file:write("return ", common.serialize(record)); file:close()
        wait(function()
          os.remove(root .. "/sidebar-0.lua")
          user32.PostMessageW(hwnd, 0x804d, 0, 0)
          coroutine.yield(.05)
          local updated = read("sidebar-0")
          for _, item in ipairs(updated and updated.items or {}) do
            if item.kind == "terminal" and item.id == record.session_id and item.cwd == record.cwd then return true end
          end
        end, 10, "Terminal registry change did not refresh the idle Sidebar")
        save("idle-finish", true)
        wait(function() return not subject:running() end, 15)
        return
      end
      if action == "sidebar-process" or action == "sidebar-log" or action == "sidebar-recovery" or action == "sidebar-recovery-reset"
          or action == "sidebar-gpu" or action == "sidebar-minimized" then
        local function sidebar_pid(old)
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          local found
          for value in text:gmatch("Shell Sidebar connected: pid=(%d+)") do
            found = tonumber(value)
          end
          if found ~= old then return found end
        end
        -- The shell restarts a crashed Sidebar only after its process exits. Restart deadlines start there.
        -- On a saturated CPU, idle-priority GPU driver threads can delay that exit for seconds.
        -- 30 seconds matches the shell's own exit wait.
        local progress = 0
        local function wait_exit(child)
          wait(function() return kernel.WaitForSingleObject(child, 0) == 0 end, 30,
            "Killed Sidebar did not finish exiting within the shell's exit wait")
          progress = progress + 1
          save("sidebar-progress", progress)
        end
        local first = wait(function() return sidebar_pid() end, 15, "Sidebar process did not connect")
        local function ready(pid)
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          local connection = text:match("Shell Sidebar connected: pid=" .. pid .. " connection=(%d+)")
          return connection and text:find("Shell state: Ready Project=0 connection=" .. connection, 1, true)
        end
        wait(function() return ready(first) end, 10, "Sidebar did not publish its first frame")
        assert(first ~= a.pid and first ~= a.shell_pid, "Sidebar shares a Project or shell process")
        if action == "sidebar-minimized" then
          user32.PostMessageW(hwnd, 0x112, 0xF020, 0)
          wait(function() return user32.IsIconic(hwnd) ~= 0 end, 2, "Owned Window did not minimize")
          user32.PostMessageW(hwnd, 0x804c, 5, 0)
          local replacement = wait(function() return sidebar_pid(first) end, 15, "Sidebar Restart did not connect")
          coroutine.yield(1)
          user32.PostMessageW(hwnd, 0x112, 0xF120, 0)
          wait(function() return user32.IsIconic(hwnd) == 0 end, 2, "Owned Window did not restore")
          wait(function() return ready(replacement) end, 10, "A Sidebar restarted in a minimized Window did not recover")
          save("sidebar-process-finish", true)
          wait(function() return not subject:running() end, 15)
          return
        end
        if action == "sidebar-gpu" then
          -- A driver update removes the GPU device of every process. The shell's presentation fails,
          -- and the Sidebar process ends with its own device.
          local sidebar = kernel.OpenProcess(0x1fffff, 0, first)
          assert(sidebar ~= nil); handles[#handles + 1] = sidebar
          user32.SendMessageW(hwnd, 0x804b, 5, 0)
          assert(kernel.TerminateProcess(sidebar, 107))
          wait_exit(sidebar)
          local replacement = wait(function() return sidebar_pid(first) end, 15,
            "The shell did not restart the Sidebar after a GPU failure")
          wait(function() return ready(replacement) end, 20, "The Sidebar did not recover after a GPU failure")
          -- The shell rebuilds its presentation. The Project keeps running through the failure.
          assert(kernel.WaitForSingleObject(handles[1], 0) ~= 0, "The GPU failure ended the Project")
          assert(read("a-started").pid == a.pid, "The GPU failure replaced the Project")
          save("sidebar-process-finish", true)
          wait(function() return not subject:running() end, 15)
          return
        end
        if action == "sidebar-recovery-reset" then
          local last = first
          for _ = 1, 3 do
            local child = kernel.OpenProcess(0x1fffff, 0, last)
            assert(child ~= nil); handles[#handles + 1] = child
            assert(kernel.TerminateProcess(child, 107))
            wait_exit(child)
            last = wait(function() return sidebar_pid(last) end, 15)
            wait(function() return ready(last) end, 10)
          end
          -- A healthy connection restores a fresh recovery budget.
          coroutine.yield(61)
          local child = kernel.OpenProcess(0x1fffff, 0, last)
          assert(child ~= nil); handles[#handles + 1] = child
          assert(kernel.TerminateProcess(child, 107))
          wait_exit(child)
          local replacement = wait(function() return sidebar_pid(last) end, 15,
            "A stable Sidebar did not restore its automatic recovery budget")
          wait(function() return ready(replacement) end, 10)
          assert(kernel.WaitForSingleObject(handles[1], 0) ~= 0, "Sidebar budget reset ended A")
          save("sidebar-process-finish", true)
          wait(function() return not subject:running() end, 15)
          return
        end
        if action == "sidebar-log" then
          wait(function()
            for _, name in ipairs(system.list_dir(USERDIR .. "/logs") or {}) do
              if name:match("%-p" .. first .. "%.log$") then
                local file = assert(io.open(USERDIR .. "/logs/" .. name, "rb"))
                local text = file:read("*a"); file:close()
                if text:find("Sidebar frontend started", 1, true) then return true end
              end
            end
          end, 5, "Sidebar quiet logs did not enter its normal session log")
          save("sidebar-process-finish", true)
          wait(function() return not subject:running() end, 15)
          return
        end
        local handle = kernel.OpenProcess(0x1fffff, 0, first)
        handles[#handles + 1] = handle; assert(handle ~= nil)
        assert(ntdll.NtSuspendProcess(handle) == 0)
        user32.PostMessageW(hwnd, 0x112, 0xF020, 0)
        wait(function() return user32.IsIconic(hwnd) ~= 0 end, 1, "Sidebar hang blocked native Minimize")
        user32.PostMessageW(hwnd, 0x112, 0xF120, 0)
        wait(function() return user32.IsIconic(hwnd) == 0 end, 1, "Sidebar hang blocked native Restore")
        save("sidebar-project-input", true)
        wait(function() return read("sidebar-project-input-ok") end, 5, "Sidebar hang blocked Project input")
        if action == "sidebar-recovery" then
          user32.PostMessageW(hwnd, 0x804c, 5, 0)
          track_exit(handle, "manual-restart-hung")
          -- The shell terminates with code 125. Windows reports that code as soon as termination starts.
          -- Completion can wait seconds on a saturated CPU for idle-priority GPU driver threads.
          wait(function()
            local code = ffi.new("unsigned long[1]")
            return kernel.GetExitCodeProcess(handle, code) ~= 0 and code[0] == 125
          end, 3, "Manual Sidebar Restart retained its hung frontend")
        else
          assert(ntdll.NtResumeProcess(handle) == 0)
          assert(kernel.TerminateProcess(handle, 107))
          wait(function() return kernel.WaitForSingleObject(handle, 0) == 0 end, 5)
          user32.PostMessageW(hwnd, 0x804c, 5, 0)
        end
        local second = wait(function() return sidebar_pid(first) end, 15, "Sidebar Restart did not connect")
        wait(function() return ready(second) end, 10, "Restarted Sidebar did not publish a frame")
        assert(second ~= first and kernel.WaitForSingleObject(handles[1], 0) ~= 0, "Sidebar Restart replaced A")
        if action == "sidebar-recovery" then
          -- Repeated crashes must eventually stop automatic replacement.
          local last, stopped = second, false
          for _ = 1, 12 do
            local child = kernel.OpenProcess(0x1fffff, 0, last)
            assert(child ~= nil); handles[#handles + 1] = child
            assert(kernel.TerminateProcess(child, 107))
            track_exit(child, "crash-loop")
            wait_exit(child)
            local deadline = system.get_time() + 6
            local next_pid
            repeat
              local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
              local text = file:read("*a"); file:close()
              local newest
              for value in text:gmatch("Shell Sidebar connected: pid=(%d+)") do newest = tonumber(value) end
              if newest ~= last then next_pid = newest end
              poll_exits()
              if not next_pid then coroutine.yield(.05) end
            until next_pid or system.get_time() >= deadline
            if not next_pid then
              local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
              local text = file:read("*a"); file:close()
              assert(text:find("automatic restart limit reached", 1, true), "Sidebar stopped before its restart limit")
              stopped = true; break
            end
            last = next_pid
            wait(function() return ready(last) end, 10)
          end
          assert(stopped, "Sidebar crash loop has no attempt limit")
          user32.PostMessageW(hwnd, 0x804c, 5, 0)
          local manual = wait(function() return sidebar_pid(last) end, 15)
          wait(function() return ready(manual) end, 10)
          assert(kernel.WaitForSingleObject(handles[1], 0) ~= 0, "Sidebar recovery ended A")
        end
        save("sidebar-process-finish", true)
        wait(function() return not subject:running() end, 15)
        return
      end
      if action == "sidebar-demand" then
        wait(function() return read("demand-ready") end, 15)
        save("demand-hide", true)
        wait(function() return user32.IsWindowVisible(hwnd) == 0 end, 5, "Owned Window did not become hidden")
        system.sleep(2)
        assert(os.rename(root .. "/Recent", root .. "/RecentMoved"))
        coroutine.yield(7)
        user32.PostMessageW(hwnd, 0x804d, 0, 0)
        local page = wait(function() return read("sidebar-0") end, 3)
        local recent
        for _, item in ipairs(page.items) do
          if item.kind == "project" and item.path:gsub("\\", "/") == root .. "/Recent" then recent = item end
        end
        assert(recent and recent.exists, "Unrequested status scans changed the idle model")
        save("demand-query", true)
        wait(function() return read("demand-fresh") end, 10)
        assert(os.rename(root .. "/RecentMoved", root .. "/Recent"))
        save("demand-finish", true)
        wait(function() return not subject:running() end, 15)
        return
      end
      if action == "sidebar-worker" then
        wait(function()
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          return text:find("Shell paused the owned Sidebar status worker", 1, true)
        end, 8, "Sidebar worker delay was not armed")
        user32.PostMessageW(hwnd, 0x112, 0xF020, 0)
        wait(function() return user32.IsIconic(hwnd) ~= 0 end, 1, "Path checks blocked native Minimize")
        user32.PostMessageW(hwnd, 0x112, 0xF120, 0)
        wait(function() return user32.IsIconic(hwnd) == 0 end, 1, "Path checks blocked native Restore")
      end
      local b = wait(function() return read("b-ready") end, 20)
      handles[2] = kernel.OpenProcess(0x100000, 0, b.pid)
      assert(handles[2] ~= nil, "Cannot retain owned B process")
      save("b-observed", {continue = true})
      local c = wait(function() return read("c-ready") end, 20)
      handles[3] = kernel.OpenProcess(0x100000, 0, c.pid)
      assert(handles[3] ~= nil, "Cannot retain owned C process")
      save("c-observed", {continue = true})
      local complete = wait(function() return read("model-complete") end, 15)
      assert(complete.a_state == "dormant" and complete.b_state == "dormant", "The model lost a Dormant Project")
      save("unload-c", {continue = true})
      wait(function() return kernel.WaitForSingleObject(handles[3], 0) == 0 end, 10)
      assert(subject:running(), "Last unload closed the Window")
      local page = wait(function()
        user32.PostMessageW(hwnd, 0x804d, 0, 0)
        local value = read("sidebar-0")
        if not value then return end
        for _, item in ipairs(value.items) do
          if item.kind == "project" and (item.state ~= "dormant" or item.pid ~= 0) then return end
        end
        return value
      end, 5, "Empty Window lost its Sidebar model")
      local dormant_b
      for _, item in ipairs(page.items) do
        if item.kind == "project" then
          assert(item.state == "dormant" and item.pid == 0, "Empty Window retained a loaded Project")
          if item.path:gsub("\\", "/") == root .. "/Replacement" then dormant_b = item.row_id end
        end
      end
      assert(dormant_b, "Empty Window cannot reach earlier Dormant B")
      save("empty-load-b", {continue = true})
      user32.PostMessageW(hwnd, 0x804d, 1, dormant_b)
      local restored = wait(function() return read("b-restored") end, 15)
      assert(restored.pid ~= complete.b_pid and restored.shell_pid == a.shell_pid, "Model selection replaced the Window")
      save("finish", {continue = true})
      wait(function() return not subject:running() end, 15)
    end)
    if not ok and #exits > 0 then
      -- Record the actual exit time of a slow termination. This does not change the result.
      local deadline = system.get_time() + 30
      repeat poll_exits(); coroutine.yield(.05)
        local pending = false
        for _, item in ipairs(exits) do pending = pending or not item.ms end
      until not pending or system.get_time() > deadline
    end
    if #exits > 0 then poll_exits(); save_exits() end
    save("result", {ok = ok, error = ok and nil or tostring(err), action = action})
    if subject and subject:running() then subject:terminate(); subject:wait(1) end
    for _, handle in ipairs(handles) do kernel.CloseHandle(handle) end
    quit()
    return
  end
  local ok, err = pcall(function()
    if directory == root .. "/Project" then
      local record_directory = USERDIR .. "/terminal-sessions"
      if not system.get_file_info(record_directory) then assert(common.mkdirp(record_directory)) end
      for _, entry in ipairs({
        {id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status = "exited"},
        {id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", status = "running"},
      }) do
        local file = assert(io.open(record_directory .. "/" .. entry.id .. ".lua", "wb"))
        file:write("return ", common.serialize({version = 1, session_id = entry.id,
          project_path = root .. "/Recent", host_pid = 4294967295, host_creation_time = "0000000000000000",
          status = entry.status, shell = "fixture shell", cwd = root .. "/Recent", attached = false}))
        file:close()
      end
      save("a-started", state())
      if action == "sidebar-minimized" or action == "sidebar-gpu" then
        wait(function() return read("sidebar-process-finish") end, 60)
        quit()
        return
      end
      local initial = model_until(function(model)
        local recent = row(model, "Recent")
        return recent and recent.exists and #recent.terminals == 2 and row(model, "Replacement")
      end,
        "Recent Projects are missing from the model")
      assert(initial[1].path:gsub("\\", "/") == directory and initial[2].path:gsub("\\", "/") == root .. "/Recent",
        "Recent source order changed")
      assert(row(initial, "Recent").exists, "Worker did not check recent paths")
      if action == "sidebar-idle" then
        save("idle-ready", true)
        wait(function() return read("idle-finish") end, 30)
        -- No explicit query or focus change: the shell must notify the selected Project too.
        wait(function()
          local recent = row(core.project_sidebar or {}, "Recent")
          for _, terminal in ipairs(recent and recent.terminals or {}) do
            if terminal.cwd == "REGISTRY_NOTIFICATION_CWD" then return true end
          end
        end, 10, "The Project kept old Terminal state without a focus change")
        quit()
        return
      end
      if action == "sidebar-log" then
        wait(function() return read("sidebar-process-finish") end, 30)
        quit()
        return
      end
      if action == "sidebar-recovery-reset" then
        wait_finish(120)
        quit()
        return
      end
      if action == "sidebar-process" or action == "sidebar-log" or action == "sidebar-recovery" then
        wait(function() return read("sidebar-project-input") end, 30)
        local editor = core.open_file(directory .. "/edited.txt")
        core.set_active_view(editor)
        core.on_event("textinput", "SIDEBAR_HANG_INPUT")
        assert(editor.buffer:get_text(1, 1, 1, 19):find("SIDEBAR_HANG_INPUT", 1, true))
        save("sidebar-project-input-ok", true)
        wait_finish(30)
        quit()
        return
      end
      if action == "sidebar-demand" then
        save("demand-ready", true)
        wait(function() return read("demand-hide") end, 15)
        system.set_window_visible(core.window, false)
        wait(function() return read("demand-query") end, 15)
        system.set_window_visible(core.window, true)
        model_until(function(model) return not row(model, "Recent").exists end, "Stale query did not refresh status")
        local recents = {table.unpack(core.recent_projects)}
        recents[#recents + 1] = root .. "/Other"
        core.set_recent_projects(recents)
        model_until(function(model) return row(model, "Other") end, "Changed recent source did not reach the shell")
        save("demand-fresh", true)
        wait(function() return read("demand-finish") end, 10)
        quit()
        return
      end
      local terminals = row(initial, "Recent").terminals
      assert(terminals[1].id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and terminals[1].state == "exited" and
        terminals[2].id == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and terminals[2].state == "lost" and terminals[2].busy == -1,
        "Worker changed exited, lost, or unknown Terminal status")
      assert(os.rename(root .. "/Recent", root .. "/RecentMoved"))
      model_until(function(model) return not row(model, "Recent").exists end, "Worker did not refresh an unavailable recent path")
      assert(os.rename(root .. "/RecentMoved", root .. "/Recent"))
      assert(core.open_project_in_same_window(root .. "/Replacement"))
      local b = wait(function() return read("b-ready") end, 15)
      wait(function() return read("b-observed") end, 10)
      local loaded = model_until(function(model) local item = row(model, "Replacement"); return item.selected and item.state == "ready" end)
      assert(loaded[1].path == initial[1].path and loaded[2].path == initial[2].path, "Selecting B changed list order")
      assert(core.open_project_in_same_window(directory))
      save("defer-dialog", {continue = true})
      model_until(function(model) return row(model, "Replacement").deferred_dialog end, "Deferred file dialog has no indicator")
      assert(core.unload_project(root .. "/Replacement"))
      model_until(function(model)
        local item = row(model, "Replacement")
        return item.close_choice and item.state == "closing" and not item.deferred_dialog
      end, "Close choice has no indicator")
      save("cancel-b", {continue = true})
      model_until(function(model) local item = row(model, "Replacement"); return item.state == "ready" and not item.close_choice end)
      save("unload-b", {continue = true})
      model_until(function(model) local item = row(model, "Replacement"); return item.state == "dormant" and item.pid == 0 end)
      assert(core.open_project_in_same_window(root .. "/Other"))
      wait(function() return read("c-ready") end, 15)
      wait(function() return read("c-observed") end, 10)
      assert(core.unload_project(directory))
    elseif directory == root .. "/Replacement" then
      if read("empty-load-b") then
        save("b-restored", state())
        wait(function() return read("finish") end, 10)
        assert(require("core.command").perform("core:close_current_window"))
        return
      end
      local editor = core.open_file(directory .. "/edited.txt")
      editor.buffer:insert(1, 1, "UNSAVED_")
      save("b-ready", state())
      wait(function() return read("defer-dialog") and not system.window_should_render(core.window) end, 15)
      core.open_file_dialog(core.window, function() end, {title = "Deferred Sidebar probe"})
      wait(function() return core.nag_view.visible and core.nag_view:get_title() == "Unsaved Changes" and read("cancel-b") end, 15)
      assert(require("core.command").perform("core:select_dialog_no"))
      wait(function() return read("unload-b") end, 10)
      editor.buffer:save()
      assert(require("core.command").perform("core:unload_project"))
    elseif directory == root .. "/Other" then
      save("c-ready", state())
      local model = model_until(function(value)
        return row(value, "Project").state == "dormant" and row(value, "Replacement").state == "dormant"
      end, "The model lost earlier Dormant records")
      assert(model[1].path:gsub("\\", "/") == directory, "New Project is not first")
      assert(model[2].path:gsub("\\", "/") == root .. "/Project" and model[3].path:gsub("\\", "/") == root .. "/Recent",
        "Lifecycle changes reordered recent Projects")
      save("model-complete", {a_state = row(model, "Project").state, b_state = row(model, "Replacement").state,
        b_pid = read("b-ready").pid, c_pid = state().pid})
      wait(function() return read("unload-c") end, 10)
      assert(require("core.command").perform("core:unload_project"))
    end
  end)
  if not ok then save("model-error", {error = tostring(err)}) end
end)
