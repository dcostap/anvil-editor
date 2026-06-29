local test = require "core.test"
local command = require "core.command"
local style = require "core.style"
local theme_editor = require "plugins.theme_editor"

test.describe("runtime theme editor", function()
  local old_background

  test.before_each(function()
    old_background = style.background
  end)

  test.after_each(function()
    style.background = old_background
    theme_editor.hide()
  end)

  test.it("collects current theme colors for runtime editing and export", function()
    local entries = theme_editor.collect_color_entries()
    local background_entry
    local syntax_entry
    for _, entry in ipairs(entries) do
      if entry.expr == "style.background" then background_entry = entry end
      if entry.expr == "style.syntax.normal" or entry.expr == "style.syntax[\"normal\"]" then
        syntax_entry = entry
      end
    end

    test.not_nil(background_entry)
    test.not_nil(syntax_entry)

    local exported = theme_editor.export_theme_text(entries)
    test.ok(exported:find("style.background =", 1, true) ~= nil)
    test.ok(exported:find("return style", 1, true) ~= nil)
  end)

  test.it("groups style keys that share the same color table", function()
    local groups = theme_editor.collect_color_groups(theme_editor.collect_color_entries())
    local found
    for _, group in ipairs(groups) do
      local names = {}
      for _, entry in ipairs(group.entries) do names[entry.expr] = true end
      if names["style.git_change_addition"] and names["style.filetree_git_line_additions"] then
        found = group
        break
      end
    end

    test.not_nil(found)
    test.ok(#found.entries >= 2)
    test.equal("Git / File Tree", found.category)
  end)

  test.it("applies selected color immediately without saving a theme file", function()
    local view = theme_editor.show()
    local background_entry
    for _, entry in ipairs(theme_editor.collect_color_entries()) do
      if entry.expr == "style.background" then
        background_entry = entry
        break
      end
    end
    test.not_nil(background_entry)

    view:select_entry(background_entry)
    view:apply_color_to_selected({1, 2, 3, 4})

    test.same({1, 2, 3, 4}, style.background)
  end)

  test.it("exports only colors changed since the editor baseline", function()
    local view = theme_editor.show()
    local background_entry
    for _, entry in ipairs(theme_editor.collect_color_entries()) do
      if entry.expr == "style.background" then
        background_entry = entry
        break
      end
    end
    test.not_nil(background_entry)

    view:select_entry(background_entry)
    view:apply_color_to_selected({5, 6, 7, 8})

    local changed = view:changed_entries()
    local exported = theme_editor.export_theme_text(changed)

    test.equal(1, #changed)
    test.ok(exported:find("style.background = {5, 6, 7, 8}", 1, true) ~= nil)
    test.ok(exported:find("style.text =", 1, true) == nil)
  end)

  test.it("resizes from the bottom-right grip", function()
    local view = theme_editor.show()
    local start_w = view:get_width()
    local start_h = view:get_height()
    local x = view.position.x + start_w - 2
    local y = view.position.y + start_h - 2

    test.ok(view:on_mouse_pressed("left", x, y, 1))
    test.ok(view:on_mouse_moved(x + 80, y + 40, 80, 40))
    test.ok(view:get_width() >= start_w + 79)
    test.ok(view:get_height() >= start_h + 39)
    test.ok(view:on_mouse_released("left", x + 80, y + 40))
  end)

  test.it("tracks and resets runtime changes", function()
    local view = theme_editor.show()
    local background_entry
    for _, entry in ipairs(theme_editor.collect_color_entries()) do
      if entry.expr == "style.background" then
        background_entry = entry
        break
      end
    end
    test.not_nil(background_entry)

    view:select_entry(background_entry)
    view:apply_color_to_selected({9, 10, 11, 12})
    test.equal(1, #view:changed_entries())

    view:reset_all_changes()
    test.same(old_background, style.background)
    test.equal(0, #view:changed_entries())
  end)

  test.it("registers commands for showing and hiding the editor", function()
    test.ok(command.is_valid("theme-editor:show"))
    test.ok(command.is_valid("theme-editor:hide"))
    test.ok(command.is_valid("theme-editor:toggle"))
  end)
end)
