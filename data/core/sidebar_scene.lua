-- Private renderer check for the Project Sidebar: a fixed model with every row kind.
local style = require "core.style"
local View = require "core.view"
local SidebarView = require "core.sidebar_view"

local Scene = View:extend()
function Scene:get_name() return "Project Sidebar" end

local MINUTE, DAY = 60, 24 * 60 * 60
local POWERSHELL = [[C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__package\pwsh.exe]]

local function terminal(id, title, age, fields)
  local item = {id = id, title = title, cwd = "C:/Projects/anvil-editor", state = "running", busy = 0, bell = 0,
    attached = true, activity = os.time() - age}
  for key, value in pairs(fields or {}) do item[key] = value end
  return item
end

local function project(row_id, path, state, age, window_id, terminals, panes)
  return {row_id = row_id, id = row_id, path = path, state = state, exists = true, window_id = window_id or 0,
    activity = os.time() - age, terminals = terminals or {}, panes = panes or {}}
end

local function editor(number, group, name, fields)
  local item = {id = "pane-" .. number, number = number, group = group, name = name,
    icon = {kind = "file", path = name}}
  for key, value in pairs(fields or {}) do item[key] = value end
  return item
end

local function terminal_tab(number, group, session, title, age, busy)
  return {id = "pane-" .. number, number = number, group = group, name = title,
    terminal = {session = session, state = "running", busy = busy, activity = os.time() - age}}
end

function Scene:new()
  Scene.super.new(self)
  self.sidebar = SidebarView(function() end, {})
  self.sidebar:set_model({
    project(1, "C:/Projects/anvil-editor", "ready", MINUTE, 1, {
      terminal("a", "[40 s] \u{03C0} - GLP4", 30, {busy = 1, agent_app = "pi", agent_state = "working", agent_since = os.time() - 400,
        agent_step = "bash: npm test -- --watch=false", agent_step_since = os.time() - 42}),
      terminal("b", POWERSHELL, 20 * MINUTE),
      terminal("build", [[.\gradlew.bat runAppiDesktop --console=rich --info]], 30,
        {command_started=os.time() - 180, command_finished=os.time() - 30, command_exit=0}),
      terminal("c", "npm run dev", 3 * DAY),
      terminal("d", "", 2 * DAY, {state = "exited"}),
      terminal("e", "build log", 10 * DAY),
      terminal("f", "ssh server", 40 * DAY, {bell = 1}),
      terminal("g", "old shell", 45 * DAY),
    }, {active = 2, visible = 1,
      editor(1, 1, "init.lua"),
      editor(2, 1, "sidebar_view.lua", {color = {0xe2, 0xc0, 0x8d, 255}}),
      terminal_tab(3, 2, "a", "[40 s] \u{03C0} - GLP4", 30, true),
      terminal_tab(4, 3, "b", POWERSHELL, 20 * MINUTE, false),
      editor(5, 4, "removed.md", {missing = true}),
    }),
    project(2, "D:/Work/Israel Mallo Mart\u{00ED}nez - ManualSistemas", "ready", 2 * 60 * 60, 2, {
      terminal("h", "\u{03C0} - Israel Mallo Mart\u{00ED}nez", 5 * MINUTE, {agent_state = "blocked",
        agent_app = "pi", agent_kind = "permission", agent_message = "Allow write to src/main.c?", agent_since = os.time() - 90}),
    }, {active = 1, visible = 1, terminal_tab(1, 1, "h", "\u{03C0} - Israel Mallo Mart\u{00ED}nez", 5 * MINUTE)}),
    project(3, "C:/Projects/notes", "dormant", 2 * DAY, 0, {
      terminal("i", "pi", 3 * 60 * 60, {busy = 1}),
      terminal("j", "pwsh", 5 * 60 * 60),
    }),
    project(4, "C:/Projects/website", "dormant", 12 * DAY),
    project(5, "C:/Projects/scratch", "dormant", 20 * DAY),
    project(6, "C:/Projects/old-tool", "dormant", 60 * DAY),
    windows = {{id = 1, selected_project = 1}, {id = 2, selected_project = 2}},
  }, 1)
end

function Scene:draw()
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, style.background)
  self.sidebar:draw(math.floor(280 * SCALE), math.floor(self.position.y + self.size.y))
end

return Scene
