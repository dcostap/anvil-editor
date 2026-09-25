local test = require "core.test"
local core = require "core"
local command = require "core.command"
local settings = require "plugins.settings"
local style = require "core.style"

test.describe("cycle to next color theme", function()
  local original_theme

  test.before_each(function()
    original_theme = settings.config.theme or "dark"
  end)

  test.after_each(function()
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    settings.apply_color_theme(original_theme)
  end)

  test.it("applies the next installed theme immediately", function()
    local themes = settings.get_installed_colors()
    test.ok(#themes >= 2, "expected two installed themes")

    settings.apply_color_theme(themes[2].name)
    local expected_background = { table.unpack(style.background) }
    settings.apply_color_theme(themes[1].name)

    test.ok(command.perform("core:cycle_to_next_theme"))

    test.equal(settings.config.theme, themes[2].name)
    test.same(expected_background, style.background)
  end)

  test.it("wraps from the last theme to the first and saves the choice", function()
    local themes = settings.get_installed_colors()
    test.ok(#themes >= 2, "expected two installed themes")
    settings.apply_color_theme(themes[#themes].name)

    test.ok(command.perform("core:cycle_to_next_theme"))

    test.equal(settings.config.theme, themes[1].name)
    test.equal(dofile(USERDIR .. "/user_settings.lua").config.theme, themes[1].name)
  end)

  test.it("repeats a theme command selected from the Command Palette", function()
    local themes = settings.get_installed_colors()
    test.ok(#themes >= 2, "expected two installed themes")
    settings.apply_color_theme(themes[1].name)

    test.ok(command.perform("fuzzy:open_commands"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.results = {{ kind = "command", command = "core:cycle_to_next_theme" }}
    picker.selected = 1
    picker.open_transition_complete = true
    test.ok(command.perform("fuzzy:confirm"))
    test.equal(settings.config.theme, themes[2].name)

    test.ok(command.perform("core:repeat_last_command"))
    test.equal(settings.config.theme, themes[3] and themes[3].name or themes[1].name)
  end)

  test.it("keeps the theme command when repeat is selected from the Command Palette", function()
    local themes = settings.get_installed_colors()
    test.ok(#themes >= 2, "expected two installed themes")
    settings.apply_color_theme(themes[1].name)
    test.ok(command.perform("core:cycle_to_next_theme"))

    test.ok(command.perform("fuzzy:open_commands"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker.results = {{ kind = "command", command = "core:repeat_last_command" }}
    picker.selected = 1
    picker.open_transition_complete = true
    test.ok(command.perform("fuzzy:confirm"))

    test.equal(settings.config.theme, themes[3] and themes[3].name or themes[1].name)
  end)
end)
