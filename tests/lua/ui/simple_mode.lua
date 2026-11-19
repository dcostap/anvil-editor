local core = require "core"
local command = require "core.command"
local config = require "core.config"
local launcher = require "core.project_launcher"
local pane_report = require "core.pane_report"
local panes = require "core.panes"
local simple_menu = require "core.simple_menu"
local SidebarView = require "core.sidebar_view"
local test = require "core.test"

-- Seams: the Simple Mode toggle command, the Project's Pane report, the Project Launcher's buttons, and the Sidebar
-- View's pointer handlers and emitted actions.

local function each_item(items, fn)
  for _, entry in ipairs(items) do
    if entry ~= "-" then
      if entry.items then each_item(entry.items, fn) else fn(entry) end
    end
  end
end

local function find(items, label)
  for _, entry in ipairs(items) do
    if entry ~= "-" and entry.label == label then return entry end
  end
  error("no menu item " .. label)
end

local function launcher_labels()
  local labels = {}
  for _, item in ipairs(launcher.items()) do labels[#labels + 1] = item.label end
  return table.concat(labels, "|")
end

local function read_user_settings()
  local ok, saved = pcall(dofile, USERDIR .. PATHSEP .. "user_settings.lua")
  return ok and type(saved) == "table" and saved.config or {}
end

test.describe("Simple Mode", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.simple_mode = config.simple_mode
  end)

  test.after_each(function(context)
    if config.simple_mode ~= context.simple_mode then command.perform("core:toggle_simple_mode") end
    panes.reset_for_tests()
  end)

  test.it("names a real command in each Menu Bar item", function()
    for _, menu in ipairs(simple_menu.MENUS) do
      each_item(menu.items, function(item)
        test.ok(command.map[item.command], menu.label .. " > " .. item.label .. ": no command " .. item.command)
      end)
    end
  end)

  test.it("saves the toggle, reports the menu commands and hides the Terminal buttons", function()
    config.simple_mode = false
    test.not_ok(pane_report.build().menu, "The Pane report has a menu outside Simple Mode")
    test.ok(launcher_labels():find("Terminal", 1, true))

    command.perform("core:toggle_simple_mode")
    test.equal(config.simple_mode, true)
    test.equal(read_user_settings().simple_mode, true)
    local menu = test.not_nil(pane_report.build().menu)
    -- The toggle that turns Simple Mode off is on, and a command that cannot run now is absent.
    test.equal(menu["core:toggle_simple_mode"].on, true)
    test.not_ok(menu["markdown:surround_bold"], "Bold can run without a Markdown Editor")
    local labels = launcher_labels()
    test.not_ok(labels:find("Terminal", 1, true) or labels:find("Pi", 1, true), labels)
    test.ok(labels:find("New File", 1, true), labels)

    command.perform("core:toggle_simple_mode")
    test.equal(config.simple_mode, false)
    test.equal(read_user_settings().simple_mode, false)
    test.ok(launcher_labels():find("Terminal", 1, true))
  end)

  test.it("follows a change that another Project saved", function()
    config.simple_mode = false
    core.on_event("simplemodechanged", true)
    test.equal(config.simple_mode, true)
    core.on_event("simplemodechanged", false)
    test.equal(config.simple_mode, false)
  end)

  test.describe("Menu Bar", function()
    local function sidebar(report)
      local actions = {}
      local view = SidebarView(function(...) actions[#actions + 1] = {...} end, {})
      view:set_size(320, 600)
      view:set_model({{row_id=7,id=31,path="C:/Notes",state="ready",window_id=5,terminals={},panes=report},
        windows={{id=5,selected_project=31}}}, 5)
      return view, actions
    end

    test.it("shows only in Simple Mode", function()
      config.simple_mode = false
      local view = sidebar({})
      test.not_ok(view:menu_bar())
      config.simple_mode = true
      local bar = test.not_nil(view:menu_bar())
      test.equal(#bar, #simple_menu.MENUS)
      config.simple_mode = false
    end)

    test.it("opens a menu below its label, and its items run in the Selected Project", function()
      config.simple_mode = true
      local view, actions = sidebar({menu = {["editor:save"] = {key = "ctrl+s"}}})
      local bar = view:menu_bar()
      local label = bar[1]
      local x, y = label.x + label.w / 2, label.y + label.h / 2
      test.equal(view:menu_bar_at(x, y), 1)
      view:on_mouse_pressed("left", x, y, 1)
      local opened = test.not_nil(actions[#actions])
      test.same({opened[1], opened[3], opened[4]}, {"menu", label.x, label.y + label.h})
      test.equal(view.menu_bar_open, 1)

      local items = opened[2]
      local save = find(items, "Save")
      test.equal(save.shortcut, "ctrl+s")
      test.not_ok(save.disabled)
      -- The Project did not report it, so it cannot run there now.
      test.ok(find(items, "Save As…").disabled)

      local before = #actions
      command.perform(save.command, table.unpack(save.args))
      test.same({actions[before + 1], actions[before + 2]}, {{"return_focus"},
        {"request", "select", "C:/Notes", {action = "perform", command = "editor:save"}}})
      config.simple_mode = false
    end)

    test.it("shows each item as available before the Project's first report", function()
      config.simple_mode = true
      local view, actions = sidebar(nil)
      local label = view:menu_bar()[2]
      view:on_mouse_pressed("left", label.x + 1, label.y + 1, 1)
      local disabled = 0
      each_item(actions[#actions][2], function(item) if item.disabled then disabled = disabled + 1 end end)
      test.equal(disabled, 0)
      config.simple_mode = false
    end)
  end)
end)
