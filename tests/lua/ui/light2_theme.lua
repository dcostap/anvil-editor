local test = require "core.test"
local core = require "core"
local style = require "core.style"
local theme_editor = require "plugins.theme_editor"

local function font_path(font)
  local path = font:get_path()
  return type(path) == "table" and path[1] or path
end

test.describe("Light2 color theme", function()
  local previous

  test.before_each(function()
    previous = require("plugins.settings").config.theme or "dark"
  end)

  test.after_each(function()
    theme_editor.close()
    core.reload_module("colors." .. (previous == "dark" and "default" or previous))
  end)

  test.it("uses warm paper and oxblood for its main colors", function()
    core.reload_module("colors.light2")
    test.same({245, 234, 215, 255}, style.background)
    test.same({26, 24, 20, 255}, style.text)
    test.same({107, 29, 29, 255}, style.accent)
    test.same({235, 222, 197, 255}, style.background2)
    test.same(style.accent, style.search_selection_outline)
    test.equal(style.accent[1], style.selection[1])
    test.ok(style.selection[4] < 255)
  end)

  test.it("does not change global fonts when switching themes", function()
    local code_font = style.code_font
    local base_view_text = style.view_text_font
    local base_prose = style.markdown_body_font
    local base_heading = style.prose_heading_font
    local base_big = style.big_font
    core.reload_module("colors.light2")
    test.equal(base_view_text, style.view_text_font)
    test.equal(base_prose, style.markdown_body_font)
    test.equal(base_heading, style.prose_heading_font)
    test.equal(base_big, style.big_font)
    test.equal(code_font, style.code_font)
    core.reload_module("colors.light")
    test.equal(base_view_text, style.view_text_font)
    test.equal(base_prose, style.markdown_body_font)
    test.equal(base_heading, style.prose_heading_font)
    test.equal(base_big, style.big_font)
    test.same({255, 255, 255, 255}, style.background)
  end)

  test.it("lets the theme editor preview and discard paper changes", function()
    local editor = theme_editor.open("light2")
    editor:set_palette("text_bg", {240, 225, 200, 255})
    test.same({240, 225, 200, 255}, style.background)
    editor:reload()
    test.same({245, 234, 215, 255}, style.background)
  end)
end)
