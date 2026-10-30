local core = require "core"
local command = require "core.command"
local config = require "core.config"
local panes = require "core.panes"
local test = require "core.test"
local dialog = require "core.ui.dialog"

if PLATFORM ~= "Windows" then return end

local file_types = require "plugins.file_types"

local OPEN_COMMAND = '"' .. EXEFILE .. '" "%1"'

local function values(key)
  return system.get_registry_values(file_types.root .. "\\" .. key)
end

local function open_dialog()
  test.ok(command.perform("file_types:manage"))
  local open = test.not_nil(dialog.current())
  dialog.update()
  return open
end

local function find_row(open, name)
  for index, row in ipairs(open.list.rows) do
    if row.name == name then return row, index end
  end
  test.fail("no row " .. name)
end

local function click_at(x, y)
  core.on_event("mousepressed", "left", x, y, 1)
  core.on_event("mousereleased", "left", x, y)
end

local function click_row(open, name)
  local _, index = find_row(open, name)
  local list = open.list
  click_at(list.x + list.w / 2, list.y + (index - 0.5) * list.row_height)
end

local function click(control)
  click_at(control.x + control.w / 2, control.y + control.h / 2)
end

test.describe("File Types Dialog", function()
  local saved

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      size = { core.root_panel.size.x, core.root_panel.size.y },
      root = file_types.root,
      types = config.plugins.file_types.types,
      open_in_system = system.open_in_system,
    }
    core.root_panel.size.x, core.root_panel.size.y = 1000, 700
    -- A private key, so the test never changes the user's file types.
    file_types.root = "Software\\AnvilTests-file-types-" .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    config.plugins.file_types.types = {
      { name = "Markdown", extensions = { "md", "markdown" } },
      { name = "Lua", extensions = { "lua" } },
    }
  end)

  test.after_each(function()
    local open = dialog.current()
    if open then open:close() end
    for _ = 1, 3 do dialog.update() end
    test.ok(system.delete_registry_key(file_types.root))
    file_types.root = saved.root
    config.plugins.file_types.types = saved.types
    system.open_in_system = saved.open_in_system
    core.root_panel.size.x, core.root_panel.size.y = saved.size[1], saved.size[2]
    panes.reset_for_tests()
  end)

  test.it("checking a type makes this anvil.exe open its extensions", function()
    local open = open_dialog()
    test.equal(find_row(open, "Markdown").checked, false)

    click_row(open, "Markdown")

    test.ok(find_row(open, "Markdown").checked)
    for _, extension in ipairs({ "md", "markdown" }) do
      test.equal(values("Classes\\Anvil." .. extension .. "\\shell\\open\\command")[""], OPEN_COMMAND)
      test.not_nil(values("Classes\\." .. extension .. "\\OpenWithProgids")["Anvil." .. extension])
    end
    test.equal(values("RegisteredApplications").Anvil, file_types.root .. "\\Anvil\\Capabilities")
    test.equal(find_row(open, "Lua").checked, false)
    test.equal(values("Classes\\Anvil.lua"), nil)
  end)

  test.it("clearing the last type removes Anvil from Windows Settings", function()
    local open = open_dialog()
    click_row(open, "Lua")
    test.ok(find_row(open, "Lua").checked)

    test.ok(command.perform("dialog:confirm"))

    test.equal(find_row(open, "Lua").checked, false)
    test.equal(values("Classes\\Anvil.lua"), nil)
    test.equal(values("Classes\\.lua\\OpenWithProgids")["Anvil.lua"], nil)
    test.equal(values("RegisteredApplications").Anvil, nil)
    test.equal(values("Anvil"), nil)
  end)

  test.it("shows types that another anvil.exe opens, and takes them over when checked", function()
    local other = '"C:\\Other\\anvil.exe" "%1"'
    for _, extension in ipairs({ "lua", "foo" }) do
      local key = file_types.root .. "\\Classes\\Anvil." .. extension .. "\\shell\\open\\command"
      test.ok(system.set_registry_value(key, "", other))
      test.ok(system.set_registry_value(file_types.root .. "\\Anvil\\Capabilities\\FileAssociations",
        "." .. extension, "Anvil." .. extension))
    end
    local open = open_dialog()
    local lua = find_row(open, "Lua")
    test.equal(lua.checked, false)
    test.ok(lua.other)
    test.ok(find_row(open, ".foo").other, "an extension outside the list keeps a row")

    click_row(open, "Lua")

    test.ok(find_row(open, "Lua").checked)
    test.equal(values("Classes\\Anvil.lua\\shell\\open\\command")[""], OPEN_COMMAND)
  end)

  test.it("Set as Default opens Anvil's page in Windows Settings", function()
    local opened
    system.open_in_system = function(resource) opened = resource return true end
    local open = open_dialog()
    test.equal(open.default_button.enabled, false)
    click_row(open, "Markdown")
    dialog.update()

    click(open.default_button)

    test.equal(opened, "ms-settings:defaultapps?registeredAppUser=Anvil")
    test.equal(dialog.current(), nil)
  end)
end)
