local core = require "core"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function result_labels(view)
  local labels = {}
  for i, row in ipairs(view.results or {}) do
    labels[i] = row.file or row.label or row.text
  end
  return labels
end

test.describe("Fuzzy Searcher loading feedback delay", function()
  test.before_each(function(context)
    context.original_visited_files = core.visited_files
    core.visited_files = {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    core.visited_files = context.original_visited_files
  end)

  test.it("does not flash file results while selecting a restored symbol prompt", function()
    fuzzy_searcher._test.clear_prompt_history()
    fuzzy_searcher._test.set_file_cache_for_test({ "alpha.lua", "beta.lua" })

    fuzzy_searcher.open("$")
    core.fuzzy_searcher_active_view.input:set_text("$needle")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("$")
    local picker = assert(core.fuzzy_searcher_active_view)

    test.equal(picker.input:get_text(), "$needle")
    test.same(result_labels(picker), {})
  end)
end)
