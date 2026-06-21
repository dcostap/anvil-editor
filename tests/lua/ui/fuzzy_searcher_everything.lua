local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local helpers = fuzzy_searcher._test

test.describe("Fuzzy Searcher Everything project search", function()
  test.it("asks Everything for project-like folder names instead of every descendant path", function()
    local params = helpers.everything_project_search_params("sm64", 80, 0)

    test.equal(params.search, "folder: sm64")
    test.equal(params.sort, "path")
    test.equal(params.path, nil)
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
