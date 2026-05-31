local common = require "core.common"
local core = require "core"
local test = require "core.test"

local function line_without_newline(line)
  line = line or ""
  return line:sub(-1) == "\n" and line:sub(1, -2) or line
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content)
  file:close()
end

local function find_editree_line(view, wanted)
  for i, line in ipairs(view.doc.lines) do
    if line_without_newline(line) == wanted then return i end
  end
end

local function wait_for_folder_counts(editree, line, timeout)
  local deadline = system.get_time() + (timeout or 2)
  local hint
  repeat
    hint = editree:get_line_hint(line).text
    if hint:find("   2 📁", 1, true) and hint:find("   1 📄", 1, true) then
      return hint
    end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  return hint
end

test.describe("Editree Line Hints", function()
  test.after_each(function(context)
    if context.editree and context.editree_previous_dir then
      context.editree.current_dir = context.editree_previous_dir
      context.editree:refresh(false, false)
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("show file size/date and async direct folder counts/date", function(context)
    local temp_root = core.root_project().path
      .. PATHSEP .. "editree-line-hints-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root

    local folder = temp_root .. PATHSEP .. "folder"
    test.ok(common.mkdirp(folder .. PATHSEP .. "subdir-a"))
    test.ok(common.mkdirp(folder .. PATHSEP .. "subdir-b"))
    write_file(folder .. PATHSEP .. "child.txt", "child")
    write_file(temp_root .. PATHSEP .. "file.bin", string.rep("x", 23 * 1024))

    local editree = require "plugins.editree"
    context.editree = editree
    context.editree_previous_dir = editree.current_dir
    editree.current_dir = temp_root
    editree:refresh(false, false)

    local folder_line = find_editree_line(editree, "folder/")
    local file_line = find_editree_line(editree, "file.bin")
    test.not_nil(folder_line, "expected folder row in Editree")
    test.not_nil(file_line, "expected file row in Editree")

    local initial_folder_hint = editree:get_line_hint(folder_line).text
    local file_hint = editree:get_line_hint(file_line).text

    test.ok(initial_folder_hint:find("   … 📁", 1, true), initial_folder_hint)
    test.ok(initial_folder_hint:find("   … 📄", 1, true), initial_folder_hint)
    test.ok(initial_folder_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), initial_folder_hint)

    local folder_hint = wait_for_folder_counts(editree, folder_line)
    test.ok(folder_hint:find("   2 📁", 1, true), folder_hint)
    test.ok(folder_hint:find("   1 📄", 1, true), folder_hint)
    test.ok(folder_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), folder_hint)

    test.ok(file_hint:find(" 23 K", 1, true), file_hint)
    test.ok(file_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), file_hint)
  end)
end)
