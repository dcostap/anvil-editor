local common = require "core.common"
local core = require "core"
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
  local raw_open = io.open

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
      shown:update()
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

  test.it("keeps the Machine's files unchanged when the user edits the File Tree", function(context)
    local tree = open_tree(context)
    test.ok(wait_until(function() return text(tree):find("notes.md", 1, true) ~= nil end), text(tree))
    test.ok(tree.buffer.read_only, "The File Tree of a Machine Project must be read-only")
  end)
end)
