local core = require "core"
local command = require "core.command"
local config = require "core.config"
local launcher = require "core.project_launcher"
local panes = require "core.panes"
local simple_menu = require "core.simple_menu"
local TitleBar = require "core.titlebar"
local View = require "core.view"
local context_menu = require "core.context_menu"
local test = require "core.test"

-- Seams: the Simple Mode toggle command, the Project Launcher's buttons, the Title Bar's pointer handlers and the
-- Context Menu.

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

  test.it("saves the toggle and hides the Terminal buttons", function()
    config.simple_mode = false
    test.ok(launcher_labels():find("Terminal", 1, true))

    command.perform("core:toggle_simple_mode")
    test.equal(config.simple_mode, true)
    test.equal(read_user_settings().simple_mode, true)
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
    test.before_each(function(context)
      context.saved = {controls = system.get_window_controls, content_x = system.get_window_content_x,
        hit_test = system.set_window_hit_test}
      -- The shell's Window controls at the right end of the Title Bar.
      system.get_window_controls = function() return 760, 0, 140, 32 end
      context.hit = nil
      system.set_window_hit_test = function(_, ...) context.hit = {...} end
      panes.create { factory = function() return View() end }
    end)

    test.after_each(function(context)
      context_menu.close()
      system.get_window_controls = context.saved.controls
      system.get_window_content_x = context.saved.content_x
      system.set_window_hit_test = context.saved.hit_test
      config.simple_mode = false
    end)

    local function title_bar(content_x)
      system.get_window_content_x = function() return content_x end
      local title = TitleBar()
      title.size.x = 900
      title:update()
      return title
    end

    test.it("follows the Project name, while the Sidebar shows and while it is hidden", function(context)
      config.simple_mode = false
      test.equal(#title_bar(0).menu_rects, 0)
      config.simple_mode = true
      for _, content_x in ipairs {240, 0} do
        local title = title_bar(content_x)
        local rects = title.menu_rects
        test.equal(#rects, #simple_menu.MENUS)
        local toggle, name, last = title.sidebar_toggle_rect, title.project_rect, rects[#rects]
        test.equal(name.x, toggle.x + toggle.w)
        test.ok(rects[1].x > name.x + name.w, "No gap keeps the Menu Bar apart from the Project name")
        -- The labels take the pointer, so a press on them does not drag the Window. The name still drags it.
        local client_x, client_w = context.hit[4], context.hit[5]
        test.ok(client_x <= rects[1].x and client_x + client_w >= last.x + last.w,
          "The Menu Bar is not in the Title Bar's client area")
        test.ok(client_x >= name.x + name.w, "The Project name does not drag the Window")
      end
      -- Without the Sidebar, Tabs follow the Menu Bar after a gap.
      local title = title_bar(0)
      local entry = test.not_nil(title:get_pane_entries()[1])
      local last = title.menu_rects[#title.menu_rects]
      test.ok(entry.x > last.x + last.w, "No gap keeps the Tabs apart from the Menu Bar")
    end)

    test.it("opens a menu below its label, changes menus under the pointer and runs items here", function()
      config.simple_mode = true
      local title = title_bar(0)
      local file, edit = title.menu_rects[1], title.menu_rects[2]
      test.ok(title:on_mouse_pressed("left", file.x + 2, file.y + 2, 1))
      test.ok(context_menu.is_open())
      test.equal(context_menu.labels()[1], "New File")
      -- No Editor is active, so Save cannot run: it shows, but choosing it does nothing.
      test.ok(context_menu.choose("Save"))
      test.ok(context_menu.is_open(), "Choosing a dim item closed the menu")

      core.on_event("mousemoved", edit.x + 2, edit.y + 2, 0, 0)
      test.equal(context_menu.labels()[1], "Undo")

      core.on_event("mousemoved", title.menu_rects[5].x + 2, edit.y + 2, 0, 0)
      test.ok(context_menu.choose("Exit Simple Mode"))
      test.not_ok(context_menu.is_open())
      test.equal(config.simple_mode, false)
    end)
  end)
end)
