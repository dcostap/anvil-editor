local common = require "core.common"
local core = require "core"
local fs = require "core.fs"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local test = require "core.test"

-- Seam: the normal Buffer open, edit and save flow in a Project process that uses a Machine.
-- The Machine keeps its files under a private folder (`--test-root`). The Client has a different
-- copy at the same path, so a read of the Client's copy shows in the text or in the access log.
-- Other subsystems, such as Git and the Markdown vault index, still use the local disk.
test.describe("Buffer on a Machine", function()
  local raw_open = io.open

  local function write_file(path, text)
    common.mkdirp(common.dirname(path))
    local file = assert(raw_open(path, "wb"))
    file:write(text)
    file:close()
  end

  local function read_file(path)
    local file = raw_open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
  end

  local function machine_copy(context, path)
    return context.store .. PATHSEP .. path:gsub("^(%a):", "%1")
  end

  -- A View holds its Buffer. The test holds it the same way, so the registry keeps it open.
  local function open(context, path)
    return core.buffer_registry:retain(core.open_buffer(path), context)
  end

  local function wait_until(condition, what)
    local deadline = system.get_time() + 10
    while not condition() and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(condition(), what)
  end

  -- Records each content read of the Client's copies of the open files in this Lua state.
  -- Workers read through their payload, so the text checks catch their reads.
  local function watch_client_copy(context)
    local accesses, originals = {}, {}
    context.accesses, context.originals = accesses, originals
    local function watch(owner, name)
      local original = owner[name]
      originals[#originals + 1] = function() owner[name] = original end
      owner[name] = function(path, ...)
        if type(path) == "string" and (common.path_equals(path, context.notes)
            or common.path_equals(path, context.idea)) then
          accesses[#accesses + 1] = name .. " " .. path
        end
        return original(path, ...)
      end
    end
    watch(io, "open")
    watch(encoding, "detect")
  end

  test.before_each(function(context)
    -- The mapped path holds this folder twice, so a long name passes the Windows path limit.
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "mb" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.store = context.root .. PATHSEP .. "machine"
    context.project = context.root .. PATHSEP .. "project"
    context.notes = context.project .. PATHSEP .. "notes.md"
    context.idea = context.project .. PATHSEP .. "idea.md"
    test.ok(common.mkdirp(context.user))
    -- A UTF-16 Client copy changes the detected encoding if any code reads it.
    write_file(context.notes, "\255\254C\0l\0i\0e\0n\0t\0\n\0")
    write_file(machine_copy(context, context.notes), "Machine copy\n")
    write_file(context.idea, "Client only\n")
    context.server = machine_server.start(context.user, { "--test-root", context.store, context.project })
    context.original_buffers = core.buffers
    core.buffers = {}
    fs.use_machine(machine_server.discovery_path(context.user))
    watch_client_copy(context)
  end)

  test.after_each(function(context)
    for _, restore in ipairs(context.originals) do restore() end
    for _, buffer in ipairs(core.buffers) do core.buffer_registry:remove(buffer, true) end
    core.buffers = context.original_buffers
    fs.use_local()
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("opens, edits and saves the Machine's file", function(context)
    local buffer = open(context, context.notes)
    wait_until(function() return not buffer:is_loading() end, "The Buffer did not load")
    test.equal(table.concat(buffer.lines), "Machine copy\n")
    test.equal(buffer.encoding, "UTF-8")
    test.not_ok(buffer:is_dirty())

    buffer:insert(1, 1, "Edited ")
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The save did not finish")
    test.equal(read_file(machine_copy(context, context.notes)), "Edited Machine copy\n")

    -- A second save sends the version that the first save made.
    buffer:insert(1, 1, "Twice ")
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The second save did not finish")
    test.equal(read_file(machine_copy(context, context.notes)), "Twice Edited Machine copy\n")

    test.equal(read_file(context.notes), "\255\254C\0l\0i\0e\0n\0t\0\n\0")
    test.same(context.accesses, {})
  end)

  test.it("creates a file that the Machine does not have", function(context)
    local buffer = open(context, context.idea)
    wait_until(function() return not buffer:is_loading() end, "The Buffer did not load")
    test.equal(table.concat(buffer.lines), "\n")

    buffer:insert(1, 1, "New")
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The save did not finish")
    -- A new Buffer takes its line endings from the settings.
    test.equal((read_file(machine_copy(context, context.idea)):gsub("\r\n", "\n")), "New\n")
    test.equal(read_file(context.idea), "Client only\n")
    test.same(context.accesses, {})
  end)
end)
