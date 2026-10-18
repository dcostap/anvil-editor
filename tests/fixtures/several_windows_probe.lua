-- mod-version:3
-- Seam: public commands and native Windows owned by an isolated shell process.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^windows%-") then return end
local shared = action:match("^windows%-sidebars") ~= nil
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local ffi = require "ffi"
ffi.cdef [[
  unsigned long __stdcall GetCurrentProcessId(void);
  unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
  int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
  int __stdcall IsWindowVisible(void *);
  void * __stdcall GetWindow(void *, unsigned int);
  int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
  unsigned long __stdcall GetMenuState(void *, unsigned int, unsigned int);
  void * __stdcall GetSystemMenu(void *, int);
  int __stdcall IsIconic(void *);
  int __stdcall IsZoomed(void *);
  int __stdcall GetWindowTextW(void *, wchar_t *, int);
  void * __stdcall GetPropW(void *, const wchar_t *);
  void * __stdcall OpenProcess(unsigned long, int, unsigned long);
  unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
  int __stdcall CloseHandle(void *);
  int __stdcall GetClientRect(void *, void *);
  long __stdcall NtSuspendProcess(void *);
  long __stdcall NtResumeProcess(void *);
  int __stdcall TerminateProcess(void *, unsigned int);
]]
local kernel, user32 = ffi.load("kernel32"), ffi.load("user32")
local ntdll = ffi.load("ntdll")
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local function save(name, value)
  local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
  file:write("return ", common.serialize(value)); file:close()
end
local function load(name)
  local file = io.open(root .. "/" .. name .. ".lua", "rb")
  if not file then return end
  local text = file:read("*a"); file:close()
  return assert(loadstring(text))()
end
local function wait_for(fn, seconds, message)
  local deadline = system.get_time() + seconds
  repeat
    local value = fn()
    if value then return value end
    coroutine.yield(.01)
  until system.get_time() >= deadline
  error(message or "owned Window probe timed out")
end
local function windows(pid)
  local found = {}
  local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
  local callback = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
    local owner = ffi.new("unsigned long[1]")
    user32.GetWindowThreadProcessId(window, owner)
    if tonumber(owner[0]) == pid and user32.IsWindowVisible(window) ~= 0 and
        user32.GetPropW(window, property) ~= nil then
      found[#found + 1] = window
    end
    return 1
  end)
  user32.EnumWindows(callback, 0); callback:free()
  return found
end
local function trace()
  local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
  local text = file:read("*a"); file:close(); return text
end
local function window_id(window)
  for id, hex in trace():gmatch("Shell Window record: id=(%d+) SDL=%d+ hwnd=(%x+)") do
    if ffi.cast("void *", tonumber(hex, 16)) == window then return tonumber(id) end
  end
end
local function dialog(pid)
  local found
  local callback = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
    local owner = ffi.new("unsigned long[1]")
    user32.GetWindowThreadProcessId(window, owner)
    if tonumber(owner[0]) == pid and user32.IsWindowVisible(window) ~= 0 then
      local text = ffi.new("wchar_t[128]")
      local length = user32.GetWindowTextW(window, text, 128)
      local name = {}
      for i = 0, length - 1 do name[#name + 1] = string.char(tonumber(text[i]) < 128 and text[i] or 63) end
      if table.concat(name) == "Open Project" then found = window; return 0 end
    end
    return 1
  end)
  user32.EnumWindows(callback, 0); callback:free(); return found
end
local function services(pid)
  local hex = assert(trace():match("Shell service notifications hwnd=(%x+)"))
  local window = ffi.cast("void *", tonumber(hex, 16))
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  assert(tonumber(owner[0]) == pid, "picker result has the wrong shell target")
  return window
end
local function quit() core.exit(function() core.quit_request = true end, true) end
local path = core.root_project().path:gsub("\\", "/")
if path:find("/driver$", 1) then
  core.add_background_thread(function()
    local subject
    local ok, err = pcall(function()
      local process = require "core.process"
      subject = assert(process.start({EXEFILE, "--shell", root .. "/Project"}, {
        stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD,
      }))
      local a = wait_for(function() return load("a-ready") end, 15)
      local original = assert(windows(a.shell_pid)[1])
      if action == "windows-picker-command" then
        save("open", {continue = true})
        wait_for(function() return trace():find("Shell Open Project picker started: Window=" .. a.window_id, 1, true) end,
          5, "hosted Open Project command did not use the shell picker")
        user32.PostMessageW(services(a.shell_pid), 0x8050, 1, a.window_id)
        local b = wait_for(function() return load("b-ready") end, 15, "occupied Window picker did not load the second Project")
        assert(b.shell_pid == a.shell_pid and b.window_id == a.window_id, "occupied Window picker used another Window")
        assert(#windows(a.shell_pid) == 1, "occupied Window picker created another Window")
        save("finish", {continue = true})
        wait_for(function() return not subject:running() end, 10)
        assert(subject:returncode() == 0); return
      end
      if action == "windows-open" or action == "windows-owner-close" or shared then
        save("open", {continue = true})
        local b = wait_for(function() return load("b-ready") end, 15, "Open Project did not load the second Project")
        assert(b.shell_pid == a.shell_pid, "Open Project escaped the requesting shell")
        assert(a.window_id > 0 and b.window_id > 0 and a.window_id ~= b.window_id,
          "Projects did not receive distinct Window identities")
        assert(#windows(a.shell_pid) == 2, "Open Project did not create a second native Window")
        if shared then
          wait_for(function()
            return trace():find("Shell Sidebar surface Ready: Window=" .. b.window_id, 1, true)
          end, 5, "second Window has no Sidebar surface from the shared process")
          os.remove(root .. "/sidebar-0.lua")
          user32.PostMessageW(original, 0x804d, 0, 0)
          local model = wait_for(function() return load("sidebar-0") end, 3)
          local owners, selections = {}, {}
          for _, row in ipairs(model.items) do
            if row.kind == "project" then owners[row.pid] = row.window_id end
          end
          for _, row in ipairs(model.windows) do selections[row.id] = row.selected_project end
          assert(owners[a.pid] == a.window_id and owners[b.pid] == b.window_id, "Sidebar snapshot lost owning Windows")
          assert(selections[a.window_id] ~= 0 and selections[b.window_id] ~= 0 and
            selections[a.window_id] ~= selections[b.window_id], "Sidebar selections are not independent")
          if action == "windows-sidebars-recovery" then
            local pid
            for value in trace():gmatch("Shell Sidebar connected: pid=(%d+)") do pid = tonumber(value) end
            local frontend = assert(kernel.OpenProcess(0x100801, 0, pid))
            assert(ntdll.NtSuspendProcess(frontend) == 0, "Cannot suspend the owned Sidebar")
            local resumed, suspend_error = pcall(function()
              user32.PostMessageW(original, 0x112, 0xf020, 0)
              wait_for(function() return user32.IsIconic(original) ~= 0 end, 3)
              user32.PostMessageW(original, 0x112, 0xf120, 0)
              wait_for(function() return user32.IsIconic(original) == 0 end, 3)
              user32.PostMessageW(original, 0x112, 0xe010, 0)
              wait_for(function() return #windows(a.shell_pid) == 3 end, 5, "Suspended Sidebar blocked native New Window")
            end)
            ntdll.NtResumeProcess(frontend)
            if not resumed then kernel.CloseHandle(frontend); error(suspend_error) end
            assert(kernel.TerminateProcess(frontend, 125) ~= 0)
            -- The shell restarts a crashed Sidebar only after its process exits. The recreate deadline starts there.
            -- On a saturated CPU, idle-priority GPU driver threads can delay that exit for seconds.
            -- 30 seconds matches the shell's own exit wait.
            local exited = pcall(wait_for, function() return kernel.WaitForSingleObject(frontend, 0) == 0 end, 30)
            kernel.CloseHandle(frontend)
            assert(exited, "Killed Sidebar did not finish exiting within the shell's exit wait")
            wait_for(function()
              local next_pid, connection
              for value, generation in trace():gmatch("Shell Sidebar connected: pid=(%d+) connection=(%d+)") do
                next_pid, connection = tonumber(value), generation
              end
              if next_pid == pid then return false end
              local text = trace()
              for _, window in ipairs(windows(a.shell_pid)) do
                if not text:find("Shell Sidebar surface Ready: Window=" .. window_id(window) .. " connection=" .. connection, 1, true) then
                  return false
                end
              end
              return true
            end, 10, "Sidebar crash did not recreate every Window's surface")
            for _, state in ipairs({a, b}) do
              local project = assert(kernel.OpenProcess(0x100000, 0, state.pid))
              assert(kernel.WaitForSingleObject(project, 0) ~= 0, "Sidebar recovery restarted a Project")
              kernel.CloseHandle(project)
            end
            for _, window in ipairs(windows(a.shell_pid)) do
              if window_id(window) ~= a.window_id and window_id(window) ~= b.window_id then
                user32.PostMessageW(window, 0x10, 0, 0)
              end
            end
            wait_for(function() return #windows(a.shell_pid) == 2 end, 5)
          end
        end
        if action == "windows-owner-close" or shared then
          local project = assert(kernel.OpenProcess(0x100000, 0, a.pid))
          save("close-a", {continue = true})
          wait_for(function() return kernel.WaitForSingleObject(project, 0) == 0 end, 10, "first Project did not close")
          kernel.CloseHandle(project)
          assert(subject:running(), "first Window Close ended the shell")
          wait_for(function() return #windows(a.shell_pid) == 1 end, 8, "first Window did not close independently")
          local remaining = assert(windows(a.shell_pid)[1])
          assert(window_id(remaining) == b.window_id, "first Close removed the other Window")
          if shared then
            local pid
            for value in trace():gmatch("Shell Sidebar connected: pid=(%d+)") do pid = tonumber(value) end
            local frontend = assert(kernel.OpenProcess(0x100000, 0, tonumber(pid)))
            assert(kernel.WaitForSingleObject(frontend, 0) ~= 0, "first Window Close ended the shared Sidebar")
            kernel.CloseHandle(frontend)
            os.remove(root .. "/sidebar-0.lua")
            user32.PostMessageW(remaining, 0x804d, 0, 0)
            local model = wait_for(function() return load("sidebar-0") end, 3)
            assert(model.windows and #model.windows == 1 and model.windows[1].id == b.window_id,
              "Sidebar snapshot did not retain the surviving Window's selection")
          end
          user32.PostMessageW(remaining, 0x112, 0xe010, 0)
          wait_for(function() return #windows(a.shell_pid) == 2 end, 5,
            "remaining Window native controls required the first Window")
          for _, item in ipairs(windows(a.shell_pid)) do
            if item ~= remaining then user32.PostMessageW(item, 0x10, 0, 0) end
          end
          save("finish", {continue = true})
          wait_for(function() return #windows(a.shell_pid) == 0 end, 10, "second Project did not close")
          return
        end
        local function scroll(window, state)
          local x = math.floor(state.x)
          local y = math.floor(state.y)
          user32.PostMessageW(window, 0x804a, 0, x + y * 65536)
          user32.PostMessageW(window, 0x804a, 3, x + y * 65536)
        end
        local second_window
        for _, item in ipairs(windows(a.shell_pid)) do
          if window_id(item) == b.window_id then second_window = item end
        end
        scroll(assert(second_window), b)
        assert(wait_for(function() return load("wheel-b") end, 5, "second Window input did not reach its Project").scroll > 0)
        assert(not load("wheel-a"), "second Window input reached the first Project")
        scroll(original, a)
        assert(wait_for(function() return load("wheel-a") end, 5, "first Window input did not reach its Project").scroll > 0)
        user32.PostMessageW(original, 0x112, 0xf020, 0)
        wait_for(function() return user32.IsIconic(original) ~= 0 end, 3)
        save("duplicate", {continue = true})
        wait_for(function() return load("duplicate-requested") end, 5)
        wait_for(function() return user32.IsIconic(original) == 0 end, 5,
          "duplicate selection did not raise the Project's owning Window")
        assert(#windows(a.shell_pid) == 2, "duplicate Project selection created another Window")
        local _, first = trace():gsub("\\", "/"):gsub("Shell started Project pid=%d+ path=[^\r\n]+/Project[\r\n]", "")
        local _, second = trace():gsub("\\", "/"):gsub("Shell started Project pid=%d+ path=[^\r\n]+/Replacement[\r\n]", "")
        assert(first == 1 and second == 1, "duplicate selection created another Project runtime")
        user32.PostMessageW(original, 0x112, 0xf020, 0)
        wait_for(function() return user32.IsIconic(original) ~= 0 end, 3)
        save("same-project", {continue = true})
        wait_for(function() return user32.IsIconic(original) == 0 end, 5,
          "Open Project command rejected the requesting Window's loaded Project")
        user32.PostMessageW(original, 0x112, 0xf030, 0)
        wait_for(function() return user32.IsZoomed(original) ~= 0 end, 3)
        save("maximized-project", {continue = true})
        wait_for(function() return load("maximized-requested") end, 5)
        coroutine.yield(.3)
        local open_preserved = user32.IsZoomed(original) ~= 0
        if not open_preserved then
          user32.PostMessageW(original, 0x112, 0xf030, 0)
          wait_for(function() return user32.IsZoomed(original) ~= 0 end, 3)
        end
        os.remove(root .. "/sidebar-0.lua")
        user32.PostMessageW(original, 0x804d, 0, 0)
        local page = wait_for(function() return load("sidebar-0") end, 3)
        local row
        for _, item in ipairs(page.items) do
          if item.kind == "project" and item.path:gsub("\\", "/") == root .. "/Project" then row = item.row_id end
        end
        user32.PostMessageW(original, 0x804d, 1, assert(row))
        coroutine.yield(.3)
        local sidebar_preserved = user32.IsZoomed(original) ~= 0
        assert(open_preserved and sidebar_preserved,
          "Maximized Window lost its state: hosted Open Project=" .. tostring(open_preserved)
            .. " Sidebar selection=" .. tostring(sidebar_preserved))
        save("finish", {continue = true})
        wait_for(function() return not subject:running() end, 10)
        assert(subject:returncode() == 0)
        return
      end
      save("new", {continue = true})
      wait_for(function() return load("new-requested") end, 5)
      local owned = wait_for(function()
        local all = windows(a.shell_pid)
        return #all == 2 and all
      end, 8, "New Window did not belong to the existing shell")
      local _, projects = trace():gsub("\\", "/"):gsub("Shell started Project pid=%d+ path=[^\r\n]+/Project[\r\n]", "")
      assert(projects == 1, "New Window loaded another Project")
      local empty = owned[1] == original and owned[2] or owned[1]
      if action:match("^windows%-picker") then
        local id = assert(window_id(empty))
        user32.PostMessageW(empty, 0x112, 0xe020, 0)
        wait_for(function() return trace():find("Shell Open Project picker started: Window=" .. id, 1, true) end,
          5, "shell-owned Project folder picker did not start")
        if action == "windows-picker-native" then
          local picker = wait_for(function() return dialog(a.shell_pid) end, 5,
            "shell folder picker did not create its native dialog")
          assert(user32.GetWindow(picker, 4) == empty, "Project folder picker has the wrong parent")
          user32.PostMessageW(picker, 0x10, 0, 0)
          wait_for(function() return trace():find("Shell Open Project picker cancelled: Window=" .. id, 1, true) end, 5)
        else
          local target = services(a.shell_pid)
          if action == "windows-picker-late" then
            user32.PostMessageW(empty, 0x10, 0, 0)
            wait_for(function() return #windows(a.shell_pid) == 1 end, 5)
            user32.PostMessageW(original, 0x112, 0xe010, 0)
            wait_for(function() return #windows(a.shell_pid) == 2 end, 5)
            for _, item in ipairs(windows(a.shell_pid)) do if item ~= original then empty = item end end
            assert(window_id(empty) ~= id, "replacement Window reused a stale identity")
            user32.PostMessageW(target, 0x8050, 1, id)
            wait_for(function() return trace():find("picker result for removed or closing Window=" .. id, 1, true) end, 5)
            assert(not load("b-ready"), "late picker result loaded a Project into another Window")
            assert(#windows(a.shell_pid) == 2, "late picker result created another Window")
          else
            user32.PostMessageW(target, 0x8050, 3, id)
            wait_for(function() return trace():find("Shell Open Project picker cancelled: Window=" .. id, 1, true) end, 5,
              "picker cancellation did not preserve the empty Window")
            assert(#windows(a.shell_pid) == 2 and not load("b-ready"), "picker cancellation loaded a Project")
            user32.PostMessageW(empty, 0x112, 0xe020, 0)
            wait_for(function()
              local _, starts = trace():gsub("Shell Open Project picker started: Window=" .. id, "")
              return starts == 2
            end, 5)
            user32.PostMessageW(target, 0x8050, 1, id)
            local b = wait_for(function() return load("b-ready") end, 15, "accepted picker did not load the Project")
            assert(b.shell_pid == a.shell_pid and b.window_id == id,
              "empty Window Open Project loaded into the wrong Window")
            assert(#windows(a.shell_pid) == 2, "empty Window Open Project created another Window")
            save("finish", {continue = true})
            wait_for(function() return not subject:running() end, 10)
            assert(subject:returncode() == 0)
            return
          end
        end
      end
      if action == "windows-menu" then
        local menu = assert(user32.GetSystemMenu(empty, 0))
        assert(user32.GetMenuState(menu, 0xe010, 0) ~= 0xffffffff,
          "Title Bar menu has no New Window action")
        assert(user32.GetMenuState(menu, 0xe020, 0) ~= 0xffffffff,
          "Title Bar menu has no Open Project action")
        user32.PostMessageW(empty, 0x112, 0xe010, 0)
        wait_for(function() return #windows(a.shell_pid) == 3 end, 5,
          "empty Window native New Window action required a Project")
        for _, window in ipairs(windows(a.shell_pid)) do
          if window ~= original then user32.PostMessageW(window, 0x10, 0, 0) end
        end
      else
      user32.PostMessageW(empty, 0x10, 0, 0)
      end
      wait_for(function() return #windows(a.shell_pid) == 1 end, 5, "empty Window Close ended the wrong Window")
      assert(subject:running(), "empty Window Close ended the shell")
      save("finish", {continue = true})
      wait_for(function() return not subject:running() end, 10)
      assert(subject:returncode() == 0)
    end)
    local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
    file:write("return ", common.serialize {ok = ok, action = action, error = ok and nil or tostring(err)})
    file:close()
    if subject and subject:running() then subject:terminate(); subject:wait(1) end
    quit()
  end)
else
  core.add_background_thread(function()
    local state = {pid = tonumber(kernel.GetCurrentProcessId()), shell_pid = system.get_window_process_id(),
      window_id = system.get_anvil_window_id and system.get_anvil_window_id() or 0}
    if action == "windows-open" then
      local editor = core.open_file(path .. "/edited.txt")
      core.set_active_view(editor)
      wait_for(function() return editor.size.x > 0 and editor.size.y > 0 end, 5)
      coroutine.yield(.2)
      state.x, state.y = editor:get_line_screen_position(1, 2)
      state.y = state.y + editor:get_line_height() / 2
      local on_event = core.on_event
      core.on_event = function(kind, ...)
        local result = on_event(kind, ...)
        if kind == "mousewheel" then
          save(path == root .. "/Replacement" and "wheel-b" or "wheel-a", {scroll = editor.scroll.to.y})
        end
        return result
      end
    end
    if path == root .. "/Replacement" then
      save("b-ready", state)
      if action ~= "windows-open" then
        wait_for(function() return load("finish") end, 25)
        quit(); return
      end
      wait_for(function() return load("duplicate") end, 20)
      assert(core.open_project_in_new_window(root .. "/Project/."))
      save("duplicate-requested", {continue = true})
      wait_for(function() return load("finish") end, 20)
      quit(); return
    end
    save("a-ready", state)
    if action == "windows-picker-command" then
      wait_for(function() return load("open") end, 15)
      assert(command.perform("core:open_project_folder_system_file_picker"))
      wait_for(function() return load("finish") end, 25)
      quit(); return
    end
    if action == "windows-open" or action == "windows-owner-close" or shared then
      wait_for(function() return load("open") end, 15)
      require("core.config").plugins.ipc.single_instance = true
      assert(command.perform("core:open_project_folder_in_new_window"))
      core.global_prompt_bar:set_text(root .. "/Replacement")
      core.global_prompt_bar:submit()
      if action == "windows-owner-close" or shared then
        wait_for(function() return load("close-a") end, 25)
        quit(); return
      end
      wait_for(function() return load("same-project") end, 25)
      assert(command.perform("core:open_project_folder_in_new_window"))
      core.global_prompt_bar:set_text(root .. "/Project")
      core.global_prompt_bar:submit()
      wait_for(function() return load("maximized-project") end, 25)
      assert(core.open_project_in_new_window(root .. "/Project"))
      save("maximized-requested", {continue = true})
      wait_for(function() return load("finish") end, 25)
      quit(); return
    end
    wait_for(function() return load("new") end, 15)
    assert(command.perform("core:new_anvil_window"), "New Window command is unavailable")
    save("new-requested", {continue = true})
    wait_for(function() return load("finish") end, 35)
    quit()
  end)
end
