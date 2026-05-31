local common = require "core.common"
local Doc = require "core.doc"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_lines(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  test.not_nil(file, err)
  local content = file:read("*a")
  file:close()
  return content
end

test.describe("core.doc save", function()
  test.before_each(function(context)
    context.temp_root = USERDIR
      .. PATHSEP .. "doc-save-tests-"
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
    local doc = Doc()
    write_lines(doc, "hello from anvil")

    local abs = join_path(context.temp_root, "missing", "nested", "file.txt")
    doc:save("missing" .. PATHSEP .. "nested" .. PATHSEP .. "file.txt", abs)

    local parent_info = system.get_file_info(join_path(context.temp_root, "missing", "nested"))
    test.not_nil(parent_info)
    test.equal(parent_info.type, "dir")
    test.equal(read_file(abs), "hello from anvil\n")
    test.equal(doc.abs_filename, abs)
    test.equal(doc:is_dirty(), false)
  end)

  test.test("reports a clear error when a parent path is a file", function(context)
    local blocker = join_path(context.temp_root, "not-a-directory")
    local file = io.open(blocker, "wb")
    test.not_nil(file)
    file:write("blocker")
    file:close()

    local doc = Doc()
    write_lines(doc, "content")
    local ok, err = pcall(doc.save, doc, "not-a-directory" .. PATHSEP .. "file.txt", blocker .. PATHSEP .. "file.txt")

    test.equal(ok, false)
    test.ok(tostring(err):find("parent path is not a directory", 1, true), tostring(err))
  end)
end)
