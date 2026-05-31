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

local function find_filetree_line(view, wanted)
  for i, line in ipairs(view.doc.lines) do
    if line_without_newline(line) == wanted then return i end
  end
end

local function wait_for_folder_counts(filetree, line, folders_text, files_text, timeout)
  local deadline = system.get_time() + (timeout or 2)
  local hint
  repeat
    hint = filetree:get_line_hint(line).text
    if hint:find(folders_text, 1, true) and hint:find(files_text, 1, true) then
      return hint
    end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  return hint
end

test.describe("File Tree Line Hints", function()
  test.after_each(function(context)
    if context.filetree and context.filetree_previous_dir then
      context.filetree.current_dir = context.filetree_previous_dir
      context.filetree:refresh(false, false)
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("show file size/date and async direct folder counts/date", function(context)
    local temp_root = core.root_project().path
      .. PATHSEP .. "filetree-line-hints-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.temp_root = temp_root

    local folder_a = temp_root .. PATHSEP .. "folder-a"
    test.ok(common.mkdirp(folder_a .. PATHSEP .. "subdir-a"))
    test.ok(common.mkdirp(folder_a .. PATHSEP .. "subdir-b"))
    write_file(folder_a .. PATHSEP .. "child.txt", "child")

    local folder_b = temp_root .. PATHSEP .. "folder-b"
    test.ok(common.mkdirp(folder_b .. PATHSEP .. "nested"))
    write_file(folder_b .. PATHSEP .. "one.txt", "one")
    write_file(folder_b .. PATHSEP .. "two.txt", "two")

    write_file(temp_root .. PATHSEP .. "file.bin", string.rep("x", 23 * 1024))

    local filetree = require "plugins.filetree"
    context.filetree = filetree
    context.filetree_previous_dir = filetree.current_dir
    filetree.current_dir = temp_root
    filetree:refresh(false, false)

    local folder_a_line = find_filetree_line(filetree, "folder-a/")
    local folder_b_line = find_filetree_line(filetree, "folder-b/")
    local file_line = find_filetree_line(filetree, "file.bin")
    test.not_nil(folder_a_line, "expected first folder row in File Tree")
    test.not_nil(folder_b_line, "expected second folder row in File Tree")
    test.not_nil(file_line, "expected file row in File Tree")

    local initial_folder_a_hint = filetree:get_line_hint(folder_a_line).text
    local initial_folder_b_hint = filetree:get_line_hint(folder_b_line).text
    local file_hint = filetree:get_line_hint(file_line).text

    test.ok(initial_folder_a_hint:find("   … 📁", 1, true), initial_folder_a_hint)
    test.ok(initial_folder_a_hint:find("   … 📄", 1, true), initial_folder_a_hint)
    test.ok(initial_folder_b_hint:find("   … 📁", 1, true), initial_folder_b_hint)
    test.ok(initial_folder_b_hint:find("   … 📄", 1, true), initial_folder_b_hint)
    test.ok(initial_folder_a_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), initial_folder_a_hint)

    local folder_a_hint = wait_for_folder_counts(filetree, folder_a_line, "   2 📁", "   1 📄")
    local folder_b_hint = wait_for_folder_counts(filetree, folder_b_line, "   1 📁", "   2 📄")
    test.ok(folder_a_hint:find("   2 📁", 1, true), folder_a_hint)
    test.ok(folder_a_hint:find("   1 📄", 1, true), folder_a_hint)
    test.ok(folder_a_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), folder_a_hint)
    test.ok(folder_b_hint:find("   1 📁", 1, true), folder_b_hint)
    test.ok(folder_b_hint:find("   2 📄", 1, true), folder_b_hint)

    test.ok(file_hint:find(" 23 K", 1, true), file_hint)
    test.ok(file_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), file_hint)
  end)
end)
