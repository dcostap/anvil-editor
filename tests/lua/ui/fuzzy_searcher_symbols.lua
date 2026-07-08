local core = require "core"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local lsp_manager = require "core.lsp.manager"
local lsp_provider = require "core.lsp.provider"
local symbol_index = require "core.treesitter.symbol_index"

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
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
  end)

  test.it("falls back to Tree-sitter when LSP returns an empty fresh workspace symbol result", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_lsp_workspace_symbols = lsp_provider.workspace_symbols
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async

    local lsp_queries = 0
    local ts_query
    lsp_manager.is_enabled = function() return true end
    lsp_provider.workspace_symbols = function(query)
      lsp_queries = lsp_queries + 1
      test.equal(query, "parse")
      return {}, nil, "fresh"
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
    test.equal(lsp_queries, 1)
    test.equal(ts_query, "parse")
    test.equal(picker.results[1].label, "parse")
    test.equal(picker.status, "1 symbol — Tree-sitter")
  end)
end)
