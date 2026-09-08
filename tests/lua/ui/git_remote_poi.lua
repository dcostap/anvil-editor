local core = require "core"
local panes = require "core.panes"
local poi = require "core.poi"
local View = require "core.view"
local GitView = require "plugins.git.view"
local test = require "core.test"

test.describe("Commit remote POIs", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.source = GitView(core.root_project(), {
      defer_refresh = true, tab_id = "test-commit",
      backend = {
        WORKING_TREE = "WORKING_TREE", EMPTY_TREE = "EMPTY_TREE",
        file_at = function(_, revision, path, _, callback)
          callback(revision .. " " .. path .. "\n", nil)
        end,
      },
    })
    local source = context.source
    source.model.repo = { root = core.root_project().path }
    context.tab = {
      id = "test-commit", kind = "commit_diff", title = "Commit", closable = true,
      left = "before", right = "after", selected_file = 1,
      changed_files = {
        { status = "modified", old_path = "src/a.lua", new_path = "src/a.lua" },
        { status = "modified", old_path = "src/b.lua", new_path = "src/b.lua" },
      },
    }
    source.model.tabs[#source.model.tabs + 1] = context.tab
    panes.create { factory = function() return source end }
    source:on_resume()
  end)

  test.after_each(function() panes.reset_for_tests() end)

  test.it("keeps the tree local and opens remote comparisons in the requesting Pane", function(context)
    local source = context.source
    local tree = source:pane_view("file-list")
    test.equal(poi.get_remote_source(), tree)
    test.equal(#source:get_surface_focus_targets(), 1)
    test.ok(poi.navigate(tree, 1))
    test.equal(panes.active().current_view, source)
    poi.set_remote_source(tree)
    local destination = panes.create { factory = function() return View() end }
    test.ok(poi.navigate_remote(1))
    local first = destination.current_view
    test.not_equal(first, source)
    test.contains(table.concat(first.buffer_view_b.buffer.lines), "after src/a.lua")
    test.ok(poi.navigate_remote(1))
    test.contains(table.concat(destination.current_view.buffer_view_b.buffer.lines), "after src/b.lua")
    test.equal(context.tab.selected_file, 2)
    test.equal(tree:path_tree_record_for_line(tree.buffer:get_selection()).new_path, "src/b.lua")
    test.ok(panes.close(panes.pane_for_view(source), { force = true }))
    test.contains(table.concat(first.buffer_view_b.buffer.lines), "after src/a.lua")
    test.equal(poi.get_remote_source(), nil)
  end)

  test.it("reveals a changed file inside a collapsed source folder", function(context)
    local tree = context.source:pane_view("file-list")
    tree:toggle_path_tree_folder(1)
    local destination = panes.create { factory = function() return View() end }
    test.ok(poi.navigate_remote(1))
    test.not_nil(destination.current_view.buffer_view_a)
    test.equal(tree:path_tree_record_for_line(tree.buffer:get_selection()).new_path, "src/a.lua")
  end)

  test.it("does not replace a View opened while comparison content loads", function(context)
    local pending = {}
    context.source.model.backend.file_at = function(_, revision, path, _, callback)
      pending[#pending + 1] = function() callback(revision .. " " .. path .. "\n") end
    end
    local destination = panes.create { factory = function() return View() end }
    test.ok(poi.navigate_remote(1))
    local other = View()
    panes.present(other, { pane = destination })
    for _, complete in ipairs(pending) do complete() end
    test.equal(destination.current_view, other)
  end)

  test.it("keeps historical image files until the standalone comparison closes", function(context)
    local file = assert(io.open(DATADIR .. "/plugins/editor_wallpaper/wallpaper.jpg", "rb"))
    local bytes = file:read("*a")
    file:close()
    context.tab.changed_files = {{ status = "modified", old_path = "a.jpg", new_path = "a.jpg", binary = true }}
    context.source.model.backend.file_at = function(_, _, _, _, callback) callback(bytes) end
    context.source:update_pane_buffers(true)
    local destination = panes.create { factory = function() return View() end }
    test.ok(poi.navigate_remote(1))
    local comparison = destination.current_view
    test.equal(tostring(comparison), "ImageComparisonView")
    local path = comparison.left_view.path
    test.not_nil(comparison.left_view.image)
    test.ok(panes.close(panes.pane_for_view(context.source), { force = true }))
    test.not_nil(system.get_file_info(path))
    test.ok(panes.close(destination, { force = true }))
    test.equal(system.get_file_info(path), nil)
  end)
end)
