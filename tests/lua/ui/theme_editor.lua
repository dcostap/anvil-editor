local test = require "core.test"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local RootPanel = require "core.rootpanel"
local style = require "core.style"
local theme_editor = require "plugins.theme_editor"

test.describe("theme editor", function()
  test.after_each(function()
    theme_editor.close()
  end)

  test.it("shows the Wallpaper rather than the Editor through its background", function()
    local old_root, old_wallpaper, old_clip = core.root_panel, config.wallpaper, core.clip_rect_stack[1]
    config.wallpaper = "image1"
    local root = RootPanel()
    root.size.x, root.size.y = 1200, 750
    core.root_panel = root
    local editor = theme_editor.open("dark3")
    editor:update()
    local window = renwindow.create("theme-editor-wallpaper", 1200, 750)
    local x, y = math.floor(editor.position.x + 4), math.floor(editor.position.y + 4)
    local function pixel(image, behind)
      root.wallpaper = canvas.new(8, 8, image)
      root.wallpaper_name = "image1"
      renderer.begin_frame(window)
      core.clip_rect_stack[1] = { 0, 0, 1200, 750 }
      renderer.set_clip_rect(0, 0, 1200, 750)
      root:draw_wallpaper(true)
      renderer.draw_rect(editor.position.x, editor.position.y,
        editor.size.x, editor.size.y, behind)
      editor:draw()
      renderer.end_frame()
      return renwindow.get_color(window, x, y)
    end
    local ok, err = pcall(function()
      local image = { 200, 60, 40, 255 }
      local first = pixel(image, { 0, 0, 0, 255 })
      test.same(first, pixel(image, { 255, 255, 255, 255 }),
        "the Theme Editor must not show Editor content")
      test.not_equal(first[1], pixel({ 20, 60, 200, 255 }, { 0, 0, 0, 255 })[1],
        "the Theme Editor must still show the Wallpaper")
    end)
    theme_editor.close()
    core.root_panel, config.wallpaper, core.clip_rect_stack[1] = old_root, old_wallpaper, old_clip
    if not ok then error(err, 0) end
  end)

  test.it("previews named color edits and drops them on reload", function()
    local editor = theme_editor.open("dark3")
    local original = {table.unpack(style.theme_palette.text_bg)}
    editor:set_palette("text_bg", {8, 9, 10, 255})
    test.same({8, 9, 10, 255}, style.background)
    editor:reload()
    test.same(original, style.background)
  end)

  test.it("keeps a disabled child rule while using the parent color", function()
    local editor = theme_editor.open("dark3")
    local original = {table.unpack(style.syntax["function.call"])}
    editor:set_rule("syntax.function.call", {enabled = false, color = {11, 12, 13, 255}})
    test.same(style.syntax["function"], style.syntax["function.call"])
    test.same({11, 12, 13, 255}, editor.draft.rules["syntax.function.call"].color)
    editor:reload()
    test.same(original, style.syntax["function.call"])
  end)

  test.it("saves a theme for a later reload", function()
    local path = USERDIR .. "/colors/edits/dark3.lua"
    local editor = theme_editor.open("dark3")
    editor:set_palette("text_bg", {18, 19, 20, 255})
    editor:save(false)
    editor:reload()
    test.same({18, 19, 20, 255}, style.background)
    test.not_nil(system.get_file_info(path))
    os.remove(path)
  end)

  test.it("registers a command for selecting a theme to edit", function()
    test.ok(command.is_valid("theme_editor:edit_theme"))
  end)

  test.it("loads as a compatible bundled plugin", function()
    local details = core.get_plugin_details(DATADIR .. "/plugins/theme_editor.lua")
    test.not_nil(details)
    test.ok(details.version_match)
  end)

  test.it("drops a new unsaved syntax rule on reload", function()
    local editor = theme_editor.open("dark3")
    editor:set_rule("syntax.anvil_temporary.child", {enabled = true, color = {11, 12, 13, 255}})
    test.same({11, 12, 13, 255}, style.syntax["anvil_temporary.child"])
    editor:reload()
    test.equal(nil, rawget(style.syntax, "anvil_temporary.child"))
  end)

  test.it("keeps a disabled child override after saving and reopening", function()
    local path = USERDIR .. "/colors/edits/dark3.lua"
    local editor = theme_editor.open("dark3")
    editor:set_rule("syntax.function.call", {enabled = false, color = {4, 5, 6, 255}})
    editor:save(false)
    theme_editor.close()
    editor = theme_editor.open("dark3")
    test.same({4, 5, 6, 255}, editor.draft.rules["syntax.function.call"].color)
    test.same(style.syntax["function"], style.syntax["function.call"])
    os.remove(path)
  end)
end)
