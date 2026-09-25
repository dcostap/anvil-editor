local test = require "core.test"
local command = require "core.command"
local style = require "core.style"
local theme_editor = require "plugins.theme_editor"

test.describe("theme editor", function()
  test.after_each(function()
    theme_editor.close()
  end)

  test.it("previews named color edits and drops them on reload", function()
    local editor = theme_editor.open("dark2")
    local original = {table.unpack(style.theme_palette.text_bg)}
    editor:set_palette("text_bg", {8, 9, 10, 255})
    test.same({8, 9, 10, 255}, style.background)
    editor:reload()
    test.same(original, style.background)
  end)

  test.it("keeps a disabled child rule while using the parent color", function()
    local editor = theme_editor.open("dark2")
    local original = {table.unpack(style.syntax["function.call"])}
    editor:set_rule("syntax.function.call", {enabled = false, color = {11, 12, 13, 255}})
    test.same(style.syntax["function"], style.syntax["function.call"])
    test.same({11, 12, 13, 255}, editor.draft.rules["syntax.function.call"].color)
    editor:reload()
    test.same(original, style.syntax["function.call"])
  end)

  test.it("saves a theme for a later reload", function()
    local path = USERDIR .. "/colors/edits/dark2.lua"
    local editor = theme_editor.open("dark2")
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

  test.it("drops a new unsaved syntax rule on reload", function()
    local editor = theme_editor.open("dark2")
    editor:set_rule("syntax.anvil_temporary.child", {enabled = true, color = {11, 12, 13, 255}})
    test.same({11, 12, 13, 255}, style.syntax["anvil_temporary.child"])
    editor:reload()
    test.equal(nil, rawget(style.syntax, "anvil_temporary.child"))
  end)

  test.it("keeps a disabled child override after saving and reopening", function()
    local path = USERDIR .. "/colors/edits/dark2.lua"
    local editor = theme_editor.open("dark2")
    editor:set_rule("syntax.function.call", {enabled = false, color = {4, 5, 6, 255}})
    editor:save(false)
    theme_editor.close()
    editor = theme_editor.open("dark2")
    test.same({4, 5, 6, 255}, editor.draft.rules["syntax.function.call"].color)
    test.same(style.syntax["function"], style.syntax["function.call"])
    os.remove(path)
  end)
end)
