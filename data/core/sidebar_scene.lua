-- Private renderer check for the Project Sidebar: a fixed model with every row kind.
local style = require "core.style"
local View = require "core.view"
local SidebarView = require "core.sidebar_view"

local Scene = View:extend()
function Scene:get_name() return "Project Sidebar" end

local MINUTE, DAY = 60, 24 * 60 * 60
local POWERSHELL = [[C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__package\pwsh.exe]]

local function terminal(id, title, age, fields)
  local item = {id = id, title = title, cwd = "C:/Projects/anvil-editor", state = "running", busy = 0,
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

-- mode is nil, "search" or "drag". The second Project is collapsed, so it shows only its agent's question.
function Scene:new(mode)
  Scene.super.new(self)
  self.sidebar = SidebarView(function() end,
    {["project:D:/Work/Israel Mallo Mart\u{00ED}nez - ManualSistemas"] = true}, {})
  self.sidebar:set_model({
    project(1, "C:/Projects/anvil-editor", "ready", MINUTE, 1, {
      terminal("a", "[40 s] \u{03C0} - GLP4", 30, {busy = 1, agent_app = "pi", agent_model = "GPT Test", agent_state = "working", agent_since = os.time() - 400,
        agent_step = "bash: npm test -- --watch=false", agent_step_since = os.time() - 42}),
      terminal("b", POWERSHELL, 20 * MINUTE),
      terminal("deepseek", "DeepSeek", 30, {agent_app = "pi", agent_model = "DeepSeek-V3", agent_state = "idle",
        agent_since = os.time() - MINUTE}),
      terminal("build", [[.\gradlew.bat runAppiDesktop --console=rich --info]], 30,
        {command_started=os.time() - 180, command_finished=os.time() - 30, command_exit=0}),
      terminal("c", "npm run dev", 3 * DAY),
      terminal("d", "", 2 * DAY, {state = "exited"}),
      terminal("e", "build log", 10 * DAY),
      terminal("f", "\u{03C0} - review", 40 * DAY, {agent_app = "pi", agent_model = "Claude Test", agent_state = "done",
        agent_since = os.time() - 5 * MINUTE}),
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
        agent_app = "pi", agent_model = "Claude Test", agent_kind = "permission", agent_message = "Allow write to src/main.c?", agent_since = os.time() - 90}),
    }, {active = 1, visible = 1, terminal_tab(1, 1, "h", "\u{03C0} - Israel Mallo Mart\u{00ED}nez", 5 * MINUTE)}),
    project(7, "C:/Projects/api-server", "starting", 3 * MINUTE, 1),
    project(3, "C:/Projects/notes", "dormant", 2 * DAY, 0, {
      terminal("i", "pi", 3 * 60 * 60, {busy = 1}),
      terminal("j", "pwsh", 5 * 60 * 60),
    }),
    project(4, "C:/Projects/website", "dormant", 12 * DAY),
    project(5, "C:/Projects/scratch", "dormant", 20 * DAY),
    project(6, "C:/Projects/old-tool", "dormant", 60 * DAY),
    windows = {{id = 1, selected_project = 1}, {id = 2, selected_project = 2}},
  }, 1)
  if mode == "search" then
    self.sidebar:on_focus(true)
    self.sidebar:on_text_input("shell")
  end
  self.drag = mode == "drag"
end

local function tab_y(sidebar, id, part)
  for index, row in ipairs(sidebar.rows) do
    if row.kind == "tab" and row.tab.id == id then return sidebar:row_y(index) + row.h * part end
  end
end

-- Holds removed.md over the line between the first group's two Tabs, with all motion finished.
function Scene:start_drag(width, height)
  local sidebar = self.sidebar
  sidebar:set_size(width, height)
  local x, start = 110 * SCALE, tab_y(sidebar, "pane-5", 0.5)
  sidebar:on_mouse_pressed("left", x, start)
  sidebar:on_mouse_moved(x, start - 10 * SCALE)
  sidebar:on_mouse_moved(x + 24 * SCALE, tab_y(sidebar, "pane-1", 0.85))
  for _ = 1, 90 do sidebar:step(1 / 30) end
end

function Scene:draw()
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, style.background)
  local width, height = math.floor(280 * SCALE), math.floor(self.position.y + self.size.y)
  if self.drag then
    self.drag = false
    self:start_drag(width, height)
  end
  self.sidebar:draw(width, height)
end

return Scene
