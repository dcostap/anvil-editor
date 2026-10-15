-- Private renderer check for the Project Sidebar: a fixed model with every row kind.
local style = require "core.style"
local View = require "core.view"
local SidebarView = require "core.sidebar_view"

local Scene = View:extend()
function Scene:get_name() return "Project Sidebar" end

local MINUTE, DAY = 60, 24 * 60 * 60

local function terminal(id, title, age, fields)
  local item = {id = id, title = title, cwd = "C:/Projects/anvil-editor", state = "running", busy = 0, bell = 0,
    attached = true, activity = os.time() - age}
  for key, value in pairs(fields or {}) do item[key] = value end
  return item
end

local function project(row_id, path, state, age, window_id, terminals)
  return {row_id = row_id, id = row_id, path = path, state = state, exists = true, window_id = window_id or 0,
    activity = os.time() - age, terminals = terminals or {}}
end

function Scene:new()
  Scene.super.new(self)
  self.sidebar = SidebarView(function() end, {})
  self.sidebar:set_model({
    project(1, "C:/Projects/anvil-editor", "ready", MINUTE, 1, {
      terminal("a", "[40 s] \u{03C0} - GLP4", 30, {busy = 1}),
      terminal("b", "pwsh - anvil-editor", 20 * MINUTE),
      terminal("c", "npm run dev", 3 * DAY),
      terminal("d", "", 2 * DAY, {state = "exited"}),
      terminal("e", "build log", 10 * DAY),
      terminal("f", "ssh server", 40 * DAY, {bell = 1}),
      terminal("g", "old shell", 45 * DAY),
    }),
    project(2, "D:/Work/Israel Mallo Mart\u{00ED}nez - ManualSistemas", "ready", 2 * 60 * 60, 2, {
      terminal("h", "\u{03C0} - Israel Mallo Mart\u{00ED}nez", 5 * MINUTE),
    }),
    project(3, "C:/Projects/notes", "dormant", 2 * DAY),
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
