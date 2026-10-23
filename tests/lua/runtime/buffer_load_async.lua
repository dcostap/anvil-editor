local test = require "core.test"
local Buffer = require "core.buffer"
local common = require "core.common"

local function wait_for(predicate)
  local deadline = system.get_time() + 30
  repeat
    if predicate() then return end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  test.ok(predicate(), "background load did not finish")
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text)); assert(file:close())
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local text = assert(file:read("*a")); assert(file:close())
  return text
end

test.describe("Background Buffer loading", function()
  test.before_each(function(context)
    context.root = USERDIR .. PATHSEP .. "load-async-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    context.path = context.root .. PATHSEP .. "source.txt"
    context.buffer = Buffer("source.txt", context.path, true)
    context.buffer.disable_language_services = true
    context.buffer.disable_treesitter = true
  end)

  test.after_each(function(context)
    context.buffer:on_close()
    test.ok(test.remove_tree(context.root))
  end)

  test.it("publishes complete decoded text and rejects edits and saves while loading", function(context)
    local source = "\239\187\191one\r\ntwo\r\n"
    write(context.path, source)
    local buffer = context.buffer
    local finished, success, failure
    test.ok(buffer:load_async(context.path, function(ok, err)
      finished, success, failure = true, ok, err
    end))
    test.ok(buffer:is_loading())
    test.same(buffer.lines, { "\n" })
    local edit = buffer:text_input("not allowed")
    test.ok(edit.rejected)
    test.not_ok(pcall(buffer.save, buffer))
    test.equal(read(context.path), source, "a pending load overwrote its source")
    wait_for(function() return finished end)
    test.ok(success, failure)
    test.not_ok(buffer:is_loading())
    test.same(buffer.lines, { "one\n", "two\n" })
    test.ok(buffer.crlf)
    test.equal(buffer.bom, "\239\187\191")
    test.not_ok(buffer:is_dirty())
  end)

  test.it("retains old text after a read failure", function(context)
    local buffer = context.buffer
    buffer:text_input("unsaved text")
    local finished, success
    test.ok(buffer:load_async(context.path, function(ok) finished, success = true, ok end))
    wait_for(function() return finished end)
    test.not_ok(success)
    test.equal(table.concat(buffer.lines), "unsaved text\n")
    test.not_ok(pcall(buffer.save, buffer), "a failed load must not create an empty source")
    test.not_ok(system.get_file_info(context.path))
  end)

  test.it("does not publish a cancelled load", function(context)
    write(context.path, string.rep("loaded line\n", 20000))
    local buffer = context.buffer
    buffer:text_input("keep this")
    local change_id = buffer:get_change_id()
    local finished, success
    test.ok(buffer:load_async(context.path, function(ok) finished, success = true, ok end))
    test.ok(pcall(buffer.undo, buffer), "Undo must leave a loading Buffer unchanged")
    test.equal(buffer:get_change_id(), change_id)
    buffer:cancel_load()
    wait_for(function() return finished end)
    test.not_ok(success)
    test.equal(table.concat(buffer.lines), "keep this\n")
    test.not_ok(buffer:is_loading())
  end)

  test.it("does not replace a newer snapshot with an older load", function(context)
    write(context.path, string.rep("old disk text\n", 20000))
    local buffer = context.buffer
    local finished, success
    test.ok(buffer:load_async(context.path, function(ok) finished, success = true, ok end))
    buffer:replace_snapshot("new source\n")
    wait_for(function() return finished end)
    test.not_ok(success)
    test.same(buffer.lines, { "new source\n" })
  end)

  test.it("cannot save placeholder text after the file identity changes during loading", function(context)
    write(context.path, "original file\n")
    local target = context.root .. PATHSEP .. "other.txt"
    write(target, "keep other file\n")
    local buffer, finished, success = context.buffer
    test.ok(buffer:load_async(context.path, function(ok) finished, success = true, ok end))
    buffer:set_filename("other.txt", target)
    wait_for(function() return finished end)
    test.not_ok(success)
    test.not_ok(pcall(buffer.save, buffer))
    test.equal(read(target), "keep other file\n")
  end)

  test.it("decodes UTF-16 and retains its save encoding", function(context)
    write(context.path, "\254\255\0o\0n\0e\0\r\0\n")
    local buffer, finished, success = context.buffer
    test.ok(buffer:load_async(context.path, function(ok) finished, success = true, ok end))
    wait_for(function() return finished end)
    test.ok(success)
    test.same(buffer.lines, { "one\n" })
    test.equal(buffer.encoding, "UTF-16BE")
    test.equal(buffer.bom, "\254\255")
    test.ok(buffer.crlf)
    buffer:save()
    test.equal(read(context.path), "\254\255\0o\0n\0e\0\r\0\n")
  end)

  test.it("publishes one complete source while retaining invalid bytes and display text", function(context)
    local source = string.rep("line with enough text for transfer\n", 50000) .. "broken\255\n"
    write(context.path, source)
    local buffer, finished, success = context.buffer
    buffer.encoding = "UTF-8"
    local observed = {}
    buffer:add_text_change_listener("load-test", {
      after_change = function(current) observed[#observed + 1] = table.concat(current.lines) end,
    })
    test.ok(buffer:load_async(context.path, function(ok) finished, success = true, ok end))
    wait_for(function() return finished end)
    test.ok(success)
    test.same(observed, { source })
    test.ok(buffer.binary)
    test.ok(string.uisvalid(buffer:get_utf8_line(50001)))
    test.equal(buffer:get_utf8_line(50001):sub(1, 6), "broken")
    buffer:save()
    test.equal(read(context.path), source)
  end)
end)
