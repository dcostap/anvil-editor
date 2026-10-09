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
local function wait(fn, seconds, message)
  local deadline = system.get_time() + seconds
  repeat
    if read("model-error") then error(read("model-error").error) end
    local value = fn(); if value then return value end
    coroutine.yield(.01)
  until system.get_time() > deadline
  error(message or "Sidebar model probe timed out")
end
local function snapshot()
  assert(type(core.request_project_sidebar) == "function", "Project Sidebar snapshot API is unavailable")
  local previous = core.project_sidebar
  assert(core.request_project_sidebar())
  return wait(function() return core.project_sidebar ~= previous and core.project_sidebar end, 5)
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
      if action == "sidebar-process" then
        local function sidebar_pid(old)
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          local found
          for value in text:gmatch("Shell Sidebar connected: pid=(%d+)") do
            if tonumber(value) ~= old then found = tonumber(value) end
          end
          return found
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
        local handle = kernel.OpenProcess(0x1fffff, 0, first)
        handles[#handles + 1] = handle; assert(handle ~= nil)
        assert(ntdll.NtSuspendProcess(handle) == 0)
        user32.PostMessageW(hwnd, 0x112, 0xF020, 0)
        wait(function() return user32.IsIconic(hwnd) ~= 0 end, 1, "Sidebar hang blocked native Minimize")
        user32.PostMessageW(hwnd, 0x112, 0xF120, 0)
        wait(function() return user32.IsIconic(hwnd) == 0 end, 1, "Sidebar hang blocked native Restore")
        save("sidebar-project-input", true)
        wait(function() return read("sidebar-project-input-ok") end, 5, "Sidebar hang blocked Project input")
        assert(ntdll.NtResumeProcess(handle) == 0)
        assert(kernel.TerminateProcess(handle, 107))
        wait(function() return kernel.WaitForSingleObject(handle, 0) == 0 end, 5)
        user32.PostMessageW(hwnd, 0x804c, 5, 0)
        local second = wait(function() return sidebar_pid(first) end, 15, "Sidebar Restart did not connect")
        wait(function() return ready(second) end, 10, "Restarted Sidebar did not publish a frame")
        assert(second ~= first and kernel.WaitForSingleObject(handles[1], 0) ~= 0, "Sidebar Restart replaced A")
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
      local initial = model_until(function(model)
        local recent = row(model, "Recent")
        return recent and recent.exists and #recent.terminals == 2 and row(model, "Replacement")
      end,
        "Recent Projects are missing from the model")
      assert(initial[1].path:gsub("\\", "/") == directory and initial[2].path:gsub("\\", "/") == root .. "/Recent",
        "Recent source order changed")
      assert(row(initial, "Recent").exists, "Worker did not check recent paths")
      if action == "sidebar-process" then
        wait(function() return read("sidebar-project-input") end, 30)
        local editor = core.open_file(directory .. "/edited.txt")
        core.set_active_view(editor)
        core.on_event("textinput", "SIDEBAR_HANG_INPUT")
        assert(editor.buffer:get_text(1, 1, 1, 19):find("SIDEBAR_HANG_INPUT", 1, true))
        save("sidebar-project-input-ok", true)
        wait(function() return read("sidebar-process-finish") end, 30)
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
        core.recent_projects[#core.recent_projects + 1] = root .. "/Other"
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
        assert(require("core.command").perform("core:quit"))
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
