local common = require "core.common"
local fs = require "core.fs"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

-- Seam: the raw file functions in a Project process that uses a Machine. The Project's paths
-- name the Machine's files, so these functions refuse them, and refuse relative paths. Other
-- absolute paths are local, such as USERDIR. No server runs: the guard does not need one.
test.describe("Machine guard", function()
  local function write_file(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
  end

  local function refused(fn, ...)
    local ok, err = pcall(fn, ...)
    test.not_ok(ok, "The call reached the disk")
    test.ok(tostring(err):find("on a Machine", 1, true), tostring(err))
  end

  test.before_each(function(context)
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "mg" .. math.floor(system.get_time() * 1000) % 1000000
    context.project = context.root .. PATHSEP .. "project"
    context.notes = context.project .. PATHSEP .. "notes.md"
    context.sibling = context.root .. PATHSEP .. "project-old"
    test.ok(common.mkdirp(context.project))
    test.ok(common.mkdirp(context.sibling))
    write_file(context.notes, "Client copy\n")
    fs.use_machine(context.root .. PATHSEP .. "machine.json", { context.project })
  end)

  test.after_each(function(context)
    fs.use_local()
    test.ok(test.remove_tree(context.root))
  end)

  test.it("refuses the Project's paths and relative paths, and keeps local paths", function(context)
    refused(io.open, context.notes, "rb")
    refused(system.get_file_info, context.project)
    refused(system.list_dir, (context.project:gsub("\\", "/")))
    refused(os.remove, context.project .. PATHSEP .. "sub" .. PATHSEP .. ".." .. PATHSEP .. "notes.md")
    refused(io.open, "notes.md", "rb")
    refused(process.start, { "rg", "Client", context.project })
    refused(process.start, { "rg", "Client" }, { cwd = context.project })
    if PLATFORM == "Windows" then refused(io.open, context.notes:upper(), "rb") end

    test.ok(system.get_file_info(context.sibling), "A folder beside the Project is local")
    test.ok(system.get_file_info(context.root), "A folder above the Project is local")

    fs.use_local()
    local file = assert(io.open(context.notes, "rb"))
    test.equal(file:read("*a"), "Client copy\n")
    file:close()
  end)

  test.it("owns the files of a Project at a drive root", function(context)
    local drive = PLATFORM == "Windows" and context.root:match("^%a:\\") or "/"
    fs.use_machine(context.root .. PATHSEP .. "machine.json", { drive })
    local file = drive .. "notes.md"
    test.ok(fs.on_machine(file), file)
    refused(process.start, { "rg", "Client", file })
    fs.use_local()
  end)

  test.it("refuses a worker job that names a Project path", function(context)
    local pool = worker_pool.system()
    refused(pool.submit, pool, { kind = "worker_pool_test", payload = { files = { context.notes } } })
  end)
end)
