local core = require "core"
local command = require "core.command"
local common = require "core.common"
local file_context = require "core.file_context"
local panes = require "core.panes"
local View = require "core.view"
local test = require "core.test"
local filetree = require "plugins.filetree"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

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

  test.it("selects an absolute file outside Project Paths", function()
    local view = assert(filetree.new(file))
    local line = view.buffer:get_selection(true)
    local entry = view:entry_for_line(line)
    test.ok(entry and common.path_equals(entry.abs, file))
  end)

  test.it("uses the Root Project when no target is given", function()
    local view = assert(filetree.new())
    test.equal(view.root_dir, common.normalize_path(core.root_project().path))
  end)

  test.it("updates after a display scale change", function()
    local view = assert(filetree.new(root))
    view.current_scale = SCALE / 2

    view:update()

    test.equal(view.current_scale, SCALE)
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

  test.it("records a new Navigation Place when an existing File Tree is shown again", function()
    local tree = assert(filetree.new(root))
    local pane = panes.create { factory = function() return tree end }
    local replacement = View()
    panes.present(replacement, { pane = pane })

    test.ok(command.perform("filetree:focus-file", file))

    test.equal(pane.current_view, tree)
    local selected = tree:entry_for_line(tree.buffer:get_selection(true))
    test.ok(selected and common.path_equals(selected.abs, file))
    test.equal(panes.history_length(pane), 3)
    test.equal(panes.back(pane), replacement)
    test.equal(panes.forward(pane), tree)
    selected = tree:entry_for_line(tree.buffer:get_selection(true))
    test.ok(selected and common.path_equals(selected.abs, file))
  end)

  test.it("restores Workspace expansion, selection, and instance setup", function()
    local tree = assert(filetree.new(root))
    local _, _, initial = tree:build_entries(false)
    local folder_entry
    for _, entry in pairs(initial.by_line) do
      if common.path_equals(entry.abs, folder) then folder_entry = entry; break end
    end
    test.not_nil(folder_entry)
    tree:expand_folder(folder_entry.line, folder_entry, false)
    local _, _, snapshot = tree:build_entries(false)
    local selected
    for _, entry in pairs(snapshot.by_line) do
      if common.path_equals(entry.abs, file) then selected = entry; break end
    end
    test.not_nil(selected)
    tree.buffer:set_selection(selected.line, 1)
    local state = tree:get_state()
    local restored = filetree.from_state(state)
    test.not_nil(restored)
    test.equal(restored.root_dir, tree.root_dir)
    local _, _, restored_snapshot = restored:build_entries(false)
    local restored_folder
    for _, entry in pairs(restored_snapshot.by_line) do
      if common.path_equals(entry.abs, folder) then restored_folder = entry; break end
    end
    test.ok(restored_folder and restored.line_meta[restored_folder.line].expanded)
    local restored_selected = restored:entry_for_line(restored.buffer:get_selection(true))
    test.ok(restored_selected and common.path_equals(restored_selected.abs, file))
    test.ok(restored.visible)
    test.not_ok(file_context.is_content_view(restored))
  end)

  test.it("drops Workspace state whose root is missing", function()
    local tree = assert(filetree.new(root))
    local state = tree:get_state()
    common.rm(root, true)
    test.is_nil(filetree.from_state(state))
  end)

  test.it("stops its filesystem watcher when closed", function()
    local tree = assert(filetree.new(root))
    test.ok(tree.filesystem_watch_running)
    tree:on_close()
    test.not_ok(tree.filesystem_watch_running)
    test.is_nil(tree.filesystem_watch)
  end)

  test.it("does not suspend a non-suspendable View to restore a File Tree", function()
    local tree = assert(filetree.new(root))
    local pane = panes.create { factory = function() return tree end }
    local blocker = View()
    function blocker:can_suspend() return false end
    function blocker:can_close() self.close_requested = true end
    panes.present(blocker, { pane = pane })

    test.ok(command.perform("filetree:focus"))
    test.equal(pane.current_view, blocker)
    test.ok(blocker.close_requested)
  end)

  test.it("provides File Tree Git state to fuzzy file results", function()
    local tree = assert(filetree.new(root))
    panes.create { factory = function() return tree end }
    function tree:get_git_info_for_entry(entry)
      if common.path_equals(entry.abs, file) then return { kind = "modified" } end
    end
    test.equal(fuzzy_searcher._test.git_kind_for_file(file), "modified")
  end)
end)
