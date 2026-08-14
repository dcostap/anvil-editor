local core = require "core"
local Buffer = require "core.buffer"
local BufferRegistry = require "core.buffer_registry"
local test = require "core.test"

test.describe("Buffer Registry Save As identity", function()
  test.it("rejects an identity conflict before writing the target file", function()
    local old_buffers = core.buffers
    local old_registry = core.buffer_registry
    local path = USERDIR .. PATHSEP .. "buffer-registry-save-conflict-" .. system.get_process_id() .. ".lua"
    local file = assert(io.open(path, "wb"))
    file:write("original\n")
    file:close()

    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    local existing = Buffer(path, path, false)
    local untitled = Buffer()
    core.buffer_registry:register(existing, path)
    core.buffer_registry:register(untitled)
    untitled:insert(1, 1, "replacement")

    local ok, err = pcall(untitled.save, untitled, path, path)
    test.not_ok(ok)
    test.ok(tostring(err):find("already has this file identity", 1, true))
    local check = assert(io.open(path, "rb"))
    test.equal(check:read("*a"), "original\n")
    check:close()
    test.is_nil(untitled.abs_filename)

    core.buffers = old_buffers
    core.buffer_registry = old_registry
    os.remove(path)
  end)
end)
