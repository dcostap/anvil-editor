local core = require "core"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local helpers = fuzzy_searcher._test

test.describe("Fuzzy Searcher Everything search", function()
  test.it("asks Everything for project-like folders by name and path", function()
    local params = helpers.everything_project_search_params("sm64", 80, 0)

    test.equal(params.search, "folder: sm64")
    test.equal(params.sort, "path")
    test.equal(params.path, "1")
  end)

  test.it("asks Everything for file names and paths in whole-PC file mode", function()
    local params = helpers.everything_file_search_params("anvil lua", 80, 0)

    test.equal(params.search, "file: anvil lua")
    test.equal(params.sort, "path")
    test.equal(params.path, "1")
  end)

  test.it("preserves explicit Everything file filters", function()
    local params = helpers.everything_file_search_params("file: ext:lua anvil", 80, 0)

    test.equal(params.search, "file: ext:lua anvil")
  end)

  test.it("detects Everything folder results that duplicate recent projects", function()
    local previous = core.recent_projects
    core.recent_projects = { "C:\\Projects\\anvil-editor" }

    local recent_keys = helpers.recent_project_key_set()
    local duplicate = helpers.everything_result_from_item({ type = "folder", path = "C:\\Projects", name = "anvil-editor" }, "anvil")
    local different = helpers.everything_result_from_item({ type = "folder", path = "C:\\Projects", name = "other" }, "anvil")
    local file = helpers.everything_result_from_item({ type = "file", path = "C:\\Projects", name = "anvil-editor" }, "anvil")

    core.recent_projects = previous

    test.equal(helpers.everything_project_result_is_recent_duplicate(duplicate, recent_keys), true)
    test.equal(helpers.everything_project_result_is_recent_duplicate(different, recent_keys), false)
    test.equal(helpers.everything_project_result_is_recent_duplicate(file, recent_keys), false)
  end)

  test.it("orders loaded Everything folders by shallow path depth", function()
    local results = {
      { label = "C:\\Projects\\decomps\\sm64\\levels\\bbh", path = "C:\\Projects\\decomps\\sm64\\levels\\bbh", is_folder = true },
      { label = "C:\\Projects\\decomps\\sm64", path = "C:\\Projects\\decomps\\sm64", is_folder = true },
      { label = "C:\\Users\\Darius\\AppData\\Local\\JetBrains\\CLion2025.1\\projects\\sm64.cc376d61", path = "C:\\Users\\Darius\\AppData\\Local\\JetBrains\\CLion2025.1\\projects\\sm64.cc376d61", is_folder = true },
    }

    helpers.sort_everything_project_results(results)

    test.equal(results[1].path, "C:\\Projects\\decomps\\sm64")
    test.equal(results[2].path, "C:\\Projects\\decomps\\sm64\\levels\\bbh")
  end)
end)
