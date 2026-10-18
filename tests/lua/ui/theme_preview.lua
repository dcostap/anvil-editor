local test = require "core.test"
local core = require "core"
local command = require "core.command"
local settings = require "plugins.settings"
local style = require "core.style"
local color_theme = require "core.color_theme"

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

  test.it("shows the hovered theme in the Sidebar and the saved one after cancel", function()
    local sent, preview_color_theme = {}, system.preview_color_theme
    system.preview_color_theme = function(text) sent[#sent + 1] = text; return true end
    local ok, err = pcall(function()
      test.ok(command.perform("core:select_theme"))
      local bar = core.global_prompt_bar
      bar:set_text("light")
      bar:update_suggestions()
      bar:move_suggestion_idx(1)
      bar:exit(false)
      test.equal(#sent, 3)
      test.equal(sent[#sent], "")
      -- The Sidebar draws a preview with the same colours as the previewing Project.
      color_theme.load_preview(sent[2])
      test.same({245, 234, 215, 255}, style.background)
    end)
    system.preview_color_theme = preview_color_theme
    core.reload_module(color_theme.module_name(settings.config.theme))
    if not ok then error(err, 0) end
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
