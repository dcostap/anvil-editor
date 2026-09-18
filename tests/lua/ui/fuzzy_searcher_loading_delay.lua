local core = require "core"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local symbol_index = require "core.treesitter.symbol_index"

local function result_labels(view)
  local labels = {}
  for i, row in ipairs(view.results or {}) do
    labels[i] = row.file or row.label or row.text
  end
  return labels
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 2)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.01) end
  return predicate()
end

local function find_file_result(view, file)
  for _, result in ipairs(view.results or {}) do
    if result.kind == "file" and result.file == file then return result end
  end
end

test.describe("Fuzzy Searcher loading feedback delay", function()
  test.before_each(function(context)
    context.original_visited_files = core.visited_files
    core.visited_files = {}
  end)

  test.after_each(function(context)
    if context.original_current_buffer_symbols then
      symbol_index.current_buffer_symbols = context.original_current_buffer_symbols
    end
    if context.fake_file_index then fuzzy_searcher._test.set_file_cache_for_test({}) end
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

  test.it("keeps Project File Search rows while a refined query is pending", function(context)
    fuzzy_searcher._test.set_file_cache_for_test({ "prior.lua", "replacement.lua" })
    fuzzy_searcher.open("prior")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return find_file_result(picker, "prior.lua") ~= nil
    end), "expected rows for the initial file query; input=" .. tostring(picker.input:get_text())
      .. " status=" .. tostring(picker.status)
      .. " rows=" .. table.concat(result_labels(picker), ","))

    local fake_index = { "prior.lua", "replacement.lua" }
    function fake_index:search(query)
      test.equal(query, "priorx")
      context.refined_file_search_started = true
      while not context.release_refined_file_search
        and core.fuzzy_searcher_active_view == picker do
        coroutine.yield(0.01)
      end
      return {
        { text = "replacement.lua", score = 1, spans = {} },
      }
    end
    fuzzy_searcher._test.set_file_fuzzy_index_for_test(fake_index)
    context.fake_file_index = true
    test.ok(fuzzy_searcher._test.file_index_status().native)

    picker:on_text_input("x")
    test.equal(picker.input:get_text(), "priorx")
    test.not_nil(find_file_result(picker, "prior.lua"))
    coroutine.yield((fuzzy_searcher.loading_feedback_delay or 0.20) + 0.05)

    test.ok(context.refined_file_search_started)
    test.not_nil(find_file_result(picker, "prior.lua"))

    context.release_refined_file_search = true
    test.ok(wait_until(function()
      return find_file_result(picker, "replacement.lua") ~= nil
    end), "expected the completed file query to replace the prior rows")
  end)

  test.it("keeps prior rows until a delayed search publishes replacement rows", function(context)
    context.original_current_buffer_symbols = symbol_index.current_buffer_symbols
    symbol_index.current_buffer_symbols = function(_, query)
      if query ~= "needle" then
        return {
          { name = "prior", kind = "function", start_line = 1, start_col = 1 },
        }, nil, "fresh"
      end
      context.replacement_search_started = true
      while not context.release_replacement_search
        and core.fuzzy_searcher_active_view do
        coroutine.yield(0.01)
      end
      return {
        { name = "needle", kind = "function", start_line = 1, start_col = 1 },
      }, nil, "fresh"
    end

    fuzzy_searcher.open("$$needl")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return picker.results[1] and picker.results[1].label == "prior"
    end), "expected rows for the initial query")

    picker:on_text_input("e")
    test.equal(picker.input:get_text(), "$$needle")
    test.equal(picker.results[1].label, "prior")
    coroutine.yield((fuzzy_searcher.loading_feedback_delay or 0.20) + 0.05)

    test.ok(context.replacement_search_started)
    test.equal(picker.results[1].label, "prior")

    context.release_replacement_search = true
    test.ok(wait_until(function()
      return picker.results[1] and picker.results[1].label == "needle"
    end), "expected the completed search to replace the prior rows")
    test.equal(picker.results[1].label, "needle")
  end)

  test.it("clears prior rows when a delayed search completes with no matches", function(context)
    context.original_current_buffer_symbols = symbol_index.current_buffer_symbols
    symbol_index.current_buffer_symbols = function(_, query)
      if query ~= "missing" then
        return {
          { name = "prior", kind = "function", start_line = 1, start_col = 1 },
        }, nil, "fresh"
      end
      context.empty_search_started = true
      while not context.release_empty_search
        and core.fuzzy_searcher_active_view do
        coroutine.yield(0.01)
      end
      return {}, nil, "fresh"
    end

    fuzzy_searcher.open("$$missin")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return picker.results[1] and picker.results[1].label == "prior"
    end), "expected rows for the initial query")

    picker:on_text_input("g")
    test.equal(picker.input:get_text(), "$$missing")
    test.equal(picker.results[1].label, "prior")
    coroutine.yield((fuzzy_searcher.loading_feedback_delay or 0.20) + 0.05)
    test.ok(context.empty_search_started)
    test.equal(picker.results[1].label, "prior")

    context.release_empty_search = true
    test.ok(wait_until(function() return #picker.results == 0 end))
    test.equal(#picker.results, 0)
    test.equal(picker.status, "0 symbols — current Buffer")
  end)
end)
