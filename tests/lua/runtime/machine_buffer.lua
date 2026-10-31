local autosave_fast = require "plugins.autosave_fast"
local common = require "core.common"
local core = require "core"
local fs = require "core.fs"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local test = require "core.test"

-- Seam: the normal Buffer open, edit and save flow in a Project process that uses a Machine.
-- The Machine keeps its files under a private folder (`--test-root`). The Client has a different
-- copy at the same path, so a read of the Client's copy shows in the text or in the access log.
-- Other subsystems, such as Git and the Markdown vault index, still use the local disk.
-- Idle autosave is off, so only the explicit saves write.
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

  local function wait_until(condition, what)
    local deadline = system.get_time() + 15
    while not condition() and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(condition(), what)
  end

  -- A View holds its Buffer. The test holds it the same way, so the registry keeps it open.
  local function open(context, path)
    local buffer = core.buffer_registry:retain(core.open_buffer(path), context)
    context.buffers[#context.buffers + 1] = buffer
    wait_until(function() return not buffer:is_loading() end, "The Buffer did not load")
    return buffer
  end

  local function text(buffer) return table.concat(buffer.lines) end

  local function start_server(context, ...)
    local args = { "--test-root", context.store, ... }
    args[#args + 1] = context.project
    context.server = machine_server.start(context.user, args)
  end

  -- Records each content read of the Client's copies of the open files in this Lua state.
  -- Workers read through their payload, so the text checks catch their reads.
  local function watch_client_copy(context)
    local function watch(owner, name)
      local original = owner[name]
      context.restore[#context.restore + 1] = function() owner[name] = original end
      owner[name] = function(path, ...)
        if type(path) == "string" and (common.path_equals(path, context.notes)
            or common.path_equals(path, context.idea)) then
          context.accesses[#context.accesses + 1] = name .. " " .. path
        end
        return original(path, ...)
      end
    end
    watch(io, "open")
    watch(encoding, "detect")
  end

  -- Records each conflict choice that autosave shows. `context.prompt` holds the newest one.
  local function capture_prompts(context)
    local show = core.nag_view.show
    context.restore[#context.restore + 1] = function() core.nag_view.show = show end
    core.nag_view.show = function(_, title, _, buttons, callback)
      context.prompt = { title = title, buttons = buttons, choose = function(choice)
        context.prompt = nil
        callback({ text = choice })
      end }
    end
  end

  test.before_each(function(context)
    -- The mapped path holds this folder twice, so a long name passes the Windows path limit.
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "mb" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.store = context.root .. PATHSEP .. "machine"
    context.project = context.root .. PATHSEP .. "project"
    context.notes = context.project .. PATHSEP .. "notes.md"
    context.idea = context.project .. PATHSEP .. "idea.md"
    context.buffers, context.accesses, context.restore = {}, {}, {}
    test.ok(common.mkdirp(context.user))
    -- A UTF-16 Client copy changes the detected encoding if any code reads it.
    write_file(context.notes, "\255\254C\0l\0i\0e\0n\0t\0\n\0")
    write_file(machine_copy(context, context.notes), "Machine copy\n")
    write_file(context.idea, "Client only\n")
    local enabled = autosave_fast.enabled
    context.restore[#context.restore + 1] = function() autosave_fast.enabled = enabled end
    autosave_fast.enabled = false
    watch_client_copy(context)
    capture_prompts(context)
  end)

  test.after_each(function(context)
    for _, restore in ipairs(context.restore) do restore() end
    for _, buffer in ipairs(context.buffers) do
      core.buffer_registry:release(buffer, context)
      core.buffer_registry:remove(buffer, true)
    end
    fs.use_local()
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("opens, edits and saves the Machine's file", function(context)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user))
    local buffer = open(context, context.notes)
    test.equal(text(buffer), "Machine copy\n")
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
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user))
    local buffer = open(context, context.idea)
    test.equal(text(buffer), "\n")

    buffer:insert(1, 1, "New")
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The save did not finish")
    -- A new Buffer takes its line endings from the settings.
    test.equal((read_file(machine_copy(context, context.idea)):gsub("\r\n", "\n")), "New\n")
    test.equal(read_file(context.idea), "Client only\n")
    test.same(context.accesses, {})
  end)

  test.it("does not save over a change on the Machine until the user overwrites it", function(context)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user))
    local buffer = open(context, context.notes)
    write_file(machine_copy(context, context.notes), "Changed on the Machine\n")

    buffer:insert(1, 1, "Mine ")
    buffer:save()
    wait_until(function() return context.prompt end, "The conflict choice did not show")
    test.equal(context.prompt.title, "File Changed on Disk")
    test.equal(read_file(machine_copy(context, context.notes)), "Changed on the Machine\n")
    test.ok(buffer:is_dirty())

    context.prompt.choose("Overwrite Disk")
    wait_until(function() return not buffer:is_dirty() end, "The overwrite did not finish")
    test.equal(read_file(machine_copy(context, context.notes)), "Mine Machine copy\n")
  end)

  test.it("finds the result of a save whose reply was lost", function(context)
    start_server(context, "--test-lose-reply", "files.write")
    fs.use_machine(machine_server.discovery_path(context.user))
    local buffer = open(context, context.notes)

    buffer:insert(1, 1, "Saved ")
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The lost save did not resolve")
    test.equal(read_file(machine_copy(context, context.notes)), "Saved Machine copy\n")
    test.equal(fs.machine.connections, 2)

    -- The next save uses the version of the lost save as its base.
    buffer:insert(1, 1, "Again ")
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The next save did not finish")
    test.equal(read_file(machine_copy(context, context.notes)), "Again Saved Machine copy\n")
    test.is_nil(context.prompt)
  end)

  test.it("after a reconnect, reloads a clean Buffer and keeps the text of a dirty one", function(context)
    write_file(machine_copy(context, context.idea), "Idea on the Machine\n")
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user))
    local clean = open(context, context.notes)
    local dirty = open(context, context.idea)
    dirty:insert(1, 1, "Unsaved ")

    machine_server.stop(context.server)
    write_file(machine_copy(context, context.notes), "Notes changed during the disconnect\n")
    write_file(machine_copy(context, context.idea), "Idea changed during the disconnect\n")
    start_server(context)

    wait_until(function() return text(clean) == "Notes changed during the disconnect\n" end,
      "The clean Buffer did not reload")
    test.not_ok(clean:is_dirty())
    wait_until(function() return context.prompt end, "The conflict choice did not show")
    test.equal(text(dirty), "Unsaved Idea on the Machine\n")

    context.prompt.choose("Reload From Disk (Discard Anvil Edits)")
    wait_until(function() return text(dirty) == "Idea changed during the disconnect\n" end,
      "The dirty Buffer did not reload")
    test.not_ok(dirty:is_dirty())
  end)
end)
