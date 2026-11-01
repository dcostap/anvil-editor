local autosave_fast = require "plugins.autosave_fast"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local fs = require "core.fs"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local Project = require "core.project"
local storage = require "core.storage"
local test = require "core.test"

-- Seam: the normal Buffer open, edit and save flow in a Project process that uses a Machine.
-- The Machine keeps its files under a private folder (`--test-root`). The Client has a different
-- copy at the same path. The Machine guard refuses raw reads of it in this Lua state, and the
-- text checks catch reads in workers. Idle autosave is off, so only the explicit saves write.
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

  local function record_count() return #storage.keys("machine_recovery") end

  -- A crash loses the Buffer and the connection. Only the recovery record stays.
  local function crash(context, buffer)
    fs.use_local()
    core.buffer_registry:release(buffer, context)
    core.buffer_registry:remove(buffer, true)
  end

  local function start_server(context, ...)
    local args = { "--test-root", context.store, ... }
    args[#args + 1] = context.project
    context.server = machine_server.start(context.user, args)
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
    context.notes = context.project .. PATHSEP .. "notes.txt"
    context.idea = context.project .. PATHSEP .. "idea.txt"
    context.buffers, context.restore = {}, {}
    test.ok(common.mkdirp(context.user))
    -- A UTF-16 Client copy changes the detected encoding if any code reads it.
    write_file(context.notes, "\255\254C\0l\0i\0e\0n\0t\0\n\0")
    write_file(machine_copy(context, context.notes), "Machine copy\n")
    write_file(context.idea, "Client only\n")
    local enabled, projects = autosave_fast.enabled, core.projects
    context.restore[#context.restore + 1] = function()
      autosave_fast.enabled = enabled
      core.projects = projects
    end
    autosave_fast.enabled = false
    -- In a Project process on a Machine, the Machine's Project is the only Project.
    core.projects = { Project(context.project) }
    capture_prompts(context)
  end)

  test.after_each(function(context)
    for _, restore in ipairs(context.restore) do restore() end
    for _, buffer in ipairs(context.buffers) do
      core.buffer_registry:release(buffer, context)
      core.buffer_registry:remove(buffer, true)
    end
    fs.use_local()
    storage.clear("machine_recovery")
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("opens, edits and saves the Machine's file", function(context)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
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

    -- An undo and a new edit before the reply can reach the same undo position. That text is not saved.
    -- Edits within the undo merge time join one undo step, so this test waits between them.
    coroutine.yield(config.undo_merge_timeout + 0.1)
    buffer:insert(1, 1, "A ")
    buffer:save()
    buffer:undo()
    buffer:insert(1, 1, "B ")
    wait_until(function() return not buffer.machine_save end, "The third save did not finish")
    test.equal(read_file(machine_copy(context, context.notes)), "A Twice Edited Machine copy\n")
    test.ok(buffer:is_dirty())

    -- Text typed while a reload reads the file stays.
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The fourth save did not finish")
    buffer:reload()
    buffer:insert(1, 1, "Typed ")
    coroutine.yield(1)
    test.equal(text(buffer), "Typed B Twice Edited Machine copy\n")
    test.ok(buffer:is_dirty())
  end)

  test.it("opens and saves a file of this PC's own folders on this PC", function(context)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    -- The User Module is in this PC's user folder, outside the Project.
    local path = context.root .. PATHSEP .. "init.lua"
    write_file(path, "-- This PC\n")
    local buffer = open(context, path)
    test.equal(text(buffer), "-- This PC\n")
    buffer:insert(1, 1, "-- Edited\n")
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The save did not finish")
    test.equal(read_file(path), "-- Edited\n-- This PC\n")
  end)

  test.it("opens a file whose text names a Project path", function(context)
    write_file(machine_copy(context, context.idea), context.notes)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    local buffer = open(context, context.idea)
    test.equal(text(buffer), context.notes .. "\n")
  end)

  test.it("creates a file that the Machine does not have", function(context)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    local buffer = open(context, context.idea)
    test.equal(text(buffer), "\n")

    buffer:insert(1, 1, "New")
    buffer:save()
    wait_until(function() return not buffer:is_dirty() end, "The save did not finish")
    -- A new Buffer takes its line endings from the settings.
    test.equal((read_file(machine_copy(context, context.idea)):gsub("\r\n", "\n")), "New\n")
    test.equal(read_file(context.idea), "Client only\n")
  end)

  test.it("does not save over a change on the Machine until the user overwrites it", function(context)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
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
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
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
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
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

  test.it("restores unsaved text after a crash", function(context)
    start_server(context)
    local discovery = machine_server.discovery_path(context.user)
    fs.use_machine(discovery, { context.project })
    local buffer = open(context, context.notes)
    buffer:insert(1, 1, "Unsaved ")
    wait_until(function() return record_count() == 1 end, "The recovery record was not written")
    crash(context, buffer)

    fs.use_machine(discovery, { context.project })
    local restored = open(context, context.notes)
    test.equal(text(restored), "Unsaved Machine copy\n")
    test.ok(restored:is_dirty())
    restored:save()
    wait_until(function() return not restored:is_dirty() end, "The save did not finish")
    test.equal(read_file(machine_copy(context, context.notes)), "Unsaved Machine copy\n")
    wait_until(function() return record_count() == 0 end, "The saved Buffer kept its recovery record")
    test.is_nil(context.prompt)
  end)

  test.it("forgets the unsaved text of a Buffer that the user discards", function(context)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    local buffer = open(context, context.notes)
    buffer:insert(1, 1, "Discarded ")
    wait_until(function() return record_count() == 1 end, "The recovery record was not written")
    -- An edit just before the close has a record write that is still due.
    buffer:insert(1, 1, "Late ")
    core.buffer_registry:release(buffer, context)
    core.buffer_registry:remove(buffer, true)
    test.equal(record_count(), 0)
    coroutine.yield(1)
    test.equal(record_count(), 0)
    local reopened = open(context, context.notes)
    test.equal(text(reopened), "Machine copy\n")
    test.ok(not reopened:is_dirty())
  end)

  test.it("keeps the record of a dirty Buffer whose file gets a new name", function(context)
    start_server(context)
    local discovery = machine_server.discovery_path(context.user)
    fs.use_machine(discovery, { context.project })
    local buffer = open(context, context.notes)
    buffer:insert(1, 1, "Unsaved ")
    wait_until(function() return record_count() == 1 end, "The recovery record was not written")
    -- The File Tree moves the file on the Machine, then renames the open Buffer.
    local moved = context.project .. PATHSEP .. "moved.txt"
    write_file(machine_copy(context, moved), read_file(machine_copy(context, context.notes)))
    os.remove(machine_copy(context, context.notes))
    buffer:set_filename("moved.txt", moved)
    test.equal(record_count(), 1)
    crash(context, buffer)

    fs.use_machine(discovery, { context.project })
    local restored = open(context, moved)
    test.equal(text(restored), "Unsaved Machine copy\n")
    test.ok(restored:is_dirty())
  end)

  test.it("saves an offline Save As to its new file after the reconnect", function(context)
    start_server(context)
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    local buffer = open(context, context.notes)
    buffer:insert(1, 1, "Copy of ")
    machine_server.stop(context.server)
    wait_until(function() return fs.machine.state == "waiting" end, "The Client did not see the disconnect")
    local copy = context.project .. PATHSEP .. "copy.txt"
    buffer:save("copy.txt", copy)
    wait_until(function() return not buffer.machine_save end, "The offline save did not end")
    start_server(context)
    wait_until(function() return read_file(machine_copy(context, copy)) == "Copy of Machine copy\n" end,
      "The Save As did not reach the new file")
    test.equal(read_file(machine_copy(context, context.notes)), "Machine copy\n")
    wait_until(function() return not buffer:is_dirty() end, "The Save As did not finish")
    test.ok(common.path_equals(buffer.abs_filename, copy), buffer.abs_filename)
  end)

  test.it("after a crash during a save, knows the save from the record", function(context)
    start_server(context, "--test-lose-reply", "files.write")
    local discovery = machine_server.discovery_path(context.user)
    fs.use_machine(discovery, { context.project })
    local buffer = open(context, context.notes)
    buffer:insert(1, 1, "Saved ")
    buffer:save()
    buffer:insert(1, 1, "Later ")
    -- Stop the Machine before the Client asks for the save's result. A restarted server does not know it.
    wait_until(function() return read_file(machine_copy(context, context.notes)) == "Saved Machine copy\n" end,
      "The save did not reach the Machine")
    machine_server.stop(context.server)
    wait_until(function()
      local record = storage.load("machine_recovery", storage.keys("machine_recovery")[1] or "")
      return type(record) == "table" and record.text == "Later Saved Machine copy\n"
    end, "The recovery record did not get the later edit")
    crash(context, buffer)

    start_server(context)
    fs.use_machine(discovery, { context.project })
    local restored = open(context, context.notes)
    test.equal(text(restored), "Later Saved Machine copy\n")
    test.ok(restored:is_dirty())
    restored:save()
    wait_until(function() return not restored:is_dirty() end, "The save did not finish")
    test.equal(read_file(machine_copy(context, context.notes)), "Later Saved Machine copy\n")
    test.is_nil(context.prompt)
  end)
end)

-- Seam: the Buffer's save flow, with the Machine's write replies held at the transport. The test
-- sends each reply, so edits, undos and closes can come before it.
test.describe("Buffer on a Machine while a save waits for its reply", function()
  local Buffer = require "core.buffer"
  local machine = require "machine"

  local function text(buffer) return table.concat(buffer.lines) end

  local function reply(write, err)
    if err then return write.done(err) end
    write.done(nil, machine.content_version(write.bytes))
  end

  test.before_each(function(context)
    context.write, context.enabled = fs.write, autosave_fast.enabled
    context.read, context.save_result = fs.read, fs.save_result
    autosave_fast.enabled = false
    fs.machine = { machine = "held-replies", close = function() end }
    context.writes = {}
    fs.write = function(path, bytes, base, _, done)
      context.writes[#context.writes + 1] = { path = path, bytes = bytes, base = base, done = done }
    end
    context.path = USERDIR .. PATHSEP .. "source.md"
    context.copy = USERDIR .. PATHSEP .. "copy.md"
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("source.md", context.path)
    buffer:insert(1, 1, "Original")
    buffer.new_file = false
    buffer:clean()
    buffer.machine_version = machine.content_version("Original\n")
    buffer.on_machine_conflict = function(self) context.conflict = self.machine_conflict end
    context.buffer = buffer
    -- Edits within the undo merge time join one undo step.
    coroutine.yield(config.undo_merge_timeout + 0.1)
  end)

  test.after_each(function(context)
    core.buffer_registry:release(context.buffer, context)
    core.buffer_registry:remove(context.buffer, true)
    if not context.buffer.machine_closed then context.buffer:on_close() end
    fs.write, autosave_fast.enabled = context.write, context.enabled
    fs.read, fs.save_result = context.read, context.save_result
    fs.use_local()
    storage.clear("machine_recovery")
  end)

  test.it("does not call text clean that the Machine did not save", function(context)
    local buffer = context.buffer
    buffer:insert(1, 1, "A ")
    buffer:save()
    buffer:undo()
    buffer:insert(1, 1, "B ")
    coroutine.yield(config.undo_merge_timeout + 0.1)
    buffer:insert(1, 1, "C ")
    reply(context.writes[1])
    buffer:undo()
    test.equal(text(buffer), "B Original\n")
    test.ok(buffer:is_dirty())
  end)

  test.it("keeps the recovery record of text that differs from an unresolved save", function(context)
    local buffer = context.buffer
    buffer:insert(1, 1, "A ")
    buffer:save()
    buffer:undo()
    coroutine.yield(1)
    test.equal(#storage.keys("machine_recovery"), 1)
    -- The Machine saved A, so the undone text is unsaved.
    reply(context.writes[1])
    test.ok(buffer:is_dirty())
    coroutine.yield(1)
    test.equal(#storage.keys("machine_recovery"), 1)
  end)

  test.it("replaces an existing file that a Save As names", function(context)
    local buffer = context.buffer
    buffer:insert(1, 1, "Edited ")
    buffer:save("copy.md", context.copy)
    reply(context.writes[1], { code = "conflict", version = "copy version" })
    test.equal(#context.writes, 2)
    test.equal(context.writes[2].path, context.copy)
    test.equal(context.writes[2].base, "copy version")
    reply(context.writes[2])
    test.not_ok(buffer:is_dirty())
    test.ok(common.path_equals(buffer.abs_filename, context.copy), buffer.abs_filename)

    -- A file that changes again during the Save As stops it, without the conflict choice of the open file.
    buffer:insert(1, 1, "Again ")
    buffer:save("third.md", USERDIR .. PATHSEP .. "third.md")
    reply(context.writes[3], { code = "conflict", version = "third version" })
    reply(context.writes[4], { code = "conflict", version = "changed again" })
    test.equal(#context.writes, 4)
    test.is_nil(context.conflict)
    test.ok(common.path_equals(buffer.abs_filename, context.copy), buffer.abs_filename)
  end)

  test.it("sends no save after the user discards the Buffer", function(context)
    local buffer = context.buffer
    buffer:insert(1, 1, "A ")
    buffer:save()
    buffer:insert(1, 1, "B ")
    buffer:save()
    buffer:on_close()
    reply(context.writes[1])
    test.equal(#context.writes, 1)
  end)

  test.it("saves later edits to the Save As file, not to the file it came from", function(context)
    local buffer = context.buffer
    buffer:insert(1, 1, "A ")
    buffer:save("copy.md", context.copy)
    buffer:insert(1, 1, "B ")
    buffer:save()
    reply(context.writes[1])
    test.equal(#context.writes, 2)
    test.equal(context.writes[2].path, context.copy)
    reply(context.writes[2])
    test.ok(common.path_equals(buffer.abs_filename, context.copy), buffer.abs_filename)
    test.not_ok(buffer:is_dirty())
  end)

  test.it("keeps a closed Buffer and its record while a save that looks undone waits", function(context)
    local buffer = context.buffer
    core.buffer_registry:retain(buffer, context)
    buffer:insert(1, 1, "A ")
    buffer:save()
    buffer:undo()
    test.not_ok(buffer:is_dirty())
    -- The last View closes. The Machine can still write A.
    core.buffer_registry:release(buffer, context)
    core.buffer_registry:collect()
    coroutine.yield(1)
    test.not_ok(buffer.machine_closed)
    test.equal(#storage.keys("machine_recovery"), 1)
    reply(context.writes[1])
    test.ok(buffer:is_dirty())
  end)

  test.it("sends a Save As again when the Machine did not get it", function(context)
    local buffer = context.buffer
    core.buffer_registry:retain(buffer, context)
    -- The Machine restarted, so it does not know the save. Its files have the versions before the save.
    fs.save_result = function(_, done) done({ code = "unknown_save" }) end
    fs.read = function(path, done)
      if common.path_equals(path, context.copy) then return done({ code = "not_found" }) end
      done(nil, "Original\n", machine.content_version("Original\n"))
    end
    buffer:save("copy.md", context.copy)
    reply(context.writes[1], { code = "disconnected" })
    fs.reconnected()
    test.equal(#context.writes, 2)
    test.equal(context.writes[2].path, context.copy)
    reply(context.writes[2])
    test.ok(common.path_equals(buffer.abs_filename, context.copy), buffer.abs_filename)

    -- A Save As that waits behind a lost save also goes out.
    buffer:insert(1, 1, "A ")
    buffer:save()
    buffer:save("third.md", USERDIR .. PATHSEP .. "third.md")
    local saved = context.writes[2].bytes
    fs.read = function(_, done) done(nil, saved, machine.content_version(saved)) end
    reply(context.writes[3], { code = "disconnected" })
    fs.reconnected()
    test.equal(#context.writes, 4)
    test.equal(context.writes[4].path, context.copy)
    reply(context.writes[4])
    test.equal(#context.writes, 5)
    test.ok(common.path_equals(context.writes[5].path, USERDIR .. PATHSEP .. "third.md"))
  end)

  test.it("leaves the old file's conflict behind after a Save As", function(context)
    local buffer = context.buffer
    buffer:insert(1, 1, "A ")
    buffer:save()
    reply(context.writes[1], { code = "conflict", version = "changed on the Machine" })
    test.ok(context.conflict)
    buffer:save("copy.md", context.copy)
    reply(context.writes[2])
    test.is_nil(buffer.machine_conflict)
    buffer:insert(1, 1, "B ")
    buffer:save()
    test.equal(context.writes[3].base, machine.content_version(context.writes[2].bytes))
  end)

  test.it("sends a save that waits, also when the first save leaves the text clean", function(context)
    local buffer = context.buffer
    buffer:insert(1, 1, "A ")
    buffer:save()
    -- An encoding or line ending change does not change the text.
    buffer.crlf = not buffer.crlf
    buffer:save()
    reply(context.writes[1])
    test.equal(#context.writes, 2)
    test.not_equal(context.writes[1].bytes, context.writes[2].bytes)
  end)

  test.it("refuses a file larger than the Machine takes, without a request", function(context)
    local buffer = context.buffer
    fs.write = context.write
    local requests = 0
    fs.machine.request = function(_, _, _, _, done)
      requests = requests + 1
      done({ code = "disconnected" })
    end
    buffer:insert(1, 1, string.rep("x", 17 * 1024 * 1024))
    buffer:save()
    test.equal(requests, 0)
    test.is_nil(buffer.machine_save)
    test.ok(buffer:is_dirty())
  end)

  test.it("keeps the file of a Save As that waits for another save", function(context)
    local buffer = context.buffer
    buffer:insert(1, 1, "A ")
    buffer:save()
    buffer:save("copy.md", context.copy)
    reply(context.writes[1])
    test.equal(#context.writes, 2)
    test.equal(context.writes[2].path, context.copy)
    reply(context.writes[2])
    test.ok(common.path_equals(buffer.abs_filename, context.copy), buffer.abs_filename)
  end)
end)
