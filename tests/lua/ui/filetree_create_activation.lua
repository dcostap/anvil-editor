local core = require "core"
local command = require "core.command"
local common = require "core.common"
local panes = require "core.panes"
local filetree = require "plugins.filetree"
local test = require "core.test"

test.describe("File Tree typed file activation", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.root = USERDIR .. PATHSEP .. "filetree-create-activation-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root .. PATHSEP .. "agent"))
    context.tree = assert(filetree.new(context.root))
    context.pane = panes.create { factory = function() return context.tree end }
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    if core.nag_view.visible then command.perform("core:select_dialog_no") end
    panes.reset_for_tests()
    test.ok(test.remove_tree(context.root))
  end)

  test.it("creates a typed filename whose prefix matches an existing folder", function(context)
    local tree = context.tree
    tree:with_selection_state(function()
      local line = #tree.buffer.lines
      tree.buffer:set_selection(line, #tree.buffer.lines[line])
    end)
    test.ok(command.perform("core:newline"))
    for character in ("AGENTS.md"):gmatch(".") do
      tree:on_text_input(character)
      -- Read the edit feedback that a frame displays between typed characters.
      tree:get_line_status(tree.buffer:get_selection())
    end

    test.ok(command.perform("core:activate_point_of_interest"))

    local path = context.root .. PATHSEP .. "AGENTS.md"
    test.not_nil(system.get_file_info(path), "activation must create the typed file")
    test.is_nil(core.fuzzy_searcher_active_view, "a filename must not open Symbol Search")
    test.ok(common.path_equals(context.pane.current_view.buffer.abs_filename, path))
    test.equal(system.get_file_info(context.root .. PATHSEP .. "agent").type, "dir")
  end)
end)
