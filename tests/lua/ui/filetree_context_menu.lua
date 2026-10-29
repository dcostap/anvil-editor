local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local context_menu = require "core.context_menu"
local panes = require "core.panes"
local filetree = require "plugins.filetree"
local test = require "core.test"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text or "")
  file:close()
end

local function line_of(tree, name)
  for line, text in ipairs(tree.buffer.lines) do
    if text:gsub("\n$", ""):match("^%s*(.-)%s*$") == name then return line end
  end
end

local function right_click_row(tree, name)
  local line = assert(line_of(tree, name), name .. " is not shown")
  local x, y = tree:get_line_screen_position(line, 2)
  y = y + tree:get_line_height() / 2
  core.on_event("mousepressed", "right", x, y, 1)
  core.on_event("mousereleased", "right", x, y)
end

test.describe("File Tree Context Menu", function()
  local saved

  test.before_each(function(context)
    panes.reset_for_tests()
    saved = {
      trash = config.plugins.filetree.delete_to_trash,
      size = { core.root_panel.size.x, core.root_panel.size.y },
      open_in_system = common.open_in_system,
    }
    config.plugins.filetree.delete_to_trash = false
    core.root_panel.size.x, core.root_panel.size.y = 800, 600
    context.root = USERDIR .. PATHSEP .. "filetree-context-menu-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root .. PATHSEP .. "docs"))
    write_file(context.root .. PATHSEP .. "notes.txt", "notes")
    write_file(context.root .. PATHSEP .. "page.html", "<html></html>")
    write_file(context.root .. PATHSEP .. "data.bin", "\0data")
    context.tree = assert(filetree.new(context.root))
    context.pane = panes.create { factory = function() return context.tree end }
    panes.focus(context.pane)
    core.root_panel:update()
  end)

  test.after_each(function(context)
    context_menu.close()
    if core.nag_view.visible then command.perform("core:select_dialog_no") end
    config.plugins.filetree.delete_to_trash = saved.trash
    common.open_in_system = saved.open_in_system
    core.root_panel.size.x, core.root_panel.size.y = saved.size[1], saved.size[2]
    panes.reset_for_tests()
    test.ok(test.remove_tree(context.root))
  end)

  test.it("opens text, HTML and binary files with the OS default app from their menu", function(context)
    local opened
    common.open_in_system = function(path) opened = path; return true end
    for _, name in ipairs({ "notes.txt", "page.html", "data.bin" }) do
      opened = nil
      right_click_row(context.tree, name)
      test.ok(context_menu.choose("Open with OS Default App"))
      test.equal(opened, system.absolute_path(context.root .. PATHSEP .. name))
      test.equal(core.active_view, context.tree)
      test.ok(not core.nag_view.visible, "the OS action must not ask how to open binary files")
    end
  end)

  test.it("does not offer the default file app for a directory", function(context)
    right_click_row(context.tree, "docs/")
    for _, label in ipairs(context_menu.labels()) do
      test.ok(label ~= "Open with OS Default App")
    end
  end)

  test.it("deletes the right-clicked file after the confirmation", function(context)
    right_click_row(context.tree, "notes.txt")
    test.ok(context_menu.choose("Delete"))
    test.ok(core.nag_view.visible, "Delete must ask before it changes the disk")
    command.perform("core:select_dialog_yes")
    test.is_nil(system.get_file_info(context.root .. PATHSEP .. "notes.txt"))
    test.not_nil(system.get_file_info(context.root .. PATHSEP .. "docs"))
  end)

  test.it("keeps the file and its row when the deletion is cancelled", function(context)
    right_click_row(context.tree, "notes.txt")
    test.ok(context_menu.choose("Delete"))
    command.perform("core:select_dialog_no")
    test.not_nil(system.get_file_info(context.root .. PATHSEP .. "notes.txt"))
    test.not_nil(line_of(context.tree, "notes.txt"), "a cancelled Delete must show the row again")
    test.ok(not context.tree.has_possible_edits)
  end)

  test.it("renames the right-clicked file to the name typed in the prompt", function(context)
    right_click_row(context.tree, "notes.txt")
    test.ok(context_menu.choose("Rename…"))
    test.equal(core.global_prompt_bar:get_text(), "notes.txt")
    core.global_prompt_bar:set_text("ideas.txt")
    command.perform("core:submit_prompt")
    test.ok(core.nag_view.visible)
    command.perform("core:select_dialog_yes")
    test.is_nil(system.get_file_info(context.root .. PATHSEP .. "notes.txt"))
    test.equal(system.get_file_info(context.root .. PATHSEP .. "ideas.txt").type, "file")
  end)

  test.it("does not offer Rename or Delete while the tree has edits to apply", function(context)
    context.tree.buffer:insert(1, 1, "draft.txt\n")
    right_click_row(context.tree, "notes.txt")
    local labels = table.concat(context_menu.labels(), "|")
    test.ok(not labels:find("Delete", 1, true))
    test.ok(not labels:find("Rename", 1, true))
    test.ok(labels:find("Copy Path", 1, true))
  end)
end)
