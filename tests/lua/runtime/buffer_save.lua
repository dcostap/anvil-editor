local common = require "core.common"
local Buffer = require "core.buffer"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_lines(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  if #buffer.lines == 0 then buffer.lines[1] = "\n" end
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  test.not_nil(file, err)
  local content = file:read("*a")
  file:close()
  return content
end

test.describe("core.buffer save", function()
  test.before_each(function(context)
    context.temp_root = USERDIR
      .. PATHSEP .. "buffer-save-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(context.temp_root)
    test.ok(ok, err)
  end)

  test.after_each(function(context)
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("creates missing parent directories before saving a file", function(context)
    local buffer = Buffer()
    write_lines(buffer, "hello from anvil")

    local abs = join_path(context.temp_root, "missing", "nested", "file.txt")
    buffer:save("missing" .. PATHSEP .. "nested" .. PATHSEP .. "file.txt", abs)

    local parent_info = system.get_file_info(join_path(context.temp_root, "missing", "nested"))
    test.not_nil(parent_info)
    test.equal(parent_info.type, "dir")
    test.equal(read_file(abs), "hello from anvil\n")
    test.equal(buffer.abs_filename, abs)
    test.equal(buffer:is_dirty(), false)
  end)

  test.test("reports a clear error when a parent path is a file", function(context)
    local blocker = join_path(context.temp_root, "not-a-directory")
    local file = io.open(blocker, "wb")
    test.not_nil(file)
    file:write("blocker")
    file:close()

    local buffer = Buffer()
    write_lines(buffer, "content")
    local ok, err = pcall(buffer.save, buffer, "not-a-directory" .. PATHSEP .. "file.txt", blocker .. PATHSEP .. "file.txt")

    test.equal(ok, false)
    test.ok(tostring(err):find("parent path is not a directory", 1, true), tostring(err))
  end)

  test.test("does not replace an unexpected atomic-write target", function(context)
    local source = join_path(context.temp_root, "unexpected-target.tmp")
    local target = join_path(context.temp_root, "unexpected-target.txt")
    local file = assert(io.open(source, "wb"))
    file:write("new content\n")
    file:close()
    file = assert(io.open(target, "wb"))
    file:write("external content\n")
    file:close()

    local replaced = system.atomic_replace_file(source, target, false)

    test.not_ok(replaced)
    test.equal(read_file(target), "external content\n")
    test.equal(read_file(source), "new content\n")
  end)

  test.test("does not replace a target with an unexpected file identity", function(context)
    local source = join_path(context.temp_root, "unexpected-identity.tmp")
    local target = join_path(context.temp_root, "unexpected-identity.txt")
    local file = assert(io.open(source, "wb"))
    file:write("new content\n")
    file:close()
    file = assert(io.open(target, "wb"))
    file:write("external content\n")
    file:close()

    local replaced, _, reason = system.atomic_replace_file(
      source, target, "unexpected-file-id"
    )

    test.not_ok(replaced)
    test.equal(reason, "target-changed")
    test.equal(read_file(target), "external content\n")
    test.equal(read_file(source), "new content\n")
  end)

  test.test("falls back safely when atomic replacement is unavailable", function(context)
    local abs = join_path(context.temp_root, "atomic-fallback.txt")
    local file = assert(io.open(abs, "wb"))
    file:write("old content\n")
    file:close()

    local buffer = Buffer(abs, abs, false)
    buffer:insert(1, 1, "new ")
    local atomic_replace_file = system.atomic_replace_file
    system.atomic_replace_file = function(source, target, expected_existing)
      if target == abs then return false, "simulated unsupported atomic replacement" end
      return atomic_replace_file(source, target, expected_existing)
    end
    local ok, err = pcall(buffer.save, buffer)
    system.atomic_replace_file = atomic_replace_file

    test.ok(ok, err)
    test.equal(read_file(abs), "new old content\n")
    test.not_ok(buffer:is_dirty())
  end)

  test.test("does not restore a backup before fallback writing starts", function(context)
    local abs = join_path(context.temp_root, "atomic-fallback-conflict.txt")
    local file = assert(io.open(abs, "wb"))
    file:write("old content\n")
    file:close()

    local buffer = Buffer(abs, abs, false)
    buffer.deferred_reload = true
    buffer:insert(1, 1, "new ")
    local atomic_replace_file = system.atomic_replace_file
    system.atomic_replace_file = function(source, target, expected_existing)
      if target == abs then return false, "simulated unsupported atomic replacement" end
      local ok, err = atomic_replace_file(source, target, expected_existing)
      if ok and target:find("anvil%-bak$") then
        local external = assert(io.open(abs, "wb"))
        external:write("external content\n")
        external:close()
      end
      return ok, err
    end
    buffer.safe_write_guard = function()
      if read_file(abs) == "external content\n" then return false, "simulated late conflict" end
      return true
    end
    local ok = pcall(buffer.save, buffer)
    system.atomic_replace_file = atomic_replace_file

    test.not_ok(ok)
    test.equal(read_file(abs), "external content\n")
    test.ok(buffer:is_dirty())
  end)

  test.test("preserves file identity when atomic replacement is unsafe", function(context)
    local abs = join_path(context.temp_root, "linked-file.txt")
    local file = assert(io.open(abs, "wb"))
    file:write("old content\n")
    file:close()

    local buffer = Buffer(abs, abs, false)
    buffer:insert(1, 1, "new ")
    local get_file_info = system.get_file_info
    local atomic_replace_file = system.atomic_replace_file
    system.get_file_info = function(path)
      local info, err = get_file_info(path)
      if path == abs and info then info.link_count = 2 end
      return info, err
    end
    system.atomic_replace_file = function(source, target, expected_existing)
      if target == abs then error("atomic replacement must not run for a linked file") end
      return atomic_replace_file(source, target, expected_existing)
    end
    local ok, err = pcall(buffer.save, buffer)
    system.get_file_info = get_file_info
    system.atomic_replace_file = atomic_replace_file

    test.ok(ok, err)
    test.equal(read_file(abs), "new old content\n")
    test.not_ok(buffer:is_dirty())
  end)

  test.test("restores a linked file when an identity-preserving write fails", function(context)
    local abs = join_path(context.temp_root, "linked-write-failure.txt")
    local file = assert(io.open(abs, "wb"))
    file:write("old content\n")
    file:close()

    local buffer = Buffer(abs, abs, false)
    buffer:insert(1, 1, "new ")
    local get_file_info = system.get_file_info
    local sync_file = system.sync_file
    local sync_calls = 0
    system.get_file_info = function(path)
      local info, err = get_file_info(path)
      if path == abs and info then info.link_count = 2 end
      return info, err
    end
    system.sync_file = function(output)
      sync_calls = sync_calls + 1
      if sync_calls == 2 then return false, "simulated target sync failure" end
      return sync_file(output)
    end
    local ok, err = pcall(buffer.save, buffer)
    system.get_file_info = get_file_info
    system.sync_file = sync_file

    test.not_ok(ok)
    test.ok(tostring(err):find("simulated target sync failure", 1, true), tostring(err))
    test.equal(read_file(abs), "old content\n")
    test.ok(buffer:is_dirty())
  end)
end)
