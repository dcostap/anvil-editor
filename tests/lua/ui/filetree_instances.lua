local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local View = require "core.view"
local test = require "core.test"
local filetree = require "plugins.filetree"

local function write_file(path, text)
  local handle = assert(io.open(path, "wb"))
  handle:write(text or "")
  handle:close()
end

test.describe("File Tree instances", function()
  local root
  local folder
  local file
  local set_active_view

  test.before_each(function()
    panes.reset_for_tests()
    set_active_view = core.set_active_view
    core.set_active_view = function(view) core.active_view = view end
    root = USERDIR .. PATHSEP .. "filetree-instances-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    folder = root .. PATHSEP .. "folder"
    file = folder .. PATHSEP .. "target.lua"
    test.ok(common.mkdirp(folder))
    write_file(file, "return true\n")
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.set_active_view = set_active_view
    if system.get_file_info(root) then
      local ok, err = common.rm(root, true)
      test.ok(ok, err)
    end
  end)

  test.it("requiring the plugin creates no File Tree", function()
    test.same(filetree.instances(), {})
    test.equal(panes.count(), 0)
  end)

  test.it("keeps roots and selections independent", function()
    local one = assert(filetree.new(root))
    local two = assert(filetree.new(file))
    test.equal(one.root_dir, common.normalize_path(root))
    test.equal(two.root_dir, common.normalize_path(folder))
    one.buffer:set_selection(1, 1)
    two.buffer:set_selection(math.min(2, #two.buffer.lines), 1)
    test.not_equal(one.buffer, two.buffer)
    test.not_equal(one.selection_state, two.selection_state)
  end)

  test.it("uses the Root Project when no target is given", function()
    local view = assert(filetree.new())
    test.equal(view.root_dir, common.normalize_path(core.root_project().path))
  end)

  test.it("uses source context for relative targets and dot", function()
    local source = View()
    source.current_dir = folder
    local relative = assert(filetree.new("target.lua", { source_view = source }))
    local dot = assert(filetree.new(".", { source_view = source }))
    test.equal(relative.root_dir, common.normalize_path(folder))
    test.equal(dot.root_dir, common.normalize_path(folder))
  end)

  test.it("resolves relative targets from Editor and Terminal contexts", function()
    local editor = View()
    editor.buffer = { abs_filename = file }
    local terminal = View()
    function terminal:get_cwd() return folder end
    local from_editor = assert(filetree.new("target.lua", { source_view = editor }))
    local from_terminal = assert(filetree.new("target.lua", { source_view = terminal }))
    test.equal(from_editor.root_dir, common.normalize_path(folder))
    test.equal(from_terminal.root_dir, common.normalize_path(folder))
  end)

  test.it("clamps Up Directory at the instance root", function()
    local view = assert(filetree.new(folder))
    view:up_dir()
    test.equal(view.current_dir, common.normalize_path(folder))
  end)

  test.it("suspends and restores the same instance with Back", function()
    local tree = assert(filetree.new(root))
    local pane = panes.create { factory = function() return tree end }
    local replacement = View()
    panes.present(replacement, { pane = pane })
    test.equal(panes.back(pane), tree)
    test.equal(pane.current_view, tree)
    test.equal(tree.root_dir, common.normalize_path(root))
  end)

  test.it("restores Workspace state and drops a missing root", function()
    local tree = assert(filetree.new(root))
    local state = tree:get_state()
    local restored = filetree.from_state(state)
    test.not_nil(restored)
    test.equal(restored.root_dir, tree.root_dir)
    common.rm(root, true)
    test.is_nil(filetree.from_state(state))
  end)
end)
