local core = require "core"
local common = require "core.common"
local Buffer = require "core.buffer"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local symbol_index = require "core.treesitter.symbol_index"
local test = require "core.test"
local treesitter = require "core.treesitter"
local worker_pool = require "core.worker_pool"

local function drain()
  local pool = worker_pool.current_system()
  if pool then pool:drain { max_ms = 5, max_messages = 64 } end
end

test.describe("Project enclosing symbols", function()
  test.before_each(function(context)
    context.projects, context.cwd = core.projects, system.getcwd()
    context.root = USERDIR .. PATHSEP .. "enclosing-symbols"
    common.rm(context.root, true)
    test.ok(common.mkdirp(context.root))
    context.path = context.root .. PATHSEP .. "main.c"
    local file = assert(io.open(context.path, "wb"))
    file:write("int first(void) {\n  return 1;\n}\n\nint second(void) {\n  return 2;\n}\n")
    file:close()
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {}
    symbol_index.reset_for_tests()
    symbol_index.ensure_scan(context.root)
    local deadline = system.get_time() + 10
    repeat
      drain()
      if symbol_index.status(context.root).status == "ready" then break end
      coroutine.yield(0.02)
    until system.get_time() >= deadline
    test.equal(symbol_index.status(context.root).status, "ready")
  end)

  test.after_each(function(context)
    if context.buffer then
      core.buffer_registry:remove(context.buffer, true)
      context.buffer:on_close()
    end
    symbol_index.reset_for_tests()
    project_paths.configure_workspace {}
    core.projects = context.projects
    system.chdir(context.cwd)
    common.rm(context.root, true)
  end)

  test.it("returns one result per location, including missing and invalid locations", function(context)
    local results = symbol_index.enclosing_symbols({
      { path = context.path, line = 6, col = 3 },
      { path = context.path, line = 4, col = 1 },
      { path = context.path, line = 2, col = 3 },
      { path = context.path, line = 0 },
      { path = USERDIR .. PATHSEP .. "outside.c", line = 1 },
      { path = context.path, line = 2, col = 3 },
    }, { kinds = { "function" } })
    test.equal(#results, 6)
    test.equal(results[1].symbol.name, "second")
    test.is_nil(results[2].symbol)
    test.is_nil(results[2].reason)
    test.equal(results[3].symbol.name, "first")
    test.equal(results[4].reason, "invalid-location")
    test.equal(results[5].reason, "outside-project")
    test.equal(results[6].symbol.name, "first")
  end)

  test.it("does not return cached disk symbols after an unsaved edit", function(context)
    local locations = { { path = context.path, line = 2, col = 3 } }
    test.equal(symbol_index.enclosing_symbols(locations)[1].symbol.name, "first")
    local buffer = Buffer("main.c", context.path)
    context.buffer = buffer
    core.buffer_registry:register(buffer, context.path)
    symbol_index.remember_open_buffer(buffer)
    buffer:remove(1, 5, 1, 10)
    buffer:insert(1, 5, "renamed")
    local pending = symbol_index.enclosing_symbols(locations)[1]
    test.is_nil(pending.symbol)
    test.equal(pending.reason, "overlay-indexing")
    local result
    local deadline = system.get_time() + 10
    repeat
      treesitter.poll_buffer(buffer)
      drain()
      result = symbol_index.enclosing_symbols(locations)[1]
      if result.symbol then break end
      coroutine.yield(0.02)
    until system.get_time() >= deadline
    test.equal(test.not_nil(result.symbol).name, "renamed")
    symbol_index.clear_open_buffer(buffer)
    core.buffer_registry:remove(buffer, true)
    buffer:on_close()
    context.buffer = nil
    test.equal(symbol_index.enclosing_symbols(locations)[1].symbol.name, "first")
  end)

  local function count_overlay_submissions(context)
    local pool = worker_pool.system()
    local submit = pool.submit
    context.overlay_submissions = 0
    pool.submit = function(self, spec)
      if spec and spec.kind == "treesitter_open_buffer_overlay" then
        context.overlay_submissions = context.overlay_submissions + 1
      end
      return submit(self, spec)
    end
    context.restore_submit = function() pool.submit = submit end
  end

  local function edited_buffer(context)
    local buffer = Buffer("main.c", context.path)
    context.buffer = buffer
    core.buffer_registry:register(buffer, context.path)
    symbol_index.remember_open_buffer(buffer)
    buffer:remove(1, 5, 1, 10)
    buffer:insert(1, 5, "renamed")
    return buffer
  end

  -- Wait without yielding, so the main loop cannot publish the overlay job
  -- that the parse-ready hook submits.
  local function wait_parsed_without_yield(buffer)
    local deadline = system.get_time() + 10
    repeat
      local _, changed = treesitter.poll_buffer(buffer)
      if changed and buffer.treesitter.status == "ready" then return end
      system.sleep(0.005)
    until system.get_time() >= deadline
    test.fail("Timed out waiting for the edited Buffer parse")
  end

  local function wait_for_symbol(buffer, locations, name)
    local result
    local deadline = system.get_time() + 10
    repeat
      treesitter.poll_buffer(buffer)
      drain()
      result = symbol_index.enclosing_symbols(locations)[1]
      if result.symbol and result.symbol.name == name then break end
      coroutine.yield(0.02)
    until system.get_time() >= deadline
    test.equal(result.symbol and result.symbol.name, name)
  end

  test.it("prepares an edited Buffer once while its symbols are queried repeatedly", function(context)
    local locations = { { path = context.path, line = 2, col = 3 } }
    count_overlay_submissions(context)
    local ok, err = pcall(function()
      local buffer = edited_buffer(context)
      wait_parsed_without_yield(buffer)
      for _ = 1, 5 do symbol_index.enclosing_symbols(locations) end
      symbol_index.workspace_symbols("renamed", { root = context.root })
      symbol_index.workspace_usages("renamed", { root = context.root, allow_stale = true })
    end)
    context.restore_submit()
    test.ok(ok, err)
    test.equal(context.overlay_submissions, 1)
    wait_for_symbol(context.buffer, locations, "renamed")
  end)

  test.it("publishes edited Buffer symbols when the Project index refreshes during preparation", function(context)
    local locations = { { path = context.path, line = 2, col = 3 } }
    local buffer = edited_buffer(context)
    wait_parsed_without_yield(buffer)
    test.ok(symbol_index.reindex_file(context.path, { reason = "test-save" }))
    wait_for_symbol(buffer, locations, "renamed")
    local deadline = system.get_time() + 10
    repeat
      drain()
      coroutine.yield(0.02)
    until symbol_index.status(context.root).status == "ready" or system.get_time() >= deadline
  end)

  test.it("uses Buffers opened before their Project index exists", function(context)
    symbol_index.reset_for_tests()
    local locations = { { path = context.path, line = 2, col = 3 } }
    local buffer = edited_buffer(context)
    local deadline = system.get_time() + 10
    repeat
      treesitter.poll_buffer(buffer)
      coroutine.yield(0.01)
    until buffer.treesitter.status == "ready" or system.get_time() >= deadline
    symbol_index.ensure_scan(context.root)
    deadline = system.get_time() + 10
    repeat
      drain()
      coroutine.yield(0.02)
    until symbol_index.status(context.root).status == "ready" or system.get_time() >= deadline
    wait_for_symbol(buffer, locations, "renamed")
  end)
end)
