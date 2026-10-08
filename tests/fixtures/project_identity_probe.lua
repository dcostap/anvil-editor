-- mod-version:3
-- Seam: Project selection and the owned native Window.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^identity%-") then return end
local core = require "core"
local common = require "core.common"
local ffi = require "ffi"
ffi.cdef [[ unsigned long __stdcall GetCurrentProcessId(void); ]]
ffi.cdef [[ intptr_t __stdcall SendMessageW(void *window, unsigned int message, uintptr_t wparam, intptr_t lparam); ]]
local kernel = ffi.load("kernel32")
local user32 = ffi.load("user32")
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
local function wait_for(fn, seconds, message)
  local deadline = system.get_time() + seconds
  repeat
    local value = fn()
    if value then return value end
    coroutine.yield(.01)
  until system.get_time() > deadline
  error(message or "identity probe timed out")
end
local function quit() core.exit(function() core.quit_request = true end, true) end
local directory = core.root_project().path:gsub("\\", "/"):gsub("/+$", "")
if directory:match("/driver$") then
  core.add_background_thread(function()
    local subject
    local ok, err = pcall(function()
      local process = require "core.process"
      local args = {EXEFILE, "--shell"}
      if action ~= "identity-cwd" then
        args[#args + 1] = (root .. (action == "identity-alias" and "/Project" or "/Project/")):gsub("/", "\\")
      end
      subject = assert(process.start(args, {cwd = root .. "/Project",
        stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD}))
      local initial = wait_for(function() return read("initial") end, 15)
      if action == "identity-allocation" then
        local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
        local text = file:read("*a"); file:close()
        local hex = assert(text:match("shell%[" .. initial.shell_pid .. "%] Shell window hwnd=(%x+)"))
        user32.SendMessageW(ffi.cast("void *", tonumber(hex, 16)), 0x804b, 12, 0)
      end
      local paths = {root .. "/Project", root .. "/Project/", (root .. "/Project"):upper()}
      if action == "identity-alias" then
        paths = {root .. "/alias", (root .. "/Project"):upper(), root .. "/Project/"}
        local short = os.getenv("ANVIL_PROJECT_SHORT_PATH")
        if short then paths[#paths + 1] = short
        else core.log_quiet("Project identity probe: 8.3 alias unavailable on this file system") end
      end
      save("requests", {count = #paths})
      for index, path in ipairs(paths) do
        save("go-" .. index, {path = path})
        local checked = wait_for(function() return read("checked-" .. index) or read("duplicate") end, 8)
        assert(not read("duplicate"), "same directory loaded another Project process")
        assert(checked.pid == initial.pid and checked.rendering, "same directory replaced the selected Project")
        if action == "identity-allocation" and index == 1 then
          local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
          local text = file:read("*a"); file:close()
          assert(text:find("identity allocation failed", 1, true), "owned allocation fault was not consumed")
          assert(not text:find("Shell state: Failed", 1, true), "selection allocation failure failed the current Project")
        end
      end
      save("finish", {continue = true})
      wait_for(function() return not subject:running() end, 10)
      assert(subject:returncode() == 0)
    end)
    save("result", {ok = ok, action = action, error = ok and nil or tostring(err)})
    if subject and subject:running() then subject:terminate(); subject:wait(1) end
    quit()
  end)
else
  core.add_background_thread(function()
    local pid = tonumber(kernel.GetCurrentProcessId())
    if read("initial") then save("duplicate", {pid = pid}); return end
    save("initial", {pid = pid, shell_pid = system.get_window_process_id()})
    local requests = wait_for(function() return read("requests") end, 5)
    for index = 1, requests.count do
      local request = wait_for(function() return read("go-" .. index) end, 12)
      assert(system.select_project(request.path))
      coroutine.yield(1)
      save("checked-" .. index, {pid = pid, rendering = system.window_should_render(core.window)})
    end
    wait_for(function() return read("finish") end, 10)
    quit()
  end)
end
