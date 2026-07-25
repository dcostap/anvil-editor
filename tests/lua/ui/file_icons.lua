local test = require "core.test"

test.describe("File-type icons", function()
  test.it("resolves common file types to Seti icons", function()
    local file_icons = require "core.file_icons"

    local cases = {
      { "main.c", "c" },
      { "main.cpp", "cpp" },
      { "plugin.lua", "lua" },
      { "tool.py", "python" },
      { "app.js", "javascript" },
      { "app.ts", "typescript" },
      { "workflow.json", "json" },
      { "notes.md", "markdown" },
      { "index.html", "html" },
      { "style.css", "css" },
      { "main.rs", "rust" },
      { "config.yml", "yml" },
      { "unknown.filetype", "default" },
    }

    for _, case in ipairs(cases) do
      test.equal(file_icons.resolve(case[1]), case[2], case[1])
    end
    test.is_nil(file_icons.resolve("folder", true))
  end)

  test.it("loads scalable Seti glyphs from the bundled font", function()
    local file_icons = require "core.file_icons"
    local font, glyph, color, name = file_icons.get("example.py", 16)

    test.not_nil(font)
    test.equal(name, "python")
    test.type(glyph, "string")
    test.ok(font:get_width(glyph) > 0)
    test.type(color, "table")
  end)

  test.it("renders Seti glyphs larger than their visual slot", function()
    local file_icons = require "core.file_icons"
    local drawn_font
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font)
      drawn_font = font
      return 0
    end

    local ok, err = pcall(function()
      file_icons.draw("example.py", 0, 0, 20, 16)
    end)
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.not_nil(drawn_font)
    test.ok(drawn_font:get_size() > 16, "expected the Seti font to compensate for its internal whitespace")
    test.ok(drawn_font:get_size() <= 22, "expected the glyph to remain within its row")
  end)

  test.it("keeps the File Tree icon gutter narrower than three text cells", function()
    local filetree = require "plugins.filetree"
    local gutter_width = filetree:get_gutter_width()

    test.ok(gutter_width < filetree:get_font():get_width("000"))
  end)

  test.it("reserves an icon column when rendering Fuzzy Searcher file rows", function()
    local file_icons = require "core.file_icons"
    local fuzzy_searcher = require "plugins.fuzzy_searcher"
    local style = require "core.style"
    local draw_file_result_row = fuzzy_searcher._test.draw_file_result_row
    local font = style.font
    local icon_path
    local text_x
    local old_icon_draw = file_icons.draw
    local old_draw_text = renderer.draw_text
    file_icons.draw = function(path)
      icon_path = path
      return true
    end
    renderer.draw_text = function(_, text, x)
      if text == "example.py" then text_x = x end
      return x + font:get_width(text)
    end

    local ok, err = pcall(function()
      draw_file_result_row(font, "example.py", {}, "", 10, 0, 200, nil, nil, nil, true)
    end)
    file_icons.draw = old_icon_draw
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(icon_path, "example.py")
    test.ok(text_x > 10, "expected the filename to start after the icon column")
  end)
end)
