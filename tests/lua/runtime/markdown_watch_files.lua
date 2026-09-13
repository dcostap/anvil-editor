local common = require "core.common"
local test = require "core.test"
local vault_index = require "core.markdown.vault_index"
local project_files = require "core.project_files"

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

test.describe("Markdown file changes", function()
  test.after_each(function(context)
    if context.cleanup then context.cleanup() end
  end)

  test.it("reconciles note changes without UI filesystem checks", function(context)
    local root = common.normalize_path(USERDIR .. PATHSEP .. "markdown-worker-" .. system.get_process_id())
    assert(common.mkdirp(root))
    local path = root .. PATHSEP .. "Note.md"
    write(path, "# Before\n")
    local index = vault_index.get_index(root):rebuild("test")
    test.equal(index.status, "ready", index.reason)
    local get_info = system.get_file_info
    context.cleanup = function()
      system.get_file_info = get_info
      index:stop_watcher()
      project_files.invalidate(root)
      common.rm(root, true)
    end
    system.get_file_info = function(name, ...)
      assert(not common.path_equals(name, root) and not common.path_belongs_to(name, root),
        "Markdown performed filesystem I/O on the UI thread: " .. name)
      return get_info(name, ...)
    end
    write(path, "# Changed heading\n")
    test.ok(index:reconcile_dir(path, "test-change"))
    test.equal(index.status, "ready", index.reason)
    test.equal(index:note(path).headings[1].text, "Changed heading")
    assert(os.remove(path))
    index:remove_path(path)
    test.ok(index:reconcile_dir(path, "test-delete"))
    test.equal(index:note_count(), 0)
    write(path, "# Restored\n")
    test.ok(index:reconcile_dir(path, "test-restore"))
    test.equal(index:note_count(), 1)
    test.equal(index:note(path).headings[1].text, "Restored")
  end)
end)
