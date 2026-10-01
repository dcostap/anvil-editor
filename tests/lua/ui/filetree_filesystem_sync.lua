local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local test = require "core.test"
local filetree = require "plugins.filetree"

local function write_file(path)
  local handle = assert(io.open(path, "wb"))
  handle:write("test\n")
  handle:close()
end

test.describe("File Tree filesystem updates", function()
  local root, tree, previous_active

  test.before_each(function()
    previous_active = core.active_view
    root = USERDIR .. PATHSEP .. "filetree-sync-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(root))
    for i = 1, 80 do write_file(root .. PATHSEP .. string.format("file-%03d.txt", i)) end
    tree = assert(filetree.new(root))
    panes.create { factory = function() return tree end }
    core.active_view = tree
    tree.size.x, tree.size.y = 600, 200
    tree.buffer:set_selection(2, 1)
    tree:update()
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.active_view = previous_active
    test.ok(common.rm(root, true))
  end)

  test.it("keeps manual scroll and the selected path when an external file appears", function()
    local selected_path = tree:get_context_path()
    local scroll_y = tree:get_line_height() * 30
    tree.scroll.x, tree.scroll.to.x = 0, 0
    tree.scroll.y, tree.scroll.to.y = scroll_y, scroll_y
    write_file(root .. PATHSEP .. "aaa-new.txt")

    tree:handle_filesystem_watch_change(root)
    tree:update()

    test.equal(tree:get_context_path(), selected_path)
    test.equal(tree.scroll.to.y, scroll_y, "An external update must not reveal the caret")
    test.equal(tree.scroll.y, scroll_y)
    test.ok(table.concat(tree.buffer.lines):find("aaa-new.txt", 1, true))
  end)
end)
