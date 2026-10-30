local test = require "core.test"
local core = require "core"
local command = require "core.command"
local settings = require "plugins.settings"
local style = require "core.style"
local color_theme = require "core.color_theme"
local renwindow = require "renwindow"

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
    local saved_background = {table.unpack(style.background)}
    bar:set_text("light")
    bar:update_suggestions()
    local first_preview = {table.unpack(style.background)}
    test.not_equal(table.concat(first_preview, ","), table.concat(saved_background, ","))

    local root = core.root_panel
    local old_x, old_y, old_w, old_h = root.position.x, root.position.y, root.size.x, root.size.y
    local window = renwindow.create("theme-preview-overlay", 32, 32)
    root.position.x, root.position.y, root.size.x, root.size.y = 0, 0, 32, 32
    local ok, err = pcall(function()
      renderer.begin_frame(window)
      renderer.set_clip_rect(0, 0, 32, 32)
      renderer.draw_rect(0, 0, 32, 32, { 100, 140, 180, 255 })
      local drawn, draw_error = pcall(root.draw_active_app_overlay, root)
      renderer.end_frame()
      test.ok(drawn, draw_error)
      test.same(renwindow.get_color(window, 16, 16), { 100, 140, 180, 255 },
        "theme preview dimmed the rendered editor surface")
    end)
    root.position.x, root.position.y, root.size.x, root.size.y = old_x, old_y, old_w, old_h
    renwindow.close(window)
    test.ok(ok, err)

    bar:move_suggestion_idx(1)
    test.not_equal(table.concat(style.background, ","), table.concat(first_preview, ","))
    test.equal("dark", settings.config.theme)
    bar:exit(false)
    test.same(saved_background, style.background)
    test.equal("dark", settings.config.theme)
  end)

  test.it("shows the hovered theme in the Sidebar and the saved one after cancel", function()
    local sent, latest_preview, preview_color_theme = {}, nil, system.preview_color_theme
    system.preview_color_theme = function(text)
      sent[#sent + 1] = text
      if text ~= "" then latest_preview = text end
      return true
    end
    local ok, err = pcall(function()
      test.ok(command.perform("core:select_theme"))
      local bar = core.global_prompt_bar
      bar:set_text("light")
      bar:update_suggestions()
      bar:move_suggestion_idx(1)
      local hovered_background = {table.unpack(style.background)}
      bar:exit(false)
      test.equal(sent[#sent], "")
      -- The Sidebar draws a preview with the same colours as the previewing Project.
      test.not_nil(latest_preview, "the hovered theme was not sent to the Sidebar")
      color_theme.load_preview(latest_preview)
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
