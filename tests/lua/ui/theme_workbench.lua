local test = require "core.test"
local style = require "core.style"
local themes = require "core.theme_edits"

test.describe("theme color edits", function()
  test.it("changes a named color across linked rules and keeps direct colors separate", function()
    local palette_color = {10, 20, 30, 255}
    local colors = {
      theme_palette = { accent = palette_color },
      accent = palette_color,
      syntax = style.apply_syntax_fallbacks({ keyword = palette_color, string = {10, 20, 30, 255} }),
    }
    local base = themes.capture(colors)
    local edits = {palette = {accent = {40, 50, 60, 255}}, rules = {}}

    themes.apply(colors, base, edits)
    test.same({40, 50, 60, 255}, colors.accent)
    test.same({40, 50, 60, 255}, colors.syntax.keyword)
    test.same({10, 20, 30, 255}, colors.syntax.string)
  end)

  test.it("keeps a disabled child value but uses its syntax parent", function()
    local colors = {
      theme_palette = {},
      syntax = style.apply_syntax_fallbacks({["function"] = {30, 40, 50, 255}, ["function.call"] = {90, 80, 70, 255}}),
    }
    local base = themes.capture(colors)
    local edits = {palette = {}, rules = {
      ["syntax.function.call"] = {enabled = false, color = {90, 80, 70, 255}},
    }}

    themes.apply(colors, base, edits)
    test.same({30, 40, 50, 255}, colors.syntax["function.call"])
    test.same({90, 80, 70, 255}, edits.rules["syntax.function.call"].color)
  end)

  test.it("switches one rule from a named color to a direct color", function()
    local palette_color = {10, 20, 30, 255}
    local colors = {theme_palette = {accent = palette_color}, syntax = style.apply_syntax_fallbacks({keyword = palette_color})}
    local base = themes.capture(colors)
    themes.apply(colors, base, {palette = {}, rules = {
      ["syntax.keyword"] = {enabled = true, color = {1, 2, 3, 255}},
    }})
    test.same({1, 2, 3, 255}, colors.syntax.keyword)
    test.same({10, 20, 30, 255}, colors.theme_palette.accent)
  end)

  test.it("saves edits when the user has no colors directory yet", function()
    local root = USERDIR .. "/fresh-theme-home"
    system.mkdir(root)
    local previous = USERDIR
    USERDIR = root
    local path, err = themes.save("dark2", {palette = {}, rules = {}}, false)
    USERDIR = previous
    test.not_nil(path, err)
    test.not_nil(system.get_file_info(path))
    os.remove(path)
    os.remove(root .. "/colors/edits")
    os.remove(root .. "/colors")
    os.remove(root)
  end)
end)
