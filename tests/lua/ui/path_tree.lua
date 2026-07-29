local Doc = require "core.doc"
local style = require "core.style"
local test = require "core.test"
local path_tree = require "plugins.path_tree"

local function record(path, kind, additions, deletions)
  return {
    path = path,
    kind = kind,
    stat = additions and { additions = additions, deletions = deletions or 0 } or nil,
  }
end

test.describe("Path Tree", function()
  test.it("uses the global prose typography role", function()
    local view = path_tree.View(Doc(nil, nil, true))
    test.equal(view:get_font(), style.prose_font)

    local original = style.prose_font
    local replacement = original:copy(original:get_size())
    style.prose_font = replacement
    local ok, err = pcall(function()
      test.equal(view:get_font(), replacement)
    end)
    style.prose_font = original
    if not ok then error(err, 0) end
  end)

  test.it("compacts consecutive single-child directories when requested", function()
    local tree = path_tree.build({
      record("src/main/java/App.java", "modified"),
      record("README.md", "modified"),
    }, { compact_directories = true })

    test.same(tree:lines(), {
      "src/main/java/",
      "\tApp.java",
      "README.md",
    })

    local compact = tree:row(1)
    test.equal(compact.type, "dir")
    test.equal(compact.depth, 0)
    test.equal(compact.path, "src/main/java")
    test.same(compact.compact_paths, { "src", "src/main", "src/main/java" })
    test.equal(tree:row(2).depth, 1)
    test.equal(tree:line_for_path("src", "dir"), 1)
    test.equal(tree:line_for_path("src/main", "dir"), 1)
    test.equal(tree:line_for_path("src/main/java", "dir"), 1)

    test.ok(tree:toggle(compact.path))
    test.same(tree:lines(), {
      "src/main/java/",
      "README.md",
    })
    test.equal(tree:visible_line_for_record(1), 1)

    test.ok(tree:toggle(compact.path))
    test.equal(tree:line_for_record(1), 2)
  end)

  test.it("builds one deterministic hierarchy from paths in arbitrary order", function()
    local tree = path_tree.build({
      record("src/main/App.kt", "modified", 2, 1),
      record("README.md", "deleted", 0, 4),
      record("src/test/AppTest.kt", "added", 8, 0),
      record("src/main/Util.kt", "added", 3, 0),
    })

    test.same(tree:lines(), {
      "src/",
      "\tmain/",
      "\t\tApp.kt",
      "\t\tUtil.kt",
      "\ttest/",
      "\t\tAppTest.kt",
      "README.md",
    })
    test.equal(tree:line_for_record(1), 3)
    test.equal(tree:line_for_record(4), 4)
    test.equal(tree:record_for_line(1), nil)
    test.equal(tree:record_for_line(3).path, "src/main/App.kt")

    local src = tree:row(1)
    test.equal(src.type, "dir")
    test.equal(src.kind, "added")
    test.same(src.stat, { additions = 13, deletions = 1 })
  end)

  test.it("presents whole and embedded trees with the same DocView behavior", function()
    local tree = path_tree.build({
      record("src/app.lua", "modified", 5, 2),
    })
    local whole = path_tree.View(Doc(nil, nil, true))
    whole:set_path_tree(tree)

    local embedded_doc = Doc(nil, nil, true)
    embedded_doc.lines = { "Changed files\n", "src/\n", "\tapp.lua\n" }
    local embedded = path_tree.View(embedded_doc)
    embedded:set_path_tree(tree, 1)

    test.equal(whole:path_tree_row(1).path, "src")
    test.equal(embedded:path_tree_row(2).path, "src")
    test.equal(whole:path_tree_row(2).path, "src/app.lua")
    test.equal(embedded:path_tree_row(3).path, "src/app.lua")
    test.equal(whole:get_gutter_width(), embedded:get_gutter_width())

    local whole_hint = whole:get_line_hint(2)
    local embedded_hint = embedded:get_line_hint(3)
    test.equal(whole_hint[1].text, "+5")
    test.equal(whole_hint[2].text, " −2")
    test.equal(whole_hint[1].font, style.get_small_font(style.code_font))
    test.equal(whole_hint[2].font, style.get_small_font(style.code_font))
    test.equal(embedded_hint[1].text, whole_hint[1].text)
    test.equal(embedded_hint[2].text, whole_hint[2].text)
  end)

  test.it("collapses and restores a folder without losing record identity", function()
    local tree = path_tree.build({
      record("src/main/App.kt", "modified"),
      record("src/main/Util.kt", "added"),
      record("README.md", "modified"),
    })
    local view = path_tree.View(Doc(nil, nil, true))
    view:set_path_tree(tree)

    test.ok(view:toggle_path_tree_folder(2))
    test.same(tree:lines(), { "src/", "\tmain/", "README.md" })
    test.equal(tree:line_for_record(1), nil)
    test.equal(tree:line_for_record(2), nil)
    test.equal(tree:visible_line_for_record(1), 2)
    test.equal(tree:visible_line_for_record(2), 2)
    test.equal(tree:line_for_record(3), 3)
    test.equal(view.doc.lines[3], "README.md\n")

    test.ok(view:toggle_path_tree_folder(2))
    test.equal(tree:line_for_record(1), 3)
    test.equal(tree:line_for_record(2), 4)
    test.equal(view.doc.lines[3], "\t\tApp.kt\n")
  end)

  test.it("keeps a changed file distinct from a directory with the same path", function()
    local tree = path_tree.build({
      record("generated", "deleted"),
      record("generated/output.txt", "added"),
    })

    test.same(tree:lines(), {
      "generated/",
      "\toutput.txt",
      "generated",
    })
    test.equal(tree:line_for_record(1), 3)
    test.equal(tree:line_for_record(2), 2)
    test.equal(tree:record_for_line(1), nil)
  end)

  test.it("invalidates document layout caches when visible rows are rebuilt", function()
    local nested_name = string.rep("i", 260) .. ".txt"
    local root_name = string.rep("W", 260) .. ".txt"
    local tree = path_tree.build({
      record("src/main/" .. nested_name, "modified"),
      record(root_name, "modified"),
    })
    local view = path_tree.View(Doc(nil, nil, true))
    view:set_path_tree(tree)

    local before = view:get_col_x_offset(3, 100)
    test.ok(view:toggle_path_tree_folder(2))
    local after = view:get_col_x_offset(3, 100)

    local expected_tree = path_tree.build({
      record("src/main/" .. nested_name, "modified"),
      record(root_name, "modified"),
    }, { collapsed = { ["src/main"] = true } })
    local expected_view = path_tree.View(Doc(nil, nil, true))
    expected_view:set_path_tree(expected_tree)
    local expected = expected_view:get_col_x_offset(3, 100)

    test.not_equal(before, expected)
    test.equal(after, expected)
  end)

  test.it("invalidates composed visual rows when collapse changes tree topology", function()
    local tree = path_tree.build({
      record("src/main/App.kt", "modified"),
      record("README.md", "modified"),
    })
    local view = path_tree.View(Doc(nil, nil, true))
    view:set_path_tree(tree)
    view:add_visual_row_provider("readme-marker", {
      visual_rows = function(_, candidate, line, placement)
        if placement == "before" and (candidate.doc.lines[line] or ""):find("README", 1, true) then
          return { { id = "readme" } }
        end
      end,
    })

    test.equal(view:get_scrollable_line_count(), 5)
    test.ok(view:toggle_path_tree_folder(2))
    test.equal(view:get_scrollable_line_count(), 4)
  end)

  test.it("keeps the toggled folder visible after collapsing a tall subtree", function()
    local records = {}
    for index = 1, 80 do
      records[index] = record(string.format("src/file-%03d.lua", index), "modified")
    end
    local tree = path_tree.build(records)
    local view = path_tree.View(Doc(nil, nil, true))
    view:set_path_tree(tree)
    view.size.x, view.size.y = 300, 80
    view.scroll.y, view.scroll.to.y = 10000, 10000

    test.ok(view:toggle_path_tree_folder(1))
    test.equal(view.doc:get_selection(), 1)
    test.ok(view.scroll.y < 10000)
    test.equal(view.scroll.y, view.scroll.to.y)
  end)
end)
