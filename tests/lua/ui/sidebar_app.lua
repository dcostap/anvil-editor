local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local test = require "core.test"

local function copy(value)
  local result = {}
  for key, item in pairs(value) do result[key] = item end
  return result
end

local function restore(target, saved)
  for key in pairs(target) do target[key] = nil end
  for key, value in pairs(saved) do target[key] = value end
end

-- Seam: real Sidebar startup and keyboard events. Only the native Window and shell are replaced.
local function with_sidebar(custom, run)
  local saved = {core = copy(core), system = copy(system), renwindow = copy(renwindow),
    style = copy(style), commands = copy(command.map), keymap = copy(keymap), userdir = USERDIR, scale = SCALE,
    font_group = renderer.font.group}
  local folder = USERDIR .. "/sidebar-app-" .. tostring(system.get_time()):gsub("%.", "-")
  local focus, requests = {}, {}
  local ok, err = xpcall(function()
    test.ok(common.mkdirp(folder))
    USERDIR = folder
    local file = assert(io.open(folder .. "/user_settings.lua", "w"))
    file:write("return ", common.serialize({config = {custom_keybindings = custom}}, {escape = true}))
    file:close()
    system.get_anvil_window_id = function() return 7 end
    system.activate_sidebar_surface = function() return true end
    system.sidebar_surfaces = function() return {{id = 7}} end
    system.is_surface_transparent = function() return false end
    system.set_shell_colors = function() return true end
    system.publish_project_sidebar = function() return true end
    system.focus_project_sidebar = function(value) focus[#focus + 1] = value; return true end
    system.pane_request = function(route, path, text)
      requests[#requests + 1] = {route = route, path = path, request = assert(loadstring("return " .. text))()}
      return true
    end
    system.poll_event = function() end
    system.wait_event = function() end
    system.window_should_render = function() return false end
    renwindow.create = function() return saved.core.window end
    -- Headless UI fonts can be Lua wrappers. No drawing is needed for these input checks.
    renderer.font.group = function(fonts) return fonts[1] end
    core.request_project_sidebar = function() return false end
    dofile(DATADIR .. "/core/sidebar_app.lua")
    core.init()
    core.project_sidebar = {
      {id = 1, row_id = 1, path = "C:/Alpha", state = "ready", panes = {active = 1,
        {id = "a", name = "main.lua"}, {id = "b", name = "notes.md"}}},
      windows = {{id = 7, selected_project = 1}}, revision = 1,
    }
    core.run_step()
    core.on_event("focusgained")
    core.on_event("keypressed", "down")
    run(focus, requests)
  end, debug.traceback)
  if core.session_log and core.session_log ~= saved.core.session_log then core.session_log:close() end
  restore(core, saved.core)
  restore(system, saved.system)
  restore(renwindow, saved.renwindow)
  restore(style, saved.style)
  restore(command.map, saved.commands)
  restore(keymap, saved.keymap)
  renderer.font.group = saved.font_group
  USERDIR, SCALE = saved.userdir, saved.scale
  test.ok(test.remove_tree(folder))
  assert(ok, err)
end

test.describe("Sidebar application keyboard routing", function()
  for _, source in ipairs {"default", "custom"} do
    test.it("keeps Sidebar focus for close and reopen keys from " .. source .. " bindings", function()
      local bindings = {
        ["pane:close"] = {"ctrl+alt+f10"},
        ["pane:close_others"] = {"ctrl+alt+f11"},
        ["core:reopen_last_closed_pane"] = {"ctrl+alt+f12"},
      }
      local saved_map, saved_reverse = keymap.map, keymap.reverse_map
      keymap.map, keymap.reverse_map = {}, {}
      if source == "default" then
        for name, strokes in pairs(bindings) do keymap.add {[strokes[1]] = name} end
      end
      local ok, err = pcall(with_sidebar, source == "custom" and bindings or nil, function(focus, requests)
        for index, key in ipairs {"f10", "f11", "f12"} do
          core.on_event("keypressed", key, {modifiers = 0, ctrl = true, alt = true})
          test.same(focus, {}, "Closing or reopening from the Sidebar must not give away the keyboard")
          test.same(requests[index], {route = "select", path = "C:/Alpha", request = {
            action = "key", pane = "b", stroke = "ctrl+alt+" .. key, keep_sidebar = true,
          }})
        end
      end)
      keymap.map, keymap.reverse_map = saved_map, saved_reverse
      assert(ok, err)
    end)
  end
end)
