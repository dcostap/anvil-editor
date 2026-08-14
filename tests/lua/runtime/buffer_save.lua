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
end)
