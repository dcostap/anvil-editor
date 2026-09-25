local test = require "core.test"
local command = require "core.command"
local settings = require "plugins.settings"
local style = require "core.style"

test.describe("cycle to next color theme", function()
  local original_theme

  test.before_each(function()
    original_theme = settings.config.theme or "dark"
  end)

  test.after_each(function()
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
end)
