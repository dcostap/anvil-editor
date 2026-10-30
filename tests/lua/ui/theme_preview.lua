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
    local saved_background = {table.unpack(style.background)}
    bar:set_text("light")
    bar:update_suggestions()
    local first_preview = {table.unpack(style.background)}
    test.not_equal(table.concat(first_preview, ","), table.concat(saved_background, ","))
    bar:move_suggestion_idx(1)
    test.not_equal(table.concat(style.background, ","), table.concat(first_preview, ","))
    test.equal("dark", settings.config.theme)
    bar:exit(false)
    test.same(saved_background, style.background)
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
      local hovered_background = {table.unpack(style.background)}
      bar:exit(false)
      test.equal(#sent, 3)
      test.equal(sent[#sent], "")
      -- The Sidebar draws a preview with the same colours as the previewing Project.
      color_theme.load_preview(sent[2])
      test.same(hovered_background, style.background)
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

  test.it("supplies the shell's card colours from the current theme", function()
    local colors = color_theme.shell_colors(style)
    test.same(style.button, colors.card_button)
    test.same(style.button_primary_text, colors.accent_text)
    test.ok(color_theme.same_shell_colors(style, colors))
    colors.card_button[1] = colors.card_button[1] + 1
    test.ok(not color_theme.same_shell_colors(style, colors))
  end)
end)
