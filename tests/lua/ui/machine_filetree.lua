local common = require "core.common"
local core = require "core"
local Editor = require "core.editor"
local command = require "core.command"
local config = require "core.config"
local fs = require "core.fs"
local machine_folders = require "core.machine_folders"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local panes = require "core.panes"
local Project = require "core.project"
local project_files = require "core.project_files"
local filetree = require "plugins.filetree"
local test = require "core.test"

-- Seam: the File Tree in a Project process that uses a Machine. The Machine keeps its files under a private
-- folder (`--test-root`). The Client has other files at the same path, and the Machine guard refuses raw reads
-- of them.
test.describe("File Tree on a Machine", function()
  local raw_open, raw_list_dir = io.open, system.list_dir

  local function write_file(path, text)
    common.mkdirp(common.dirname(path))
    local file = assert(raw_open(path, "wb"))
    file:write(text)
    file:close()
  end

  local function machine_copy(context, path)
    return context.store .. PATHSEP .. path:gsub("^(%a):", "%1")
  end

  -- The File Tree shown in the test. Each wait updates it, as each frame does.
  local shown

  local function open_tree(context)
    shown = assert(filetree.new(context.project))
    panes.create { factory = function() return shown end }
    core.active_view = shown
    return shown
  end

  local function wait_until(condition)
    local deadline = system.get_time() + 15
    while not condition() and system.get_time() < deadline do
      if shown then shown:update() end
      coroutine.yield(0.02)
    end
    return condition()
  end

  local function text(tree) return table.concat(tree.buffer.lines) end

  test.before_each(function(context)
    -- The mapped path holds this folder twice, so a short name stays within the Windows path limit.
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "mt" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.store = context.root .. PATHSEP .. "machine"
    context.project = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.user))
    write_file(context.project .. PATHSEP .. "client-only.md", "Client\n")
    write_file(machine_copy(context, context.project .. PATHSEP .. "notes.md"), "Notes\n")
    write_file(machine_copy(context, context.project .. PATHSEP .. "sub" .. PATHSEP .. "plan.md"), "Plan\n")
    context.projects, context.active = core.projects, core.active_view
    core.projects = { Project(context.project) }
    context.server = machine_server.start(context.user, { "--test-root", context.store, context.project })
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    shown = nil
    core.active_view = context.active
    machine_folders.clear()
    project_files.invalidate(context.project)
    fs.use_local()
    core.projects = context.projects
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("lists the Machine's folders and shows a change on the Machine", function(context)
    local tree = open_tree(context)
    test.ok(wait_until(function() return text(tree):find("notes.md", 1, true) ~= nil end), text(tree))
    test.ok(text(tree):find("sub/", 1, true), text(tree))
    test.is_nil(text(tree):find("client-only.md", 1, true))

    write_file(machine_copy(context, context.project .. PATHSEP .. "new.md"), "New\n")
    test.ok(wait_until(function() return text(tree):find("new.md", 1, true) ~= nil end), text(tree))
  end)

  test.it("opens the Machine's image", function(context)
    local path = context.project .. PATHSEP .. "picture.png"
    test.ok(canvas.new(8, 6, { 40, 100, 180, 255 }, true):save_image(machine_copy(context, path)))
    local view = test.not_nil(core.open_file(path))
    shown = view
    test.ok(wait_until(function() return view.image ~= nil end), tostring(view.errmsg))
    test.same({ view.image:get_size() }, { 8, 6 })
  end)

  test.it("makes a folder, and renames and deletes an open file, with the file commands", function(context)
    local path = context.project .. PATHSEP .. "notes.md"
    local buffer = core.open_buffer(path)
    shown = Editor(buffer)
    panes.focus(panes.create { factory = function() return shown end })
    test.ok(wait_until(function() return not buffer:is_loading() end), "The Machine's file did not open")
    buffer:insert(1, 1, "Renamed ")

    test.ok(command.perform("editor:rename"), "Rename did not run")
    core.global_prompt_bar:set_text("renamed.md")
    core.global_prompt_bar:submit()
    local renamed = context.project .. PATHSEP .. "renamed.md"
    test.ok(wait_until(function()
      return common.path_equals(buffer.abs_filename, renamed) and not buffer:is_dirty()
    end), "The file was not renamed and saved: " .. tostring(buffer.abs_filename))
    local file = assert(raw_open(machine_copy(context, renamed), "rb"))
    test.equal(file:read("*a"), "Renamed Notes\n")
    file:close()
    test.is_nil(system.get_file_info(machine_copy(context, path)))

    command.perform("editor:delete")
    test.ok(wait_until(function() return system.get_file_info(machine_copy(context, renamed)) == nil end),
      "The Machine's file was not deleted")

    command.perform("core:create_directory")
    core.global_prompt_bar:set_text("made" .. PATHSEP .. "deep")
    core.global_prompt_bar:submit()
    test.ok(wait_until(function()
      local info = system.get_file_info(machine_copy(context, context.project .. PATHSEP .. "made" .. PATHSEP .. "deep"))
      return info and info.type == "dir"
    end), "The Machine has no new folder")
    test.same(raw_list_dir(context.project), { "client-only.md" })
  end)

  test.it("uploads a file from this PC into a note's attachment folder", function(context)
    local path = context.project .. PATHSEP .. "notes.md"
    local buffer = core.open_buffer(path)
    shown = Editor(buffer)
    panes.focus(panes.create { factory = function() return shown end })
    test.ok(wait_until(function() return not buffer:is_loading() end), "The Machine's file did not open")
    local source = context.root .. PATHSEP .. "pasted.png"
    write_file(source, "image bytes")

    local ok, result = require("core.markdown.attachments").import_file(shown, source)
    test.ok(ok, result)
    test.ok(common.path_belongs_to(result.path, context.project), result.path)
    local file = assert(raw_open(machine_copy(context, result.path), "rb"))
    test.equal(file:read("*a"), "image bytes")
    file:close()
    test.ok(table.concat(buffer.lines):find(result.text, 1, true), table.concat(buffer.lines))
    test.same(raw_list_dir(context.project), { "client-only.md" })
  end)

  local function find_entry(tree, name)
    for _, entry in ipairs(tree:build_entries(false)) do
      if entry.text == name then return entry end
    end
    error("Missing entry: " .. name)
  end

  test.it("creates, renames and deletes the Machine's files", function(context)
    config.plugins.filetree.delete_to_trash, context.trash = false, config.plugins.filetree.delete_to_trash
    local tree = open_tree(context)
    test.ok(wait_until(function() return text(tree):find("notes.md", 1, true) ~= nil end), text(tree))
    local notes = find_entry(tree, "notes.md")
    tree.buffer:insert(notes.line, 1, "renamed-")
    tree:sync_meta()
    local sub = find_entry(tree, "sub")
    tree.buffer:remove(sub.line, 1, sub.line + 1, 1)
    tree:sync_meta()
    local last = #tree.buffer.lines
    tree.buffer:insert(last, #tree.buffer.lines[last], "\nmade/new.md")
    tree:sync_meta()
    local plan, err = tree:plan_changes()
    test.not_nil(plan, err)
    local done
    tree:apply_plan(plan, function(changed) done = changed end)
    test.ok(wait_until(function() return done ~= nil end), "the File Tree did not finish its changes")
    config.plugins.filetree.delete_to_trash = context.trash
    test.ok(done)

    local function on_machine(name) return system.get_file_info(machine_copy(context, context.project .. PATHSEP .. name)) end
    test.ok(on_machine("renamed-notes.md"))
    test.is_nil(on_machine("notes.md"))
    test.equal(on_machine("made" .. PATHSEP .. "new.md").type, "file")
    test.is_nil(on_machine("sub"))
    -- The Client's copy at the same path does not change.
    test.same(raw_list_dir(context.project), { "client-only.md" })
    test.ok(wait_until(function() return text(tree):find("renamed-notes.md", 1, true) ~= nil end), text(tree))
    test.is_nil(text(tree):find("sub/", 1, true))
  end)
end)
