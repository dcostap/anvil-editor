local test = require "core.test"
local core = require "core"
local command = require "core.command"
local settings = require "plugins.settings"
local style = require "core.style"

test.describe("theme selection preview", function()
  local previous
  test.before_each(function()
    previous = settings.config.theme or "dark"
    core.global_prompt_bar:exit(true)
    settings.apply_color_theme("dark")
  end)
  test.after_each(function()
    core.global_prompt_bar:exit(false)
    settings.apply_color_theme(previous)
  end)

  test.it("previews the selected theme without dimming the editor and restores it on cancel", function()
    test.ok(command.perform("core:select_theme"))
    local bar = core.global_prompt_bar
    test.not_equal(core.root_panel.app_overlay and core.root_panel.app_overlay.owner, bar)
    bar:set_text("light")
    bar:update_suggestions()
    test.same({255, 255, 255, 255}, style.background)
    bar:move_suggestion_idx(1)
    test.same({245, 234, 215, 255}, style.background)
    test.equal("dark", settings.config.theme)
    bar:exit(false)
    test.same({28, 30, 38, 255}, style.background)
    test.equal("dark", settings.config.theme)
  end)

  test.it("saves only the submitted theme", function()
    test.ok(command.perform("core:select_theme"))
    local bar = core.global_prompt_bar
    bar:set_text("light2")
    bar:submit()
    test.equal("light2", settings.config.theme)
    test.same({245, 234, 215, 255}, style.background)
  end)
end)
