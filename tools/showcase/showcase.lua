-- mod-version:3
-- Screenshot showcase, installed only by tools/showcase/run_showcase.py. Every Lua process loads it.
-- The driver process starts the shell and captures its Window. Each loaded fake Project opens its Panes and
-- types the fake commands from tools/showcase/bin, which act like Pi, npm, cargo and Gradle.
local root = os.getenv("ANVIL_SHOWCASE_ROOT")
if not root then return end
local core = require "core"

-- The Panes of each loaded Project, in order. "split" shows the Pane beside the first one.
local scenarios = {
  ["orbit-api"] = {
    {file = "src/billing/invoice.ts"},
    {command = "pi orbit-claude", split = true},
    {command = "pi orbit-gpt"},
    {command = "npm run dev"},
  },
  ["raytracer"] = {
    {file = "src/bvh.rs"},
    {command = "pi ray-claude"},
    {command = "pi ray-gpt"},
    {command = "cargo watch -x run"},
  },
  ["mobile-app"] = {
    {file = "build.gradle.kts"},
    {command = "pi mobile-gpt"},
    {command = ".\\gradlew.bat runAppDesktop"},
  },
  ["dotfiles"] = {
    {file = ".bashrc"},
    {command = "pi dotfiles-claude"},
  },
}

local function exists(name)
  local info = system.get_file_info(root .. "/" .. name)
  return info ~= nil
end
local function touch(name)
  local file = assert(io.open(root .. "/" .. name, "wb"))
  file:close()
end
local function wait(predicate, seconds, message)
  local deadline = system.get_time() + seconds
  repeat
    local value = predicate()
    if value then return value end
    coroutine.yield(0.1)
  until system.get_time() >= deadline
  error(message)
end

local function hosted(name, path)
  local scenario = scenarios[name]
  if not scenario then return end
  local panes, terminal = require "core.panes", require "plugins.terminal"
  coroutine.yield(1)
  local first, views = nil, {}
  for index, item in ipairs(scenario) do
    if item.file then
      local view = core.open_file(path .. "/" .. item.file, {placement = index == 1 and "current" or "new"})
      first = first or (view and panes.pane_for_view(view))
    else
      local view = terminal.open {cwd = path, placement = item.split and "split" or "new", direction = "right",
        pane = item.split and first and first.id or nil}
      views[#views + 1] = view
      wait(function() return view.state == "running" end, 30, "Terminal did not start in " .. name)
      -- Give the interactive shell time to show its prompt before typing.
      coroutine.yield(2)
      view.session:write(item.command .. "\r")
    end
  end
  if first then panes.focus(first.id) end
  core.log_quiet("Showcase: %s ready", name)
  touch("ready-" .. name)
  wait(function() return exists("finish") end, 300, "Showcase driver did not finish")
  for _, view in ipairs(views) do view:on_close() end
  touch("closed-" .. name)
end

local function driver()
  local ffi = require "ffi"
  ffi.cdef [[
    int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
    unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
    void * __stdcall GetPropW(void *, const wchar_t *);
    intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
  ]]
  local user32 = ffi.load("user32")
  local function shell_window(pid)
    local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
    local found
    local callback = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
      local owner = ffi.new("unsigned long[1]")
      user32.GetWindowThreadProcessId(window, owner)
      if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then found = window end
      return 1
    end)
    user32.EnumWindows(callback, 0)
    callback:free()
    return found
  end
  local function log_text()
    local file = io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb")
    if not file then return "" end
    local text = file:read("*a")
    file:close()
    return text
  end

  local shell
  local ok, err = pcall(function()
    -- The shell restores the saved Window. Start it in the Selected Project, not in the driver's folder.
    shell = assert(require("core.process").start({EXEFILE, "--shell"}, {cwd = root .. "/Projects/orbit-api",
      stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD}))
    for name in pairs(scenarios) do
      wait(function() return exists("ready-" .. name) end, 120, "Project did not get ready: " .. name)
    end
    -- Let the Sidebar scan the Terminal Sessions and draw their status.
    coroutine.yield(8)
    local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
    user32.SendMessageW(window, 0x8052, 1, 0)
    wait(function() return log_text():find("capture%-1%.bmp") end, 10, "the shell did not write its capture")
  end)
  touch("finish")
  pcall(function()
    for name in pairs(scenarios) do
      wait(function() return exists("closed-" .. name) end, 20, "Terminals did not close: " .. name)
    end
  end)
  if shell then shell:terminate() end
  local file = assert(io.open(root .. "/result.txt", "wb"))
  file:write(ok and "ok" or tostring(err))
  file:close()
  core.exit(function() core.quit_request = true end, true)
end

core.add_background_thread(function()
  local deadline = system.get_time() + 30
  while not core.root_project() and system.get_time() < deadline do coroutine.yield(0.1) end
  local project = core.root_project()
  if not project then return end
  local path = project.path:gsub("\\", "/")
  local name = path:match("[^/]+$")
  local ok, err = pcall(function()
    -- The driver runs with --direct. Every other process is hosted by the shell.
    if system.is_hosted_surface() then hosted(name, path) else driver() end
  end)
  if not ok then
    core.error("Showcase failed in %s: %s", name, err)
    local file = io.open(root .. "/error-" .. name .. ".txt", "wb")
    if file then file:write(tostring(err)); file:close() end
  end
end)
