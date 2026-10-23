-- mod-version:3
-- Seam: shell focus commands and keyboard/text routing on an owned private desktop.
if os.getenv("ANVIL_PROJECT_PROBE") ~= "navigate-sidebar" then return end
local core, common = require "core", require "core.common"
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local path = core.root_project().path:gsub("\\", "/")
local function save(name, value)
  local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
  file:write("return ", common.serialize(value)); file:close()
end
local function load(name)
  local chunk = loadfile(root .. "/" .. name .. ".lua")
  return chunk and chunk()
end
local function wait(fn, message)
  local deadline = system.get_time() + 30
  repeat
    local value = fn()
    if value then return value end
    coroutine.yield(.02)
  until system.get_time() >= deadline
  error(message)
end
local function trace()
  local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
  local text = file:read("*a"); file:close(); return text
end
if path:match("/driver$") then
  local ffi = require "ffi"
  ffi.cdef [[
    int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
    unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
    void * __stdcall GetPropW(void *, const wchar_t *);
    int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
  ]]
  local user32 = ffi.load("user32")
  local function shell_window(pid)
    local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
    local found
    local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
      local owner = ffi.new("unsigned long[1]")
      user32.GetWindowThreadProcessId(window, owner)
      if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then found = window end
      return 1
    end)
    user32.EnumWindows(cb, 0); cb:free(); return found
  end
  core.add_background_thread(function()
    local shell
    local ok, err = pcall(function()
      shell = assert(require("core.process").start({EXEFILE, "--shell", root .. "/Project"},
        {stdin=process.REDIRECT_DISCARD,stdout=process.REDIRECT_DISCARD,stderr=process.REDIRECT_DISCARD}))
      local window = wait(function() return shell_window(shell:pid()) end, "Shell Window missing")
      wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, "Sidebar not ready")
      wait(function() return load("ready") end, "Project not ready")
      local function press(key)
        user32.PostMessageW(window, 0x804a, 9, key)
        user32.PostMessageW(window, 0x804a, 10, key)
      end
      local function focus(step)
        local mark = #trace() + 1
        save("focus-" .. step, true)
        wait(function() return trace():find("Shell Sidebar focus: Window=%d+ focused=1", mark) end,
          "Sidebar did not take focus")
        return mark
      end
      local mark = focus(1)
      press(27) -- Escape returns focus without changing the Project.
      wait(function() return trace():find("Shell Sidebar focus: Window=%d+ focused=0", mark) end,
        "Escape did not return focus")
      save("hide", true)
      wait(function() return load("hidden") end, "Sidebar did not hide")
      mark = focus(2)
      wait(function() return load("shown") end, "Focusing did not reveal the Sidebar")
      -- Search a Tab through the shell's text transport, then activate it through the key transport.
      user32.PostMessageW(window, 0x804a, 11, string.byte("z"))
      press(13)
      wait(function() return load("activated") end, "Search did not activate the matching Tab")
      assert(trace():find("Shell Sidebar focus: Window=%d+ focused=0", mark), "Activation kept Sidebar focus")
      save("finish", true)
      wait(function() return not shell:running() end, "Shell did not exit")
    end)
    save("finish", true)
    if shell and shell:running() then shell:terminate(); shell:wait(1) end
    local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
    file:write("return ", common.serialize {ok=ok,error=not ok and tostring(err) or nil}); file:close()
    core.exit(function() core.quit_request = true end, true)
  end)
else
  core.add_background_thread(function()
    local command = require "core.command"
    local panes = require "core.panes"
    local Editor = require "core.editor"
    core.open_file(path .. "/edited.txt")
    local first = panes.active()
    local file = assert(io.open(path .. "/zebra.txt", "wb")); file:write("zebra\n"); file:close()
    local view = Editor(core.open_buffer(path .. "/zebra.txt"))
    assert(panes.split(first, "right", {factory=function() return view end}))
    panes.focus(first)
    save("ready", true)
    wait(function() return load("focus-1") end, "Focus request missing")
    assert(command.perform("core:focus_project_sidebar"))
    wait(function() return load("hide") end, "Hide request missing")
    assert(command.perform("core:toggle_project_sidebar"))
    wait(function() return system.get_window_content_x() == 0 end, "Sidebar stayed visible")
    save("hidden", true)
    wait(function() return load("focus-2") end, "Second focus request missing")
    assert(command.perform("core:focus_project_sidebar"))
    wait(function() return system.get_window_content_x() > 0 end, "Sidebar stayed hidden")
    save("shown", true)
    wait(function() return core.active_view == view end, "Matching Tab did not gain focus")
    save("activated", true)
    wait(function() return load("finish") end, "Finish request missing")
    command.perform("core:quit")
  end)
end
