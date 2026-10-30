-- mod-version:3
-- Seam: Alt Navigation in the shell's keyboard routing, from the toggle command to the keys a Project gets.
if os.getenv("ANVIL_PROJECT_PROBE") ~= "alt-navigation" then return end
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
local function read(file_path)
  local file = io.open(file_path, "rb")
  if not file then return "" end
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
      wait(function() return load("ready") end, "Project not ready")
      local LALT, J, SPACE = 0x400000e2, string.byte("j"), string.byte(" ")
      local function down(key) user32.PostMessageW(window, 0x804a, 9, key) end
      local function up(key) user32.PostMessageW(window, 0x804a, 10, key) end
      save("toggle", true)
      wait(function() return load("on") end, "Alt Navigation did not turn on")
      down(LALT); down(J); up(J)
      wait(function() return load("word") end, "Alt+J did not move one word left")
      down(SPACE); up(SPACE); up(LALT)
      wait(function() return load("space") end, "Alt+Space did not type a space")
      save("finish", true)
      wait(function() return not shell:running() end, "Shell did not exit")
      assert(read(root .. "/user/shell-windows.state"):find("\nalt-navigation\n", 1, true),
        "Shell App State did not save Alt Navigation")
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
    local keymap = require "core.keymap"
    local view = wait(function()
      local v = core.open_file(path .. "/edited.txt")
      return v and v.buffer and v
    end, "File did not open")
    local buffer = view.buffer
    buffer:remove(1, 1, math.huge, math.huge)
    buffer:insert(1, 1, "one two three")
    buffer:set_selection(1, 14)
    save("ready", true)
    wait(function() return load("toggle") end, "Toggle request missing")
    assert(command.perform("core:toggle_alt_navigation"))
    wait(function()
      for _, item in ipairs(core.log_items) do
        if item.text == "Alt Navigation is on" then return true end
      end
    end, "The shell did not report Alt Navigation on")
    save("on", true)
    -- Alt+J is Ctrl+Left. Alt is still held, as the user holds it, and Ctrl is not stuck.
    wait(function()
      local line, col = buffer:get_selection()
      return line == 1 and col == 9
    end, "Caret did not move to the start of the previous word")
    assert(keymap.modkeys.alt and not keymap.modkeys.ctrl,
      "Modifier state after Alt+J: alt=" .. tostring(keymap.modkeys.alt) .. " ctrl=" .. tostring(keymap.modkeys.ctrl))
    save("word", true)
    wait(function() return buffer:get_text(1, 1, 1, math.huge) == "one two  three" end,
      "Alt+Space did not type one space")
    save("space", true)
    wait(function() return load("finish") end, "Finish request missing")
    buffer:clean()
    command.perform("core:close_current_window")
  end)
end
