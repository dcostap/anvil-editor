local test = require "core.test"
local common = require "core.common"
local symbol_index = require "core.treesitter.symbol_index"
local native_pool = require "worker_pool_native"

local function drain_until(pool, predicate, limit)
  limit = limit or 1000
  for _ = 1, limit do
    for _, message in ipairs(pool:drain({ max_messages = 64 })) do
      if predicate(message) then return true end
    end
    coroutine.yield(0.001)
  end
  return false
end

test.describe("Tree-sitter Project enclosing symbols", function()
  local pool

  test.after_each(function()
    if pool then
      pool:shutdown({ cancel_running = true })
      pool = nil
    end
    symbol_index.reset_for_tests()
  end)

  test.it("returns the innermost callable symbol containing a Project location", function()
    local root = common.normalize_path("C:/project")
    local project_path = common.normalize_path(root .. PATHSEP .. "nested.c")
    pool = native_pool.new({ name = "project-enclosing-symbol", worker_count = 1 })
    local handle = test.not_nil(pool:submit({
      kind = "treesitter_index_text",
      language = "c",
      path = project_path,
      relpath = "nested.c",
      text = [[int outer(void) {
  int inner(void) { return 7; }
  return inner();
}
]],
      outline_query = [[
        (function_definition
          declarator: (function_declarator
            declarator: (identifier) @name)) @outline.function
      ]],
      capture_paging = false,
      line_range_lookup = false,
      compact_project_records = true,
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    }))

    local result
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then result = message.result end
      return message.type == "final"
    end))
    test.not_nil(result)

    local builder = native_pool.new_project_builder({ usage_cap = 10 })
    test.ok(result:adopt_project(builder:id(), {
      fingerprint = "nested-1",
      usage_complete = true,
    }))
    local snapshot = builder:freeze()

    local inner = snapshot:enclosing_symbol(project_path, 2, 24, {
      kinds = { "function", "method" },
    })
    test.not_nil(inner)
    test.equal(inner.name, "inner")
    test.equal(inner.kind, "function")

    local outer = snapshot:enclosing_symbol(project_path, 3, 3, {
      kinds = { "function", "method" },
    })
    test.not_nil(outer)
    test.equal(outer.name, "outer")

    test.is_nil(snapshot:enclosing_symbol(common.normalize_path(root .. PATHSEP .. "missing.c"), 2, 1, {
      kinds = { "function", "method" },
    }))

    local index = symbol_index.status(root)
    index.status = "ready"
    index.symbol_status = "ready"
    index.native_snapshot = snapshot
    local indexed = symbol_index.enclosing_symbol(project_path, 2, 24, {
      root = root,
      kinds = { "function", "method" },
    })
    test.not_nil(indexed)
    test.equal(indexed.name, "inner")
  end)

  test.it("uses current open Buffer symbols for a Project location", function()
    local root = common.normalize_path(USERDIR .. PATHSEP .. "enclosing-symbol-project")
    local path = common.normalize_path(root .. PATHSEP .. "current.c")
    local index = symbol_index.status(root)
    index.status = "ready"
    index.symbol_status = "ready"
    local buffer = {
      abs_filename = path,
      filename = path,
      treesitter = { status = "ready" },
      get_change_id = function() return 7 end,
      is_dirty = function() return true end,
    }
    index.open_buffers[path] = {
      buffer = buffer,
      change_id = 7,
      symbols = {
        {
          name = "outer",
          kind = "function",
          depth = 0,
          start_line = 1,
          start_col = 1,
          end_line = 6,
          end_col = 2,
        },
        {
          name = "inner",
          kind = "method",
          depth = 1,
          start_line = 2,
          start_col = 3,
          end_line = 4,
          end_col = 4,
        },
      },
      usages_by_name = {},
    }
    test.ok(symbol_index.remember_open_buffer(buffer))

    local symbol = symbol_index.enclosing_symbol(path, 3, 5, {
      root = root,
      kinds = { "function", "method" },
    })
    test.not_nil(symbol)
    test.equal(symbol.name, "inner")
    test.equal(symbol.kind, "method")
  end)
end)
