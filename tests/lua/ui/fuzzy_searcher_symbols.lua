local core = require "core"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local lsp_manager = require "core.lsp.manager"
local lsp_provider = require "core.lsp.provider"
local symbol_index = require "core.treesitter.symbol_index"
local file_icons = require "core.file_icons"
local symbol_icons = require "core.symbol_icons"

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
  test.before_each(function(context)
    context.renderer_draw_text = renderer.draw_text
    context.renderer_draw_rect = renderer.draw_rect
    context.renderer_draw_rounded_rect = renderer.draw_rounded_rect
    context.renderer_draw_text_known_bounds = renderer.draw_text_known_bounds
    context.renderer_set_clip_rect = renderer.set_clip_rect
    context.renderer_draw_canvas = renderer.draw_canvas
    context.file_icons_draw = file_icons.draw
    context.symbol_icons_draw = symbol_icons.draw
  end)

  test.after_each(function(context)
    if context.original_lsp_enabled then lsp_manager.is_enabled = context.original_lsp_enabled end
    if context.original_lsp_workspace_symbols then lsp_provider.workspace_symbols = context.original_lsp_workspace_symbols end
    if context.original_ts_workspace_symbols_async then symbol_index.workspace_symbols_async = context.original_ts_workspace_symbols_async end
    if context.original_ts_status then symbol_index.status = context.original_ts_status end
    renderer.draw_text = context.renderer_draw_text
    renderer.draw_rect = context.renderer_draw_rect
    renderer.draw_rounded_rect = context.renderer_draw_rounded_rect
    renderer.draw_text_known_bounds = context.renderer_draw_text_known_bounds
    renderer.set_clip_rect = context.renderer_set_clip_rect
    renderer.draw_canvas = context.renderer_draw_canvas
    file_icons.draw = context.file_icons_draw
    symbol_icons.draw = context.symbol_icons_draw
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

  test.it("highlights multiword matches in the symbol declaration", function()
    local row = helpers.symbol_result_from_item({
      name = "setup_blank_screen",
      kind = "method",
      declaration = "int RGE_Base_Game::setup_blank_screen()",
      declaration_name_span = { 20, 37 },
      path = "C:/project/game.cpp",
      start_line = 10,
      start_col = 3,
    }, "base setup", { scope = "project", search_declaration = true })

    test.ok(row)
    test.ok(#(row.declaration_spans or {}) > 0, "expected declaration highlighting")
  end)

  test.it("scopes inline symbol search by path and highlights each query in its own column", function(context)
    context.original_lsp_enabled = lsp_manager.is_enabled
    context.original_ts_workspace_symbols_async = symbol_index.workspace_symbols_async

    lsp_manager.is_enabled = function() return false end
    local received_query
    local received_search_declaration
    symbol_index.workspace_symbols_async = function(query, opts)
      received_query = query
      received_search_declaration = opts and opts.search_declaration
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
    test.ok(received_search_declaration)
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

  test.it("puts file and symbol icons in their matching columns", function()
    local picker = fuzzy_searcher.open_static_results("Project symbols", {
      {
        kind = "symbol", file = "src/basegame.cpp", line = 12,
        label = "check_damage", name = "check_damage", symbol_kind = "method",
      },
    })
    picker.position.x, picker.position.y = 0, 0
    picker:set_size(1200, 500)
    picker.open_transition_complete = true
    picker.update_selected_preview = function() end
    picker:update()

    local calls = {}
    local file_icon_x, symbol_icon_x
    renderer.draw_text = function(font, text, x, y)
      calls[#calls + 1] = { text = text, x = x, y = y }
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text_known_bounds = function() end
    renderer.set_clip_rect = function() end
    renderer.draw_canvas = function() end
    file_icons.draw = function(_, x) file_icon_x = x end
    symbol_icons.draw = function(_, x) symbol_icon_x = x end

    picker:draw()

    local file_x, label_x
    for _, call in ipairs(calls) do
      if call.text == "basegame.cpp" then file_x = call.x end
      if call.text == "check_damage" then label_x = call.x end
    end
    test.not_nil(file_icon_x, "expected a file icon in the file column")
    test.not_nil(symbol_icon_x, "expected a symbol icon in the symbol column")
    test.not_nil(file_x, "expected the file name")
    test.not_nil(label_x, "expected the symbol label")
    test.ok(file_icon_x < file_x, "the file icon must precede the file name")
    test.ok(file_x < symbol_icon_x, "the symbol icon must follow the file column")
    test.ok(symbol_icon_x < label_x, "the symbol icon must precede the symbol label")
  end)

  test.it("shows only line numbers after the first symbol from a file", function()
    local picker = fuzzy_searcher.open_static_results("Project symbols", {
      {
        kind = "symbol", file = "src/basegame.cpp", line = 12,
        label = "first_symbol", name = "first_symbol", symbol_kind = "method",
      },
      {
        kind = "symbol", file = "src/basegame.cpp", line = 34,
        label = "second_symbol", name = "second_symbol", symbol_kind = "method",
      },
    })
    picker.position.x, picker.position.y = 0, 0
    picker:set_size(1200, 500)
    picker.open_transition_complete = true
    picker.update_selected_preview = function() end
    picker:update()

    local names, lines, file_icon_count, symbol_icon_count = 0, 0, 0, 0
    renderer.draw_text = function(font, text, x)
      if text == "basegame.cpp" then names = names + 1 end
      if text:find(":12", 1, true) == 1 or text:find(":34", 1, true) == 1 then
        lines = lines + 1
      end
      return x + font:get_width(text)
    end
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text_known_bounds = function() end
    renderer.set_clip_rect = function() end
    renderer.draw_canvas = function() end
    file_icons.draw = function() file_icon_count = file_icon_count + 1 end
    symbol_icons.draw = function() symbol_icon_count = symbol_icon_count + 1 end

    picker:draw()

    test.equal(names, 1, "a symbol group must show its file name once")
    test.equal(lines, 2, "each symbol row must show its line number")
    test.equal(file_icon_count, 1, "a symbol group must show its file icon once")
    test.equal(symbol_icon_count, 2, "each symbol row must show its symbol icon")
  end)
end)
