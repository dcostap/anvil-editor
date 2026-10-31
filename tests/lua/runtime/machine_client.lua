local common = require "core.common"
local MachineClient = require "core.machine_client"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local test = require "core.test"

-- Seam: the Client that a Project process uses, against a real `anvil serve` process.
-- The server keeps its files under a private folder (`--test-root`), so one PC can hold
-- a Client copy and a different Machine copy at the same path.
test.describe("Machine client", function()
  local function write_file(path, text)
    common.mkdirp(common.dirname(path))
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
  end

  local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
  end

  -- The test-only mapping puts Machine path C:\a\b at <test root>\C\a\b.
  local function machine_copy(context, path)
    return context.store .. PATHSEP .. path:gsub("^(%a):", "%1")
  end

  local function call(client, method, params, bytes)
    local done, reply
    client:request(method, params, bytes, function(...) done, reply = true, table.pack(...) end)
    local deadline = system.get_time() + 10
    while not done and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(done, "The Machine did not answer " .. method)
    return table.unpack(reply, 1, reply.n)
  end

  test.before_each(function(context)
    -- The mapped path holds this folder twice, so a long name passes the Windows path limit.
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "mc" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.store = context.root .. PATHSEP .. "machine"
    context.project = context.root .. PATHSEP .. "project"
    context.notes = context.project .. PATHSEP .. "notes.md"
    test.ok(common.mkdirp(context.user))
    write_file(context.notes, "Client copy\n")
    write_file(machine_copy(context, context.notes), "Machine copy\n")
    context.server = machine_server.start(context.user, { "--test-root", context.store, context.project })
    context.client = MachineClient.new(machine_server.discovery_path(context.user))
  end)

  test.after_each(function(context)
    context.client:close()
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("reads the Machine's file, not the Client's copy at the same path", function(context)
    local err, result, bytes = call(context.client, "files.read", {path = context.notes})
    test.is_nil(err)
    test.equal(bytes, "Machine copy\n")
    test.equal(result.size, #"Machine copy\n")
  end)

  test.it("writes a file only while it has the version that the Client read", function(context)
    local _, read = call(context.client, "files.read", {path = context.notes})
    local err, written = call(context.client, "files.write", {path = context.notes, base = read.version}, "Saved\n")
    test.is_nil(err)
    test.not_equal(written.version, read.version)
    test.equal(read_file(machine_copy(context, context.notes)), "Saved\n")
    test.equal(read_file(context.notes), "Client copy\n")

    -- A write from the old version would replace newer text. The Machine returns its current file instead.
    local conflict, _, current = call(context.client, "files.write", {path = context.notes, base = read.version}, "Stale\n")
    test.equal(conflict.code, "conflict")
    test.equal(conflict.version, written.version)
    test.equal(current, "Saved\n")
    test.equal(read_file(machine_copy(context, context.notes)), "Saved\n")
  end)

  test.it("creates a file only when the Machine has none", function(context)
    local path = context.project .. PATHSEP .. "new" .. PATHSEP .. "idea.md"
    test.is_nil(call(context.client, "files.write", {path = path}, "First\n"))
    test.equal(read_file(machine_copy(context, path)), "First\n")
    test.equal(call(context.client, "files.write", {path = path}, "Second\n").code, "conflict")
    test.equal(read_file(machine_copy(context, path)), "First\n")
  end)
end)
