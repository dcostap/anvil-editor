local common = require "core.common"
local symbol_index = require "core.treesitter.symbol_index"
local test = require "core.test"

test.describe("Project Symbol Search letter case", function()
  test.it("filters indexed symbols before limits without indexing ignored files", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "native-symbol-case-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local function write(name, text)
      local file = assert(io.open(root .. PATHSEP .. name, "wb"))
      file:write(text)
      file:close()
    end
    write("Visible.kt", "class renderWidget\nclass RenderWidget\nclass RedWindow\n")
    write("Ignored.kt", "class RWrong\n")
    write(".ignore", "Ignored.kt\n")
    symbol_index.start_project_indexing({ root = root, reason = "test", refresh_after_seconds = 0 })
    local deadline = system.get_time() + 8
    local index = symbol_index.status(root)
    while index.status ~= "ready" and system.get_time() < deadline do
      coroutine.yield(0.03)
      index = symbol_index.status(root)
    end
    test.equal(index.status, "ready", index.reason)
    local page = index.native_snapshot:query_symbols("RW", {
      case_sensitive = true, limit = 1,
    })
    test.equal(#page, 1)
    test.equal(page.total, 2)
    test.ok(page.has_more)

    local request, reason = symbol_index.workspace_symbols_async("RW", {
      root = root, limit = 10, case_sensitive = true, include_ignored = true,
      refresh_after_seconds = 0,
    })
    test.not_nil(request, reason)
    while not request.done and system.get_time() < deadline do coroutine.yield(0.03) end
    test.equal(request.status, "fresh", request.reason)
    test.equal(#request.results, 2)
    local names = {}
    for _, symbol in ipairs(request.results) do names[symbol.name] = true end
    test.ok(names.RenderWidget)
    test.ok(names.RedWindow)
    test.not_ok(names.renderWidget)
    test.not_ok(names.RWrong)
    common.rm(root, true)
  end)

  test.it("keeps fuzzy matching and filters case before the result limit", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "symbol-search-case-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local index = symbol_index.status(root)
    index.status = "ready"
    index.symbol_status = "ready"
    index.usage_status = "ready"
    index.finished_at = system.get_time()
    index.symbols = {}
    for i, name in ipairs { "renderWidget", "RenderWidget", "RedWindow" } do
      index.symbols[i] = {
        name = name, text = name, kind = "class", path = root .. PATHSEP .. name .. ".kt",
        file = name .. ".kt", relpath = name .. ".kt", start_line = i, start_col = 1,
      }
    end
    local symbols, reason, status = symbol_index.workspace_symbols("RW", {
      root = root, limit = 2, case_sensitive = true, refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.equal(#symbols, 2)
    local names = {}
    for _, symbol in ipairs(symbols) do names[symbol.name] = true end
    test.ok(names.RenderWidget)
    test.ok(names.RedWindow)
    test.not_ok(names.renderWidget)
    common.rm(root, true)
  end)
end)
