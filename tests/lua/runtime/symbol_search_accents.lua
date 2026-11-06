local common = require "core.common"
local symbol_index = require "core.treesitter.symbol_index"
local test = require "core.test"

local function wait_until(predicate)
  local deadline = system.get_time() + 30
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

test.describe("Project Symbol Search accents", function()
  test.after_each(function(context)
    symbol_index.reset_for_tests()
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)

  test.it("matches indexed accents while keeping enye and source names", function(context)
    symbol_index.reset_for_tests()
    context.root = USERDIR .. PATHSEP .. "symbol-accents-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    local path = context.root .. PATHSEP .. "símbolos.kt"
    local file = assert(io.open(path, "wb"))
    file:write("class CaféNiño\nclass CafeNiña\nclass CafeNino\n")
    file:close()
    symbol_index.start_project_indexing { root = context.root, reason = "test", refresh_after_seconds = 0 }
    test.ok(wait_until(function() return symbol_index.status(context.root).status == "ready" end))

    for _, case in ipairs {
      { "cafeniño", false, "CaféNiño" },
      { "caféniña", false, "CafeNiña" },
      { "cafenino", false, "CafeNino" },
      { "CAFENIÑO", false, "CaféNiño" },
      { "CafeNiño", true, "CaféNiño" },
      { "caféniño", true },
    } do
      local request, reason = symbol_index.workspace_symbols_async(case[1], {
        root = context.root, limit = 10, case_sensitive = case[2], refresh_after_seconds = 0,
      })
      test.not_nil(request, reason)
      test.ok(wait_until(function() return request.done end), case[1])
      test.equal(request.status, "fresh", request.reason)
      test.equal(#request.results, case[3] and 1 or 0, case[1])
      if case[3] then
        test.equal(request.results[1].name, case[3])
        test.ok(common.path_equals(request.results[1].path, path))
      end
    end
  end)
end)
