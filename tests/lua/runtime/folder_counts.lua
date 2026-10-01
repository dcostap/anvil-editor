local common = require "core.common"
local test = require "core.test"
local counts = require "plugins.folder_counts"

test.describe("Folder counts", function()
  test.it("keeps the previous count visible until the updated count is ready", function(context)
    local path = common.normalize_path(USERDIR .. PATHSEP .. "count-fixture-" .. system.get_time())
    local modified, total = 1, 2
    local get_info, list_info = system.get_file_info, system.list_dir_info
    context.restore = function()
      system.get_file_info, system.list_dir_info = get_info, list_info
    end
    system.get_file_info = function(candidate, ...)
      if candidate == path then return { type = "dir", modified = modified } end
      return get_info(candidate, ...)
    end
    system.list_dir_info = function(candidate, ...)
      if candidate ~= path then return list_info(candidate, ...) end
      local entries = {}
      for i = 1, total do
        entries[i] = { name = "file-" .. i, type = "file", modified = modified }
      end
      return entries
    end

    local function wait_for_count(expected)
      local deadline = system.get_time() + 2
      repeat
        local result, pending = counts.get(path, modified, true)
        if result and result.count == expected and not pending then return result end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      test.ok(false, "The folder count did not complete")
    end

    test.equal(wait_for_count(2).count, 2)
    modified, total = 2, 3
    local previous, pending = counts.get(path, modified, true)
    test.not_nil(previous, "A pending update must not remove the previous count")
    test.equal(previous.count, 2)
    test.ok(pending)
    test.equal(wait_for_count(3).count, 3)
  end)

  test.after_each(function(context)
    if context.restore then context.restore() end
  end)
end)
