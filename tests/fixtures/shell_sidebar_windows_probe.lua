-- mod-version:3
-- Seam: hosted commands and content bounds in owned Windows on a private desktop.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "windows-sidebar-layout" and action ~= "windows-sidebar-folding" then return end
local core, common = require "core", require "core.common"
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local path = core.root_project().path:gsub("\\", "/")
local function save(name, value)
  local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
  file:write("return ", common.serialize(value)); file:close()
end
local function load(name)
  local file = io.open(root .. "/" .. name .. ".lua", "rb")
  if not file then return end
  local text = file:read("*a"); file:close()
  local chunk = loadstring(text)
  return chunk and chunk()
end
local function wait(fn, message)
  local deadline = system.get_time() + 30
  repeat
    local value = fn()
    if value then return value end
    coroutine.yield(.01)
  until system.get_time() >= deadline
  error(message or "Window Sidebar probe timed out")
end
local function quit() core.exit(function() core.quit_request = true end, true) end

if path:match("/driver$") then
  local ffi = require "ffi"
  ffi.cdef [[
    int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
    unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
  ]]
  local user32 = ffi.load("user32")
  local LEFT, RIGHT = 0x40000050, 0x4000004f -- SDL keycodes, not Windows virtual keys.
  local function native_window(pid, id)
    local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
    local text = file:read("*a"); file:close()
    for candidate, hex in text:gmatch("Shell Window record: id=(%d+) SDL=%d+ hwnd=(%x+)") do
      if tonumber(candidate) == id then
        local window = ffi.cast("void *", tonumber(hex, 16))
        local owner = ffi.new("unsigned long[1]")
        user32.GetWindowThreadProcessId(window, owner)
        if tonumber(owner[0]) == pid then return window end
      end
    end
  end
  core.add_background_thread(function()
    local children = {}
    local function launch(...)
      local child = assert(require("core.process").start({EXEFILE, ...}, {
        stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
      children[#children + 1] = child
      return child
    end
    local function state(phase, name) return load("state-" .. phase .. "-" .. name) end
    local function request(phase, name, step, command)
      save("request-" .. phase .. "-" .. name, {step=step, command=command})
      wait(function()
        local report = state(phase, name)
        return report and report.step == step
      end, "Project did not accept " .. command)
    end
    local function bounds(phase, a, b, message)
      wait(function()
        local first, second = state(phase, "Project"), state(phase, "Replacement")
        return first and second and first.x == a and second.x == b
      end, message)
    end
    local function update_stop(shell)
      local request = launch("--prepare-update")
      wait(function() return not request:running() end, "Update request did not finish")
      assert(request:returncode() == 0, "Update request failed")
      wait(function() return not shell:running() end, "Update did not close all Windows")
      assert(shell:returncode() == 0, "Shell failed during update")
    end
    local function fold(id, name)
      local saved = require("core.storage").load("sidebar", "folding") or {}
      for key, value in pairs(saved[id] or {}) do
        if key:gsub("\\", "/"):lower() == ("project:" .. root .. "/" .. name):lower() then return value end
      end
    end
    local function press(shell, id, key)
      local window = assert(native_window(shell:pid(), id))
      user32.PostMessageW(window, 0x804a, 9, key)
      user32.PostMessageW(window, 0x804a, 10, key)
    end
    local function focus(shell, phase, name, id, step)
      local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
      local mark = file:seek("end") + 1; file:close()
      request(phase, name, step, "core:focus_project_sidebar")
      wait(function()
        local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
        local text = file:read("*a"); file:close()
        return text:find("Shell Sidebar focus: Window=" .. id .. " focused=1", mark, true)
      end, "Sidebar did not take keyboard focus")
    end
    local ok, err = pcall(function()
      save("phase", 1)
      local shell = launch("--shell", root .. "/Project")
      local first = wait(function() return state(1, "Project") end)
      assert(first.initial_x > 0, "The first Window did not start with its Sidebar open")
      local full = first.initial_x
      request(1, "Project", 1, "new-window")
      local second = wait(function() return state(1, "Replacement") end)
      local first_id, second_id = first.window, second.window
      assert(second.window ~= first.window, "Projects did not get separate Windows")
      assert(second.initial_x == 0, "An additional Window did not start with its Sidebar collapsed")
      bounds(1, full, 0, "New Window changed the first Window's Sidebar")
      if action == "windows-sidebar-folding" then
        focus(shell, 1, "Project", first_id, 2)
        press(shell, first_id, LEFT); press(shell, first_id, LEFT) -- Parent, then collapse.
        wait(function() return fold(first_id, "Project") == true end, "First Window did not save its fold")
        request(1, "Replacement", 1, "core:toggle_project_sidebar")
        bounds(1, full, full, "The second Sidebar did not finish opening")
        focus(shell, 1, "Replacement", second_id, 2)
        press(shell, second_id, LEFT); press(shell, second_id, LEFT)
        wait(function() return fold(second_id, "Replacement") == true end, "Second Window did not save its fold")
        press(shell, second_id, RIGHT)
        wait(function() return fold(second_id, "Replacement") == false end, "Second Window did not save its expansion")
        assert(fold(first_id, "Project") == true and fold(first_id, "Replacement") == nil
          and fold(second_id, "Project") == nil, "Folding choices leaked between Windows")
        update_stop(shell)
        save("phase", 2)
        shell = launch("--shell")
        first = wait(function() return state(2, "Project") end)
        second = wait(function() return state(2, "Replacement") end)
        assert(first.window == first_id and second.window == second_id, "Restore moved folding to another Window")
        focus(shell, 2, "Project", first_id, 1)
        -- A collapsed Selected Project starts at its header. Right must expand it and save that choice.
        press(shell, first_id, RIGHT)
        wait(function() return fold(first_id, "Project") == false end, "The restored Selected Project lost its fold")
        assert(fold(second_id, "Replacement") == false and fold(second_id, "Project") == nil,
          "Changing the restored Window changed another Window's folds")
        return update_stop(shell)
      end
      request(1, "Replacement", 1, "core:toggle_project_sidebar")
      bounds(1, full, full, "Opening the second Sidebar changed the first")
      request(1, "Project", 2, "core:toggle_project_sidebar")
      bounds(1, 0, full, "Closing the first Sidebar changed the second")
      request(1, "Replacement", 2, "core:toggle_project_sidebar")
      bounds(1, 0, 0, "Closing the second Sidebar changed the first")
      request(1, "Project", 3, "core:focus_project_sidebar")
      bounds(1, full, 0, "Focusing one Sidebar opened another Window's Sidebar")
      request(1, "Project", 4, "core:toggle_project_sidebar")
      bounds(1, 0, 0, "The focused Sidebar did not close")
      request(1, "Replacement", 3, "core:toggle_project_sidebar")
      bounds(1, 0, full, "The second Sidebar did not open independently")
      -- Save the opposite of the new-Window defaults. Restore must not apply those defaults again.
      update_stop(shell)
      -- Model a different saved activation order at the persistence boundary.
      -- The private desktop cannot give a Window real foreground keyboard focus.
      local state_path = root .. "/user/shell-windows.state"
      local file = assert(io.open(state_path, "rb"))
      local text = file:read("*a"); file:close()
      local record = assert(text:match("\n(window " .. first_id .. " [^\n]*\n)"))
      text = text:gsub("\nwindow " .. first_id .. " [^\n]*\n", "\n", 1)
      text = text:gsub("^(anvil%-shell%-windows %d+\n)", function(header) return header .. record end, 1)
      file = assert(io.open(state_path, "wb")); file:write(text); file:close()
      save("phase", 2)
      shell = launch("--shell")
      first = wait(function() return state(2, "Project") end)
      second = wait(function() return state(2, "Replacement") end)
      assert(first.window ~= second.window, "Restore merged the Windows")
      assert(first.window == first_id and second.window == second_id,
        "Restore changed Window identities and would move saved folding between Windows")
      assert(first.initial_x == 0 and second.initial_x == full, "Restore lost per-Window Sidebar visibility")
      bounds(2, 0, full, "Restored Sidebars did not keep their saved visibility")
      request(2, "Project", 1, "core:toggle_project_sidebar")
      bounds(2, full, full, "The restored first Sidebar did not open")
      request(2, "Replacement", 1, "core:toggle_project_sidebar")
      bounds(2, full, 0, "Restored Windows still share Sidebar visibility")
      update_stop(shell)
    end)
    save("result", {ok=ok, error=ok and nil or tostring(err), action=action})
    for _, child in ipairs(children) do if child:running() then child:terminate(); child:wait(1) end end
    quit()
  end)
elseif path == root .. "/Project" or path == root .. "/Replacement" then
  local phase, name = assert(load("phase")), path:match("[^/]+$")
  core.add_background_thread(function()
    if action == "windows-sidebar-folding" then core.set_active_view(core.open_file(path .. "/edited.txt")) end
    local initial, last, step = system.get_window_content_x(), nil, 0
    while true do
      local request = load("request-" .. phase .. "-" .. name)
      if request and request.step > step then
        step = request.step
        if request.command == "new-window" then
          assert(core.open_project_in_new_window(root .. "/Replacement"))
        else
          assert(require("core.command").perform(request.command), "Sidebar command is unavailable")
        end
        last = nil
      end
      local x = system.get_window_content_x()
      if x ~= last then
        last = x
        save("state-" .. phase .. "-" .. name,
          {x=x, initial_x=initial, step=step, window=system.get_anvil_window_id()})
      end
      coroutine.yield(.01)
    end
  end)
end
