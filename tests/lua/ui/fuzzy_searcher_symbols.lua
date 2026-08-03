local core = require "core"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local lsp_manager = require "core.lsp.manager"
local lsp_provider = require "core.lsp.provider"
local symbol_index = require "core.treesitter.symbol_index"

local helpers = fuzzy_searcher._test

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 3)
  while system.get_time() < deadline do
    if predicate() then return true end
    coroutine.yield(0.03)
  end
  return predicate()
end

test.describe("Fuzzy Searcher Project symbols", function()
  test.after_each(function(context)
    if context.original_lsp_enabled then lsp_manager.is_enabled = context.original_lsp_enabled end
    if context.original_lsp_workspace_symbols then lsp_provider.workspace_symbols = context.original_lsp_workspace_symbols end
    if context.original_ts_workspace_symbols_async then symbol_index.workspace_symbols_async = context.original_ts_workspace_symbols_async end
    if context.original_ts_status then symbol_index.status = context.original_ts_status end
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
  end)

  test.it("does not start the file index for Project Symbol Search", function()
    test.not_ok(helpers.prompt_uses_file_index("$symbol"))
    test.not_ok(helpers.prompt_uses_file_index("src/game $symbol"))
    test.ok(helpers.prompt_uses_file_index("vehicle.cpp"))
  end)

  test.it("does not keep Project symbol search pending while only usage indexing is running", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async

    lsp_manager.is_enabled = function() return false end
    symbol_index.workspace_symbols_async = function(query)
      test.equal(query, "missing")
      return {
        done = true,
        status = "fresh",
        results = {},
        meta = {
          roots = {
            { status = "fresh", index = { status = "indexing", symbol_status = "ready", usage_status = "indexing" } },
          },
        },
        cancel = function() end,
      }, nil, "pending", { roots = {} }
    end

    fuzzy_searcher.open("$missing")
    local picker = core.fuzzy_searcher_active_view
    picker:refresh("$missing")

    test.ok(wait_until(function() return picker.status == "0 symbols — Tree-sitter" end))
    test.equal(#(picker.results or {}), 0)
  end)

  test.it("settles an empty completed native Project Symbol query", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async
    context.original_ts_status = symbol_index.status

    lsp_manager.is_enabled = function() return false end
    local ready_index = { status = "ready", symbol_status = "ready", usage_status = "ready" }
    -- A separate root may begin indexing after this request captured its
    -- consistent snapshots. The completed request is still authoritative and
    -- must settle instead of being discarded by a second global status scan.
    symbol_index.status = function()
      return { status = "indexing", symbol_status = "indexing", usage_status = "indexing" }
    end
    local calls = 0
    symbol_index.workspace_symbols_async = function(query)
      calls = calls + 1
      test.equal(query, "absent")
      return {
        done = true,
        status = "fresh",
        results = {},
        meta = {
          roots = { { status = "pending", index = ready_index } },
          index = ready_index,
        },
        cancel = function() end,
      }, nil, "pending", { roots = {} }
    end

    fuzzy_searcher.open("$absent")
    local picker = core.fuzzy_searcher_active_view
    picker:refresh("$absent")

    test.ok(wait_until(function() return picker.status == "0 symbols — Tree-sitter" end))
    test.equal(calls, 1)
  end)

  test.it("settles a terminal native Project Symbol query failure", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async

    lsp_manager.is_enabled = function() return false end
    local calls = 0
    symbol_index.workspace_symbols_async = function(query)
      calls = calls + 1
      test.equal(query, "broken-native")
      return {
        done = true,
        status = "unavailable",
        reason = "native-project-symbol-query-failed",
        results = nil,
        meta = { roots = {} },
        cancel = function() end,
      }, nil, "pending", { roots = {} }
    end

    fuzzy_searcher.open("$broken-native")
    local picker = core.fuzzy_searcher_active_view
    picker:refresh("$broken-native")

    test.ok(wait_until(function()
      return picker.status == "Project symbols unavailable: native-project-symbol-query-failed"
    end))
    test.equal(calls, 1)
  end)

  test.it("surfaces a terminal Tree-sitter Project index failure instead of polling forever", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async

    lsp_manager.is_enabled = function() return false end
    local calls = 0
    symbol_index.workspace_symbols_async = function(query)
      calls = calls + 1
      test.equal(query, "broken")
      return nil, "invalid-project-input", "unavailable", { roots = {} }
    end

    fuzzy_searcher.open("$broken")
    local picker = core.fuzzy_searcher_active_view
    picker:refresh("$broken")

    test.ok(wait_until(function()
      return picker.status == "Project symbols unavailable: invalid-project-input"
    end))
    test.equal(calls, 1)
  end)

  test.it("cancels the obsolete native Project Symbol query immediately", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async
    lsp_manager.is_enabled = function() return false end

    local requests = {}
    symbol_index.workspace_symbols_async = function()
      local request = {
        done = false,
        status = "pending",
        cancel = function(self)
          self.done = true
          self.status = "cancelled"
          self.cancelled = true
          return true
        end,
      }
      requests[#requests + 1] = request
      return request, nil, "pending", { roots = {} }
    end

    fuzzy_searcher.open("$first")
    local picker = core.fuzzy_searcher_active_view
    test.ok(wait_until(function()
      return requests[1] and picker.symbol_search_request == requests[1]
    end))

    picker:start_symbol_search("second", true, "")

    test.ok(requests[1].cancelled)
  end)

  test.it("shows Project indexing progress for large Projects", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async

    lsp_manager.is_enabled = function() return false end
    symbol_index.workspace_symbols_async = function()
      local index = { status = "indexing", symbol_status = "indexing", files_scanned = 12345 }
      return nil, "indexing", "pending", {
        index = index,
        roots = { { status = "pending", index = index } },
      }
    end

    fuzzy_searcher.open("$progress")
    local picker = core.fuzzy_searcher_active_view
    picker:refresh("$progress")

    test.ok(wait_until(function()
      return picker.status == "Indexing Project symbols… 12345 files scanned"
    end))
  end)

  test.it("highlights symbol text but not incidental path matches in normal symbol mode", function()
    local row = helpers.symbol_result_from_item({
      name = "parser",
      kind = "function",
      path = "C:/project/parser/parser.odin",
      start_line = 10,
      start_col = 3,
    }, "parser", { scope = "project" })

    test.ok(#row.match_spans > 0, "expected symbol-name highlighting")
    test.same(row.file_spans, {})
  end)

  test.it("scopes inline symbol search by path and highlights each query in its own column", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async

    lsp_manager.is_enabled = function() return false end
    local received_query
    symbol_index.workspace_symbols_async = function(query)
      received_query = query
      return {
        done = true,
        status = "fresh",
        results = {
          { name = "parse_package", kind = "function", path = "C:/project/odin/parser/files.odin", start_line = 10, start_col = 3 },
          { name = "parse_package", kind = "function", path = "C:/project/other/files.odin", start_line = 20, start_col = 3 },
        },
        cancel = function() end,
      }, nil, "pending", { roots = {} }
    end

    fuzzy_searcher.open("odin/parser $parse package")
    local picker = core.fuzzy_searcher_active_view
    picker:refresh("odin/parser $parse package")

    test.ok(wait_until(function() return #(picker.results or {}) == 1 end))
    test.equal(received_query, "parse package")
    test.equal(picker.results[1].label, "parse_package")
    test.ok(#picker.results[1].match_spans > 0, "expected symbol query highlighting in the symbol column")
    test.ok(#picker.results[1].file_spans > 0, "expected path query highlighting in the path column")
  end)

  test.it("uses Tree-sitter immediately even when LSP is enabled", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_lsp_workspace_symbols = lsp_provider.workspace_symbols
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async

    local lsp_queries = 0
    local ts_query
    lsp_manager.is_enabled = function() return true end
    lsp_provider.workspace_symbols = function(query)
      lsp_queries = lsp_queries + 1
      test.equal(query, "parse")
      return nil, "pending", "pending"
    end
    symbol_index.workspace_symbols_async = function(query)
      ts_query = query
      return {
        done = true,
        status = "fresh",
        results = {
          { name = "parse", kind = "function", path = "C:/project/parser.odin", relpath = "parser.odin", start_line = 10, start_col = 3 },
        },
        cancel = function() end,
      }, nil, "pending", { roots = {} }
    end

    fuzzy_searcher.open("$parse")
    local picker = core.fuzzy_searcher_active_view
    picker:refresh("$parse")

    test.ok(wait_until(function() return #(picker.results or {}) == 1 end))
    test.equal(lsp_queries, 0)
    test.equal(ts_query, "parse")
    test.equal(picker.results[1].label, "parse")
    test.equal(picker.status, "1 symbol — Tree-sitter")
  end)
end)
