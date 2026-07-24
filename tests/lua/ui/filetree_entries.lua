local common = require "core.common"
local core = require "core"
local test = require "core.test"
local filetree = require "plugins.filetree"
local project_paths = require "core.project_paths"

local function write_file(path, text)
  local handle, err = io.open(path, "wb")
  test.not_nil(handle, err)
  handle:write(text or "")
  handle:close()
end

local function setup_tree(context)
  local root = core.root_project().path .. PATHSEP .. "filetree-entry-tests-"
    .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
  local folder = root .. PATHSEP .. "folder"
  test.ok(common.mkdirp(folder))
  write_file(root .. PATHSEP .. "root.txt", "root")
  write_file(folder .. PATHSEP .. "child.txt", "child")
  context.previous_dir = filetree.current_dir
  context.temp_root = root
  filetree.current_dir = root
  filetree:refresh(false, false)
  return root
end

local function find_entry(name)
  for _, entry in ipairs(filetree:build_entries(false)) do
    if entry.text == name then return entry end
  end
end

test.describe("File Tree entry snapshots", function()
  test.after_each(function(context)
    if context.original_resolve then
      project_paths.resolve = context.original_resolve
    end
    if context.previous_dir then
      filetree.current_dir = context.previous_dir
      filetree:refresh(false, false)
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("reuses an unchanged resolved entry snapshot", function(context)
    context.original_resolve = project_paths.resolve
    local resolve_calls = 0
    project_paths.resolve = function(...)
      resolve_calls = resolve_calls + 1
      return context.original_resolve(...)
    end

    filetree:snapshot_lines()
    local first_entries = filetree:build_entries(false)
    local first_build_calls = resolve_calls
    test.ok(#first_entries > 0, "expected the File Tree to contain entries")
    test.ok(first_build_calls > 0, "expected the first snapshot to resolve its paths")

    local second_entries = filetree:build_entries(false)
    test.equal(#second_entries, #first_entries)
    test.equal(resolve_calls, first_build_calls,
      "an unchanged File Tree should not resolve every entry again")
  end)

  test.it("invalidates resolved entries after an editable tree change", function(context)
    local root = setup_tree(context)
    local original = find_entry("root.txt")
    test.not_nil(original)

    filetree:with_selection_state(function()
      filetree.doc:insert(original.line, 1, "renamed-")
    end)

    local renamed = filetree:entry_for_line(original.line)
    test.ok(common.path_equals(renamed.abs, root .. PATHSEP .. "renamed-root.txt"))
  end)

  test.it("invalidates resolved entries when a folder expands", function(context)
    local root = setup_tree(context)
    local folder = find_entry("folder")
    test.not_nil(folder)

    filetree:expand_folder(folder.line, folder, false)

    local child = find_entry("child.txt")
    test.not_nil(child)
    test.ok(common.path_equals(child.abs, root .. PATHSEP .. "folder" .. PATHSEP .. "child.txt"))
  end)
end)
