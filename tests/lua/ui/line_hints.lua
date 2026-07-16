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

local function hint_has_folder_count(hint, count)
  return tostring(hint or ""):match("^%s*" .. tostring(count) .. "%s*·") ~= nil
end

local function wait_for_folder_count(filetree, line, count, timeout)
  local deadline = system.get_time() + (timeout or 2)
  local hint
  repeat
    hint = filetree:get_line_hint(line).text
    if hint_has_folder_count(hint, count) then
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
    if context.saved_line_hint_state then
      local state = context.saved_line_hint_state
      state.filetree.line_hint_cache = state.line_hint_cache
      state.filetree.line_hint_reference_time = state.line_hint_reference_time
      state.filetree.get_folder_hint_counts = state.get_folder_hint_counts
      os.time = state.os_time
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

    local folder_c = temp_root .. PATHSEP .. "folder-c"
    test.ok(common.mkdirp(folder_c))
    write_file(folder_c .. PATHSEP .. "one.txt", "one")
    write_file(folder_c .. PATHSEP .. "two.txt", "two")

    local folder_d = temp_root .. PATHSEP .. "folder-d"
    test.ok(common.mkdirp(folder_d))

    write_file(temp_root .. PATHSEP .. "file.bin", string.rep("x", 23 * 1024))

    local filetree = require "plugins.filetree"
    context.filetree = filetree
    context.filetree_previous_dir = filetree.current_dir
    filetree.current_dir = temp_root
    filetree:refresh(false, false)

    local folder_a_line = find_filetree_line(filetree, "folder-a/")
    local folder_b_line = find_filetree_line(filetree, "folder-b/")
    local folder_c_line = find_filetree_line(filetree, "folder-c/")
    local folder_d_line = find_filetree_line(filetree, "folder-d/")
    local file_line = find_filetree_line(filetree, "file.bin")
    test.not_nil(folder_a_line, "expected first folder row in File Tree")
    test.not_nil(folder_b_line, "expected second folder row in File Tree")
    test.not_nil(folder_c_line, "expected folder-only-file row in File Tree")
    test.not_nil(folder_d_line, "expected empty folder row in File Tree")
    test.not_nil(file_line, "expected file row in File Tree")

    local initial_folder_a_hint = filetree:get_line_hint(folder_a_line).text
    local initial_folder_b_hint = filetree:get_line_hint(folder_b_line).text
    local file_hint = filetree:get_line_hint(file_line).text

    test.ok(initial_folder_a_hint:find("…", 1, true), initial_folder_a_hint)
    test.ok(initial_folder_a_hint:find("·", 1, true), initial_folder_a_hint)
    test.ok(initial_folder_b_hint:find("…", 1, true), initial_folder_b_hint)
    test.ok(initial_folder_b_hint:find("·", 1, true), initial_folder_b_hint)
    test.ok(initial_folder_a_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), initial_folder_a_hint)

    local folder_a_hint = wait_for_folder_count(filetree, folder_a_line, 3)
    local folder_b_hint = wait_for_folder_count(filetree, folder_b_line, 3)
    test.ok(hint_has_folder_count(folder_a_hint, 3), folder_a_hint)
    test.ok(folder_a_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), folder_a_hint)
    test.ok(hint_has_folder_count(folder_b_hint, 3), folder_b_hint)

    local folder_c_hint = wait_for_folder_count(filetree, folder_c_line, 2)
    local folder_d_hint = wait_for_folder_count(filetree, folder_d_line, 0)
    test.ok(hint_has_folder_count(folder_c_hint, 2), folder_c_hint)
    test.ok(hint_has_folder_count(folder_d_hint, 0), folder_d_hint)

    test.ok(file_hint:find("23 K", 1, true), file_hint)
    test.ok(file_hint:match("%d%d%d%d %a%a%a%s+%d+ %d%d:%d%d"), file_hint)
  end)

  test.it("shows a fixed prose age after the modified date", function(context)
    local filetree = require "plugins.filetree"
    context.saved_line_hint_state = {
      filetree = filetree,
      line_hint_cache = filetree.line_hint_cache,
      line_hint_reference_time = filetree.line_hint_reference_time,
      get_folder_hint_counts = filetree.get_folder_hint_counts,
      os_time = os.time,
    }
    local now = os.time()
    filetree.line_hint_reference_time = now
    filetree.line_hint_cache = {}

    local cases = {
      { 22 * 60, "22 mins ago" },
      { 35 * 60, "35 mins ago" },
      { 60 * 60 + 35 * 60, "1:35 hrs ago" },
      { 10 * 60 * 60 + 35 * 60, "10 hrs ago" },
      { 23 * 60 * 60 + 59 * 60, "23 hrs ago" },
      { 24 * 60 * 60, "1 day ago" },
      { 3 * 24 * 60 * 60, "3 days ago" },
      { 60 * 24 * 60 * 60, "2 mos ago" },
      { 730 * 24 * 60 * 60, "2 yrs ago" },
    }

    for index, case in ipairs(cases) do
      local hint = filetree:format_line_hint_for_path("relative-time-" .. index, {
        type = "file",
        size = 0,
        modified = now - case[1],
      })
      local relative_column = hint:match("· ([^·]*)$")
      test.not_nil(relative_column, hint)
      test.equal(#relative_column, 12)
      test.equal((relative_column:gsub("%s+$", "")), case[2])
    end

    filetree.line_hint_reference_time = nil
    filetree.get_folder_hint_counts = function() return { error = true } end
    os.time = function() return now end
    local info = { type = "dir", modified = now - 35 * 60 }
    local first = filetree:format_line_hint_for_path("relative-time-dir", info)
    os.time = function() return now + 24 * 60 * 60 end
    local second = filetree:format_line_hint_for_path("relative-time-dir", info)

    test.equal(second, first)
    local relative_column = second:match("· ([^·]*)$")
    test.equal(#relative_column, 12)
    test.equal((relative_column:gsub("%s+$", "")), "35 mins ago")
  end)
end)
