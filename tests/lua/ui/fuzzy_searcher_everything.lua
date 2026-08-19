local core = require "core"
local http = require "core.http"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local helpers = fuzzy_searcher._test

test.describe("Fuzzy Searcher Everything search", function()
  local http_get
  local everything_state

  test.before_each(function()
    http_get = http.get
    everything_state = helpers.everything_state()
  end)

  test.after_each(function()
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    http.get = http_get
    helpers.set_everything_state(everything_state)
  end)

  test.it("uses the Everything HTTP endpoint shared with the Pi extension", function()
    local host = os.getenv("EVERYTHING_HOST") or "localhost"
    local port = os.getenv("EVERYTHING_PORT") or "5777"
    test.equal(helpers.everything_endpoint(), "http://" .. host .. ":" .. port .. "/")
  end)

  test.it("asks Everything for Path Search folders by name and path", function()
    local params = helpers.everything_folder_search_params("sm64", 80, 0)

    test.equal(params.search, "folder: sm64")
    test.equal(params.sort, "path")
    test.equal(params.path, "1")
  end)

  test.it("asks Everything for Path Search file names and paths", function()
    local params = helpers.everything_file_search_params("anvil lua", 80, 0)

    test.equal(params.search, "file: anvil lua")
    test.equal(params.sort, "path")
    test.equal(params.path, "1")
  end)

  test.it("preserves explicit Everything file filters", function()
    local params = helpers.everything_file_search_params("file: ext:lua anvil", 80, 0)

    test.equal(params.search, "file: ext:lua anvil")
  end)

  test.it("searches folders and files together in Path Search", function()
    local requests = {}
    http.get = function(_, params)
      requests[#requests + 1] = params
    end
    helpers.set_everything_state("available")

    fuzzy_searcher.open("@needle")

    test.equal(#requests, 2)
    test.equal(requests[1].search, "folder: needle")
    test.equal(requests[2].search, "file: needle")
  end)

  test.it("shows recent Projects without querying Everything for bare Path Search", function()
    local requests = {}
    http.get = function(_, params)
      requests[#requests + 1] = params
    end
    helpers.set_everything_state("available")

    fuzzy_searcher.open("@")

    test.equal(#requests, 0)
  end)

  test.it("shows recent Projects and folders above files", function()
    local previous = core.recent_projects
    local recent = "C:\\Projects\\needle-project"
    core.recent_projects = { recent }
    local requests = {}
    http.get = function(_, params, options)
      requests[#requests + 1] = { params = params, options = options }
    end
    helpers.set_everything_state("available")

    fuzzy_searcher.open("@needle")
    requests[1].options.on_done(true, nil, {
      totalResults = 2,
      results = {
        { type = "folder", path = "C:\\Projects", name = "needle-project" },
        { type = "folder", path = "C:\\Other", name = "needle-folder" },
      },
    })
    requests[2].options.on_done(true, nil, {
      totalResults = 1,
      results = { { type = "file", path = "C:\\Other", name = "needle-file.txt" } },
    })
    local picker = core.fuzzy_searcher_active_view
    picker:refresh(picker.input:get_text())
    core.recent_projects = previous

    test.equal(picker.results[1].label, "Folders")
    test.equal(picker.results[2].project, recent)
    test.equal(picker.results[3].is_folder, true)
    test.equal(picker.results[4].label, "Files")
    test.equal(picker.results[5].file, "C:\\Other\\needle-file.txt")
  end)

  test.it("orders loaded Everything folders by shallow path depth", function()
    local results = {
      { label = "C:\\Projects\\decomps\\sm64\\levels\\bbh", path = "C:\\Projects\\decomps\\sm64\\levels\\bbh", is_folder = true },
      { label = "C:\\Projects\\decomps\\sm64", path = "C:\\Projects\\decomps\\sm64", is_folder = true },
      { label = "C:\\Users\\Darius\\AppData\\Local\\JetBrains\\CLion2025.1\\projects\\sm64.cc376d61", path = "C:\\Users\\Darius\\AppData\\Local\\JetBrains\\CLion2025.1\\projects\\sm64.cc376d61", is_folder = true },
    }

    helpers.sort_path_results(results)

    test.equal(results[1].path, "C:\\Projects\\decomps\\sm64")
    test.equal(results[2].path, "C:\\Projects\\decomps\\sm64\\levels\\bbh")
  end)
end)
