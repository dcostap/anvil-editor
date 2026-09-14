local common = require "core.common"
local core = require "core"
local test = require "core.test"
local FileTreeView = require("plugins.filetree").View

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text or "content")
  file:close()
end

local function find_entry(view, name)
  for _, entry in ipairs(view:build_entries(false)) do
    if entry.text == name then return entry end
  end
  error("Missing entry: " .. name)
end

test.describe("File Tree live edit feedback", function()
  test.before_each(function(context)
    context.root = core.root_project().path .. PATHSEP .. "filetree-feedback-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    assert(common.mkdirp(context.root .. PATHSEP .. "folder"))
    write_file(context.root .. PATHSEP .. "first.txt", "first")
    write_file(context.root .. PATHSEP .. "second.txt", "second")
    write_file(context.root .. PATHSEP .. "folder" .. PATHSEP .. "child.txt")
    context.view = FileTreeView { root = core.root_project().path }
    context.view:change_directory(context.root)
  end)

  test.after_each(function(context)
    if context.get_file_info then system.get_file_info = context.get_file_info end
    if context.view then context.view:on_close() end
    if context.root then assert(common.rm(context.root, true)) end
  end)

  test.it("shows rename feedback without reading the filesystem", function(context)
    local view = context.view
    local entry = find_entry(view, "first.txt")
    view.buffer:insert(entry.line, 1, "renamed-")
    context.get_file_info = system.get_file_info
    system.get_file_info = function()
      error("Live edit feedback must not read the filesystem")
    end

    test.equal(view:get_line_status(entry.line), "modification")
    test.is_nil(view:get_line_hint(entry.line), "a draft path has no disk metadata")
    test.not_nil(view:get_line_render(entry.line), "the edited file keeps its inline icon")
    test.ok(common.path_equals(view:entry_for_line(entry.line).abs,
      context.root .. PATHSEP .. "renamed-first.txt"))
  end)

  test.it("does not attach children of an invalid folder to the previous folder", function(context)
    local view = context.view
    view.buffer:insert(1, 1, "valid/\n../\n\tchild.txt\n")
    test.is_nil(view:entry_for_line(3))
    test.equal(view:get_line_status(2), "invalid")
    test.equal(view:get_line_status(3), "invalid")
  end)

  test.it("updates descendant paths after a folder rename and undo", function(context)
    local view = context.view
    local folder = find_entry(view, "folder")
    view:expand_folder(folder.line, folder, false)
    local child = find_entry(view, "child.txt")
    view.buffer:insert(folder.line, 1, "renamed-")
    test.ok(common.path_equals(view:entry_for_line(child.line).abs,
      context.root .. PATHSEP .. "renamed-folder" .. PATHSEP .. "child.txt"))
    test.equal(view:get_line_status(child.line), "modification")
    view.buffer:undo()
    test.ok(common.path_equals(view:entry_for_line(child.line).abs,
      context.root .. PATHSEP .. "folder" .. PATHSEP .. "child.txt"))
    test.is_nil(view:get_line_status(child.line))
  end)

  test.it("marks all duplicate file targets but permits directory merges", function(context)
    local view = context.view
    view.buffer:insert(1, 1, "duplicate\nduplicate/\nduplicate/\nmerge/\nmerge/\n")
    for line = 1, 3 do test.equal(view:get_line_status(line), "invalid") end
    for line = 4, 5 do test.equal(view:get_line_status(line), "addition") end
  end)

  test.it("keeps invalid child feedback when its folder collapses", function(context)
    local view = context.view
    local folder = find_entry(view, "folder")
    view:expand_folder(folder.line, folder, false)
    local child = find_entry(view, "child.txt")
    view.buffer:insert(child.line, 1, " ")
    test.equal(view:get_line_status(child.line), "invalid")
    view:collapse_folder(folder.line, view:entry_for_line(folder.line))
    test.equal(view:get_line_status(folder.line), "invalid")
    view:expand_folder(folder.line, view:entry_for_line(folder.line), false)
    test.equal(view:get_line_status(child.line), "invalid")
    -- Less than one complete indentation level must stay invalid too.
    view.buffer:remove(child.line, 1, child.line, 2)
    test.equal(view:get_line_status(child.line), "invalid")
    view:collapse_folder(folder.line, view:entry_for_line(folder.line))
    view:expand_folder(folder.line, view:entry_for_line(folder.line), false)
    test.equal(view:get_line_status(child.line), "invalid")
  end)

  test.it("checks current disk conflicts before applying a draft rename", function(context)
    local view = context.view
    local entry = find_entry(view, "first.txt")
    view.buffer:insert(entry.line, 1, "renamed-")
    test.equal(view:get_line_status(entry.line), "modification")
    test.not_nil(view:plan_changes())
    write_file(context.root .. PATHSEP .. "renamed-first.txt", "external change")
    local plan, _, status = view:plan_changes()
    test.is_nil(plan)
    test.equal(status[entry.line], "invalid")
    test.not_nil(system.get_file_info(context.root .. PATHSEP .. "first.txt"))
  end)

  test.it("preserves file contents when applying a rename chain", function(context)
    local view = context.view
    local first, second = find_entry(view, "first.txt"), find_entry(view, "second.txt")
    for _, change in ipairs { { first.line, "second.txt" }, { second.line, "third.txt" } } do
      view.buffer:remove(change[1], 1, change[1], #view.buffer.lines[change[1]])
      view.buffer:insert(change[1], 1, change[2])
    end
    local plan, err = view:plan_changes()
    test.not_nil(plan, err)
    test.ok(view:apply_plan(plan))
    test.is_nil(system.get_file_info(context.root .. PATHSEP .. "first.txt"))
    for name, text in pairs { ["second.txt"] = "first", ["third.txt"] = "second" } do
      local file = assert(io.open(context.root .. PATHSEP .. name, "rb"))
      local actual = file:read("*a")
      file:close()
      test.equal(actual, text)
    end
  end)

  test.it("rejects a cycle from sequential file renames", function(context)
    local view = context.view
    local first, second = find_entry(view, "first.txt"), find_entry(view, "second.txt")
    for _, change in ipairs { { first.line, "second.txt" }, { second.line, "first.txt" } } do
      view.buffer:remove(change[1], 1, change[1], #view.buffer.lines[change[1]])
      view.buffer:insert(change[1], 1, change[2])
      view:get_line_status(change[1])
    end
    local plan, _, _, reasons = view:plan_changes()
    test.is_nil(plan)
    test.match(table.concat(reasons, "\n"), "move cycle", nil, true)
  end)
end)
