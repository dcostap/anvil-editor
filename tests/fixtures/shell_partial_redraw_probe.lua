-- mod-version:3
-- Seam: a hosted surface keeps its last frame and redraws only the cells that change. After each edit, scroll,
-- popup and selection change, a Project's kept frame must equal a whole redraw of the same state, pixel for pixel.
-- The transparent Sidebar must return to the same pixels after a hover ends.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "partial-redraw" then return end
local core, common, config, command = require "core", require "core.common", require "core.config", require "core.command"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
 int __stdcall CloseHandle(void *);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 unsigned int __stdcall GetDpiForWindow(void *);
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
 error(message or "partial redraw probe timed out")
end
local function read(file_path)
 local file = io.open(file_path, "rb")
 if not file then return end
 local text = file:read("*a"); file:close(); return text
end

local function trace() return read(os.getenv("ANVIL_SURFACE_LOG")) or "" end
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
-- The bytes of the shell's next composed frame.
local function capture(window, index)
 user32.SendMessageW(window, 0x8052, index, 0)
 local pattern = "Shell probe capture written: ([^\r\n]-capture%-" .. index .. "%.bmp)"
 local file = wait(function() return trace():match(pattern) end, 5, "shell capture " .. index .. " was not written")
 return assert(read(file))
end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   local process = require "core.process"
   shell = assert(process.start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local result = wait(function() return load("project-result") end, 90, "the Project did not finish its steps")
   assert(result.ok, result.error)
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 15, "Sidebar did not become Ready")
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   -- The shell's routing probe message moves the pointer; posted Win32 input is ignored on an inactive desktop.
   local scale = user32.GetDpiForWindow(window) / 96
   local function hover(y) user32.PostMessageW(window, 0x804a, 0, 100 + math.floor(y * scale) * 65536) end
   hover(400); coroutine.yield(1)
   local before = capture(window, 1)
   hover(54); coroutine.yield(.5)
   hover(400); coroutine.yield(1)
   assert(capture(window, 2) == before, "the Sidebar kept part of its hover after the pointer left")
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  if shell and shell:running() then shell:terminate(); shell:wait(1) end
  local state = load("project-result")
  local handle = state and kernel.OpenProcess(0x1F0FFF, 0, state.pid)
  if handle ~= nil and handle then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
  core.exit(function() core.quit_request = true end, true)
 end)
elseif path:match("/Project$") then
 core.add_background_thread(function()
  local ok, err = pcall(function()
   coroutine.yield(.5)
   config.disable_blink = true
   config.transitions = false
   local Editor = require "core.editor"
   local autocomplete = require "plugins.autocomplete"
   local buffer = core.open_buffer()
   local view = require("core.panes").place(function() return Editor(buffer) end, {placement="new", focus=true})
   wait(function() return view.size.x > 0 end, 10, "the Editor has no size")
   local lines = {}
   for i = 1, 120 do lines[i] = string.format("line %03d: the quick brown fox jumps over the lazy dog", i) end
   buffer:insert(1, 1, table.concat(lines, "\n"))
   view:with_selection_state(function() buffer:set_selection(12, 10) end)
   local function perform(name) assert(command.perform(name), name .. " did not run") end
   local function type_text(text) view:with_selection_state(function() buffer:text_input(text) end) end
   autocomplete.add_provider("partial-redraw-probe", function(active_view)
    if active_view ~= view then return nil end
    local line, col
    view:with_selection_state(function() line, col = buffer:get_selection() end)
    return {query="", line=line, query_col=col, items={{text="alpha"}, {text="beta"}, {text="gamma"}}}
   end)
   local steps = {
    {"type", function() type_text("x") end},
    {"type a word", function() type_text("yz w") end},
    {"backspace", function() perform("core:backspace") end},
    {"next line", function() perform("core:move_to_next_line") end},
    {"select word", function() perform("core:select_word") end},
    {"select none", function() perform("core:select_none") end},
    {"line end", function() perform("core:move_to_end_of_line") end},
    {"buffer end", function() perform("core:move_to_end_of_buffer") end},
    {"buffer start", function() perform("core:move_to_start_of_buffer") end},
    {"popup", function() autocomplete.trigger() end},
    {"popup closed", function() autocomplete.close() end},
    {"newline", function() perform("core:newline") end},
    {"undo", function() perform("core:undo") end},
   }
   local function capture(name)
    local file = root .. "/" .. name .. ".png"
    os.remove(file)
    assert(renwindow.request_frame_capture(core.window, file))
    core.redraw = true
    return wait(function() return read(file) end, 10, name .. " was not captured")
   end
   for i, step in ipairs(steps) do
    step[2]()
    core.redraw = true
    -- Let the state settle over several frames, so the kept frame has drawn each change.
    for _ = 1, 4 do coroutine.yield(.05); core.redraw = true end
    local kept = capture(string.format("step-%02d-kept", i))
    renwindow._invalidate(core.window)
    local whole = capture(string.format("step-%02d-whole", i))
    assert(kept == whole, string.format("step %d (%s): the kept frame differs from a whole redraw", i, step[1]))
   end
  end)
  save("project-result", {ok=ok, error=ok and nil or tostring(err), pid=tonumber(kernel.GetCurrentProcessId())})
 end)
end
