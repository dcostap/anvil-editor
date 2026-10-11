-- mod-version:3
-- Seam: a scripted Win32 live resize of an owned hosted Window on a private desktop. Each size step must present
-- Project content of the new size, so the new area never shows a void.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^resize%-") then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 typedef struct { long left, top, right, bottom; } RECT;
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall SetWindowPos(void *, void *, int, int, int, int, unsigned int);
 int __stdcall GetWindowRect(void *, RECT *);
 int __stdcall ShowWindow(void *, int);
 int __stdcall IsZoomed(void *);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
]]
local user32, kernel = ffi.load("user32"), ffi.load("kernel32")
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local path = core.root_project().path:gsub("\\", "/")
local function save(name, value)
 local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
 file:write("return ", common.serialize(value)); file:close()
end
local function load(name)
 local file = io.open(root .. "/" .. name .. ".lua", "rb")
 if not file then return end
 local text = file:read("*a"); file:close(); return assert(loadstring(text))()
end
local function wait(fn, seconds, message)
 local deadline = system.get_time() + (seconds or 10)
 repeat local value = fn(); if value then return value end; coroutine.yield(.01) until system.get_time() >= deadline
 error(message or "shell resize probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
local function shell_window(pid)
 local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
 local found
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then found = window end
  return 1
 end)
 user32.EnumWindows(cb, 0); cb:free(); return found
end
local function quit() core.exit(function() core.quit_request = true end, true) end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell, stats
  local ok, err = pcall(function()
   shell = assert(require("core.process").start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD,
     -- Per-frame Project timings, kept beside the result for diagnosis.
     env={ANVIL_RESIZE_STATS="1", ANVIL_RESIZE_STATS_FLUSH="1", ANVIL_RESIZE_STATS_FILE=root .. "/project-resize.csv",
      ANVIL_D3D11_STATS="1", ANVIL_D3D11_STATS_FILE=root .. "/project-d3d11.csv"}}))
   wait(function() return load("ready") end, 30, "Project did not become ready")
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   if user32.IsZoomed(window) ~= 0 then user32.ShowWindow(window, 9) end
   assert(user32.SetWindowPos(window, nil, 100, 100, 900, 700, 0x14) ~= 0)
   coroutine.yield(1)
   -- One drag: enter the size/move loop, step the edge at about 60 Hz, then leave the loop.
   local function drag(label, steps, dx, left_edge)
    local text = trace(); local mark = #text
    user32.SendMessageW(window, 0x231, 0, 0)
    local rect = ffi.new("RECT[1]")
    for i = 1, steps do
     assert(user32.GetWindowRect(window, rect) ~= 0)
     local x, y = tonumber(rect[0].left), tonumber(rect[0].top)
     local w, h = tonumber(rect[0].right - rect[0].left), tonumber(rect[0].bottom - rect[0].top)
     if left_edge then x, w = x - dx, w + dx else w = w + dx end
     assert(user32.SetWindowPos(window, nil, x, y, w, h, 0x14) ~= 0)
     coroutine.yield(1 / 60)
    end
    user32.SendMessageW(window, 0x232, 0, 0)
    coroutine.yield(.5)
    local total, matched, waits = 0, 0, {}
    for line in trace():sub(mark + 1):gmatch("Shell resize step:[^\n]*") do
     total = total + 1
     if line:find("matched=1", 1, true) then matched = matched + 1 end
     waits[#waits + 1] = tonumber(line:match("wait_ms=([%d%.]+)"))
    end
    table.sort(waits)
    return {label=label, total=total, matched=matched, wait_p50=waits[math.ceil(#waits / 2)],
     wait_max=waits[#waits]}
   end
   stats = {
    drag("right grow", 40, 12), drag("right shrink", 40, -12),
    drag("left grow", 40, 12, true), drag("left shrink", 40, -12, true),
    drag("right fast", 20, 40), drag("left fast", 20, -40, true),
   }
   -- Exposed areas and the native UI take the Project's theme background, not a fixed colour.
   local reported
   for color in trace():gmatch("Shell Window background: id=%d+ color=(%x+)") do reported = tonumber(color, 16) end
   local bg = require("core.style").background
   local expected = math.floor(bg[1]) + math.floor(bg[2]) * 256 + math.floor(bg[3]) * 65536
   assert(reported == expected, string.format("shell background %s, expected the Project theme background %06x",
    reported and string.format("%06x", reported) or "unreported", expected))
   for _, item in ipairs(stats) do
    assert(item.total >= 15, item.label .. " drag produced too few resize steps: " .. item.total)
    assert(item.matched >= item.total * 0.9, string.format("%s drag presented matching content in %d of %d steps",
     item.label, item.matched, item.total))
   end
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action, stats=stats})
  file:close()
  if shell and shell:running() then shell:terminate(); shell:wait(1) end
  local ready = load("ready")
  if ready then
   local handle = kernel.OpenProcess(0x1F0FFF, 0, ready.pid)
   if handle ~= nil then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
  end
  quit()
 end)
elseif path == root .. "/Project" then
 core.add_background_thread(function()
  -- Real text content, so each resize re-lays out and redraws a full Document View.
  local lines = {}
  for i = 1, 3000 do
   lines[i] = string.format("%5d  local value_%d = compute(%d, \"resize probe line with some text\") -- comment", i, i, i)
  end
  local file = assert(io.open(root .. "/Project/big.lua", "wb")); file:write(table.concat(lines, "\n")); file:close()
  assert(core.open_file(root .. "/Project/big.lua"))
  coroutine.yield(.5)
  save("ready", {pid=tonumber(kernel.GetCurrentProcessId())})
 end)
end
