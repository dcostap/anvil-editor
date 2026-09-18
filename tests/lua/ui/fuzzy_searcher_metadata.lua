local test = require "core.test"
local common = require "core.common"

local folder_counts = require "plugins.folder_counts"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local git_status = require "plugins.file_git_status"
local helpers = fuzzy_searcher._test

test.describe("Fuzzy Searcher result metadata", function()
  test.before_each(function(context)
    context.get_file_info = system.get_file_info
    context.git_lookup = git_status.lookup
    context.folder_get = folder_counts.get
    context.folder_generation = folder_counts.generation
  end)

  test.after_each(function(context)
    system.get_file_info = context.get_file_info
    git_status.lookup = context.git_lookup
    folder_counts.get = context.folder_get
    folder_counts.generation = context.folder_generation
  end)

  test.it("reuses unchanged folder metadata across redraws", function(context)
    local path = USERDIR .. PATHSEP .. "metadata-folder"
    local stat_calls, git_calls, count_calls = 0, 0, 0

    system.get_file_info = function(candidate, ...)
      if common.path_equals(candidate, path) then
        stat_calls = stat_calls + 1
        return { type = "dir", size = 0, modified = 123 }
      end
      return context.get_file_info(candidate, ...)
    end
    git_status.lookup = function(service, candidate, is_directory)
      if common.path_equals(candidate, path) then
        git_calls = git_calls + 1
        test.ok(is_directory)
        return nil
      end
      return context.git_lookup(service, candidate, is_directory)
    end
    folder_counts.get = function(candidate, modified, show_hidden)
      if common.path_equals(candidate, path) then
        count_calls = count_calls + 1
        test.equal(modified, 123)
        test.not_ok(show_hidden)
        return nil, true
      end
      return context.folder_get(candidate, modified, show_hidden)
    end

    local result = {
      kind = "folder", is_folder = true,
      file = "metadata-folder", label = "metadata-folder", abs_path = path,
    }
    helpers.file_metadata_parts(result)
    helpers.file_metadata_parts(result)

    test.equal(stat_calls, 1)
    test.equal(git_calls, 1)
    test.equal(count_calls, 1)

    folder_counts.generation = folder_counts.generation + 1
    helpers.file_metadata_parts(result)
    test.equal(stat_calls, 1)
    test.equal(git_calls, 2)
    test.equal(count_calls, 2)
  end)
end)
