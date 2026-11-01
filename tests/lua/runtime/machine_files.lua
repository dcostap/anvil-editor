local common = require "core.common"
local core = require "core"
local fs = require "core.fs"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local Project = require "core.project"
local project_files = require "core.project_files"
local test = require "core.test"

-- Seam: `core.project_files` in a Project process that uses a Machine. The Machine keeps its files
-- under a private folder (`--test-root`). The Client has other files at the same path, and the Machine
-- guard refuses raw reads of them.
test.describe("Project files on a Machine", function()
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

  local function wait_until(condition, what)
    local deadline = system.get_time() + 15
    while not condition() and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(condition(), what)
  end

  local function relative_names(files)
    local names = {}
    for i, file in ipairs(files) do names[i] = file.relative end
    table.sort(names)
    return names
  end

  test.before_each(function(context)
    -- The mapped path holds this folder twice, so a short name stays within the Windows path limit.
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "mf" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.store = context.root .. PATHSEP .. "machine"
    context.project = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.user))
    write_file(context.project .. PATHSEP .. "client-only.md", "Client\n")
    write_file(machine_copy(context, context.project .. PATHSEP .. "notes.md"), "Notes\n")
    write_file(machine_copy(context, context.project .. PATHSEP .. "sub" .. PATHSEP .. "a.txt"), "A\n")
    context.projects = core.projects
    core.projects = { Project(context.project) }
    context.server = machine_server.start(context.user, { "--test-root", context.store, context.project })
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
  end)

  test.after_each(function(context)
    project_files.unsubscribe(context.project, "machine-files-test")
    project_files.invalidate(context.project)
    fs.use_local()
    core.projects = context.projects
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("lists and stats the Machine's files, not the Client's", function(context)
    local files, err, directories = project_files.list(context.project, { refresh = true })
    test.is_nil(err)
    test.same(relative_names(files), { "notes.md", "sub" .. PATHSEP .. "a.txt" })
    test.ok(project_files.contains(context.project, context.project .. PATHSEP .. "sub", "dir"))
    test.equal(#directories, 2)

    local notes, client_only = context.project .. PATHSEP .. "notes.md", context.project .. PATHSEP .. "client-only.md"
    local info = project_files.stat_paths({ notes, client_only })
    test.equal(info[notes].type, "file")
    test.equal(info[client_only], false)
  end)

  test.it("loads a note's image from the Machine", function(context)
    local images = require "core.markdown.images"
    local folder = context.project .. PATHSEP .. "attachments"
    test.ok(common.mkdirp(machine_copy(context, folder)))
    test.ok(canvas.new(8, 6, { 40, 100, 180, 255 }, true):save_image(machine_copy(context, folder .. PATHSEP .. "pic.png")))
    write_file(machine_copy(context, context.project .. PATHSEP .. ".obsidian" .. PATHSEP .. "app.json"),
      '{"attachmentFolderPath": "attachments"}')
    images.clear_assets()
    local opts = { source_path = context.project .. PATHSEP .. "notes.md", project_root = context.project }
    local found, missing = images.get_asset("pic.png", opts), images.get_asset("gone.png", opts)
    local notices = 0
    images.subscribe(found, context, function() notices = notices + 1 end)
    wait_until(function() return found.status ~= "loading" and missing.status ~= "loading" end, "The images did not load")
    test.equal(found.status, "ready", found.errmsg)
    test.same({ found.image:get_size() }, { 8, 6 })
    test.equal(notices, 1)
    test.equal(missing.status, "error")

    -- A missing image loads when it appears on the Machine, and its note hears it.
    local heard = false
    images.subscribe(missing, context, function() heard = missing.status == "ready" end)
    wait_until(function() return project_files.watch_status(context.project).running end, "The watcher did not start")
    test.ok(canvas.new(4, 3, { 40, 100, 180, 255 }, true):save_image(machine_copy(context, folder .. PATHSEP .. "gone.png")))
    wait_until(function() return heard end, "The missing image did not load after it appeared")
    images.clear_assets()
  end)

  test.it("gets the Machine's changes again after the Machine comes back", function(context)
    project_files.subscribe(context.project, "machine-files-test", function() end)
    project_files.list(context.project, { refresh = true })
    wait_until(function() return project_files.watch_status(context.project).running end, "The watcher did not start")
    machine_server.stop(context.server)
    wait_until(function() return fs.machine.state == "waiting" end, "The Client did not see the disconnect")
    -- The recovery scan runs and fails while the Machine is away.
    coroutine.yield(3)
    context.server = machine_server.start(context.user, { "--test-root", context.store, context.project })
    wait_until(function() return fs.machine.state == "ready" end, "The Client did not connect again")
    local new = context.project .. PATHSEP .. "after.md"
    write_file(machine_copy(context, new), "After\n")
    wait_until(function() return project_files.contains(context.project, new, "file") end,
      "The Project's list did not get the new file")
  end)

  test.it("keeps a bounded amount of unread Text Search output, and gives all of it to its reader", function(context)
    local line = "word " .. string.rep("x", 58) .. "\n"
    write_file(machine_copy(context, context.project .. PATHSEP .. "many.txt"), string.rep(line, 100000))
    local stream = require("core.text_search").start(
      { "rg", "--no-config", "--with-filename", "--line-number", "-F", "-e", "word", "--", "." },
      { cwd = context.project })
    local function unread()
      local bytes = 0
      for _, part in ipairs(stream.parts) do bytes = bytes + #part end
      return bytes
    end
    wait_until(function() return unread() > 0 end, "The search sent no output")
    -- The output is about 7 MiB. A stream that nobody reads stops asking the Machine for more.
    coroutine.yield(2)
    test.not_ok(stream.done, "The unread search took all its output")
    test.ok(unread() <= 3 * 1024 * 1024, "The unread search kept " .. unread() .. " bytes")
    local lines = 0
    wait_until(function()
      while stream:read_line() do lines = lines + 1 end
      return stream.done and #stream.parts == 0
    end, "The search did not end")
    while stream:read_line() do lines = lines + 1 end
    test.equal(lines, 100000)
  end)

  test.it("reports a change on the Machine to subscribers", function(context)
    local changed = {}
    project_files.subscribe(context.project, "machine-files-test", function(paths)
      for path in pairs(paths) do changed[#changed + 1] = path end
    end)
    project_files.list(context.project, { refresh = true })
    local new = context.project .. PATHSEP .. "sub" .. PATHSEP .. "new.md"
    -- The Machine's watcher needs a moment after the first list before it sees changes.
    wait_until(function() return project_files.watch_status(context.project).running end, "The watcher did not start")
    write_file(machine_copy(context, new), "New\n")
    wait_until(function() return project_files.contains(context.project, new, "file") end,
      "The Project's list did not get the new file")
    wait_until(function()
      for _, path in ipairs(changed) do
        if common.path_equals(path, new) then return true end
      end
    end, "The subscriber did not get the new file")
  end)
end)
