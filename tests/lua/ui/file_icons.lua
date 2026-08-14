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

  test.it("keeps the caret after a Path Tree file icon when moving left onto the filename", function()
    local command = require "core.command"
    local core = require "core"
    local Buffer = require "core.buffer"
    local file_icons = require "core.file_icons"
    local path_tree = require "plugins.path_tree"

    local tree = path_tree.build({ { path = "src/example.py" } })
    local view = path_tree.View(Buffer(nil, nil, true))
    view:set_path_tree(tree)

    local line = tree:line_for_record(1)
    local text = view.buffer.lines[line]:gsub("\n$", "")
    local name_col = assert(text:find("example.py", 1, true))
    view.buffer:set_selection(line, name_col + 1)
    core.active_view = view

    test.equal(command.perform("text:move-to-previous-char"), true)
    local caret_line, caret_col = view.buffer:get_selection()
    test.equal(caret_line, line)
    test.equal(caret_col, name_col)
    test.equal(
      view:get_col_x_offset(line, caret_col),
      view:get_font():get_width(text:sub(1, name_col - 1))
        + file_icons.column_width(view:get_line_height())
    )
  end)

end)
