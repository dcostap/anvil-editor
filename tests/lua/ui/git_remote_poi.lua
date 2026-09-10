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

  for _, activation in ipairs {
    "POI activation", "double-click", "commit activation", "commit activation after loading files",
  } do
  test.it("continues through Git Log files after " .. activation, function(context)
    local source = context.source
    source.tab_id = "log"
    local log = source.model:log_tab()
    log.commits = {{ hash = "after", parents = { "before" }, subject = "Change",
      changed_files = context.tab.changed_files, changed_files_loaded = true }}
    log.selected_commit = 1
    source.model.backend.diff_endpoint_for_commit = function()
      return { left = "before", right = "after" }
    end
    source.model.backend.changed_files = function(_, _, _, _, callback)
      callback(context.tab.changed_files)
    end
    source:update_pane_buffers(true)
    local tree = source:pane_view("details")
    for line = 1, #tree.buffer.lines do
      local row = tree:path_tree_row(line)
      if row and row.type == "dir" then tree:toggle_path_tree_folder(line); break end
    end
    test.ok(poi.navigate(tree, 1))
    test.equal(panes.active().current_view, source)
    if activation:find("commit activation", 1, true) then
      test.ok(poi.navigate(tree, 1))
      local complete_listing
      if activation == "commit activation after loading files" then
        log.commits[1].changed_files, log.commits[1].changed_files_loaded = nil, nil
        source.model.backend.changed_files = function(_, _, _, _, callback)
          complete_listing = callback
        end
      end
      core.active_view = source:pane_view("log-list")
      core.active_view.buffer:set_selection(1, 1)
      test.ok(require("core.command").perform("core:activate_point_of_interest"))
      if activation == "commit activation after loading files" then
        test.not_nil(complete_listing)
        complete_listing(context.tab.changed_files)
      end
    elseif activation == "double-click" then
      tree.position.x, tree.position.y = 0, 0
      tree.size.x, tree.size.y = 600, 400
      tree.scroll.x, tree.scroll.y = 0, 0
      tree.scroll.to.x, tree.scroll.to.y = 0, 0
      local x, y = tree:get_line_screen_position(tree.buffer:get_selection())
      x, y = x + 8, y + tree:get_line_height() / 2
      test.ok(source:on_mouse_pressed("left", x, y, 2))
      test.ok(source:on_mouse_released("left", x, y))
    else
      test.ok(poi.activate(tree))
    end
    test.equal(poi.get_remote_source(), tree)
    local destination = panes.active()
    test.contains(table.concat(destination.current_view.buffer_view_b.buffer.lines), "after src/a.lua")
    test.ok(poi.navigate_remote(1))
    test.contains(table.concat(destination.current_view.buffer_view_b.buffer.lines), "after src/b.lua")
    test.equal(tree:path_tree_record_for_line(tree.buffer:get_selection()).new_path, "src/b.lua")
    test.ok(poi.navigate_remote(-1))
    test.contains(table.concat(destination.current_view.buffer_view_b.buffer.lines), "after src/a.lua")
    test.equal(source:can_discard_from_history(), false)
    source:on_close()
    test.equal(poi.get_remote_source(), nil)
  end)
  end

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
