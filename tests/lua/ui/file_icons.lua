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
      { "analysis.r", "r" },
      { "kernel.cu", "cu" },
      { "game.gd", "godot" },
      { "build.gradle", "gradle" },
      { "page.jinja2", "jinja" },
      { "tool.nim", "nim" },
      { "schema.prisma", "prisma" },
      { "module.res", "rescript" },
      { "contract.sol", "ethereum" },
      { "view.twig", "twig" },
      { "types.vala", "vala" },
      { "webpack.config.js", "webpack" },
      { "Cargo.toml", "rust" },
      { "go.mod", "go" },
      { "Gemfile", "ruby" },
      { "Dockerfile.dev", "docker" },
      { ".env.local", "config" },
      { "model.stl", "svg" },
      { "server.pem", "lock" },
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

  test.it("keeps the File Tree status gutter narrower than three text cells", function()
    local filetree = require "plugins.filetree"
    local gutter_width = filetree:get_gutter_width()

    test.ok(gutter_width < filetree:get_font():get_width("000"))
  end)

  test.it("renders Path Tree file icons inline after indentation", function()
    local Doc = require "core.doc"
    local file_icons = require "core.file_icons"
    local path_tree = require "plugins.path_tree"

    local tree = path_tree.build({ { path = "src/example.py" } })
    local view = path_tree.View(Doc(nil, nil, true))
    view:set_path_tree(tree)

    local line = tree:line_for_record(1)
    local text = view.doc.lines[line]:gsub("\n$", "")
    local name_col = assert(text:find("example.py", 1, true))
    local name_x = view:get_col_x_offset(line, name_col)
    local end_x = view:get_col_x_offset(line, #text + 1)
    local icon_width = file_icons.column_width(view:get_line_height())
    test.equal(
      end_x - name_x,
      icon_width + view:get_font():get_width("example.py", { tab_offset = name_x })
    )

    local drawn
    local old_draw = file_icons.draw
    local old_draw_text = renderer.draw_text
    file_icons.draw = function(path, x, y, row_height)
      drawn = { path = path, x = x, y = y, row_height = row_height }
      return true, icon_width
    end
    renderer.draw_text = function(font, rendered_text, x, _, _, opts)
      return x + font:get_width(rendered_text, opts)
    end
    local ok, err = pcall(function()
      view:draw_line_text(line, 100, 20)
    end)
    file_icons.draw = old_draw
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.not_nil(drawn)
    test.equal(drawn.path, "example.py")
    test.equal(drawn.x, 100 + name_x)
    test.equal(drawn.y, 20)
    test.equal(drawn.row_height, view:get_line_height())
  end)

  test.it("includes inline icons in File Tree filename geometry", function()
    local file_icons = require "core.file_icons"
    local filetree = require "plugins.filetree"
    local file_entry
    for _, entry in ipairs(filetree:build_entries(false)) do
      if entry.type == "file" then
        file_entry = entry
        break
      end
    end
    file_entry = test.not_nil(file_entry, "expected the test Project to contain a file")

    local line = file_entry.line
    local text = filetree.doc.lines[line]:gsub("\n$", "")
    local parsed = test.not_nil(filetree:parse_line(line))
    local name_x = filetree:get_col_x_offset(line, parsed.name_col)
    local end_x = filetree:get_col_x_offset(line, #text + 1)
    test.equal(
      end_x - name_x,
      file_icons.column_width(filetree:get_line_height())
        + filetree:get_font():get_width(text:sub(parsed.name_col), { tab_offset = name_x })
    )
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
