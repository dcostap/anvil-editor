local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local symbol_index = require "core.treesitter.symbol_index"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local treesitter = require "core.treesitter"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

local function wait_until(predicate)
  local deadline = system.get_time() + 10
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain { max_ms = 5, max_messages = 64 } end
    if predicate() then return end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  test.fail("Timed out waiting for Project symbols")
end

local function open_picker(context, results)
  local picker = fuzzy_searcher.open_static_results("Text Search", results)
  context.picker = picker
  picker.position.x, picker.position.y = 0, 0
  picker:set_size(1400, 500)
  picker.open_transition_complete = true
  picker:update()
  return picker
end

test.describe("Text Search prepared symbol context", function()
  test.before_each(function(context)
    context.projects, context.cwd = core.projects, system.getcwd()
    context.root = USERDIR .. PATHSEP .. "grep-symbol-context"
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
    wait_until(function() return symbol_index.status(context.root).status == "ready" end)
  end)

  test.after_each(function(context)
    if context.picker then context.picker:close("replaced") end
    if context.buffer then
      symbol_index.clear_open_buffer(context.buffer)
      core.buffer_registry:remove(context.buffer, true)
      context.buffer:on_close()
    end
    symbol_index.reset_for_tests()
    project_paths.configure_workspace {}
    core.projects = context.projects
    system.chdir(context.cwd)
    common.rm(context.root, true)
  end)

  test.it("prepares current enclosing symbols before painting and clears stale context after edits", function(context)
    local picker = open_picker(context, {
      { kind = "grep", file = "main.c", abs_path = context.path, line = 2, col = 3, text = "return 1;" },
      { kind = "grep", file = "main.c", abs_path = context.path, line = 4, col = 1, text = "" },
      { kind = "grep", file = "main.c", abs_path = context.path, line = 6, col = 3, text = "return 2;" },
    })
    test.equal(test.not_nil(picker.results[1].enclosing_symbol).name, "first")
    test.is_nil(picker.results[2].enclosing_symbol)
    test.equal(test.not_nil(picker.results[3].enclosing_symbol).name, "second")

    local buffer = core.open_buffer(context.path)
    context.buffer = buffer
    symbol_index.remember_open_buffer(buffer)
    buffer:remove(1, 5, 1, 10)
    buffer:insert(1, 5, "renamed")
    picker:update()
    test.is_nil(picker.results[1].enclosing_symbol, "Do not show stale disk symbols during parsing")
    wait_until(function()
      treesitter.poll_buffer(buffer)
      picker:update()
      return picker.results[1].enclosing_symbol ~= nil
    end)
    test.equal(picker.results[1].enclosing_symbol.name, "renamed")
    test.equal(picker.results[3].enclosing_symbol.name, "second")
  end)

  test.it("prepares newly visible context when the result list scrolls", function(context)
    local results = {}
    for i = 1, 60 do
      results[i] = {
        kind = "grep", file = "main.c", abs_path = context.path,
        line = i <= 30 and 2 or 6, col = 3, text = "return;",
      }
    end
    local picker = open_picker(context, results)
    test.equal(test.not_nil(picker.results[1].enclosing_symbol).name, "first")
    test.is_nil(picker.results[60].enclosing_symbol, "Leave offscreen results unprepared")
    picker:scroll_results(60)
    wait_until(function()
      picker:update()
      return picker:displayed_list_offset() > 30
    end)
    local first = picker:displayed_list_offset()
    test.equal(test.not_nil(picker.results[first].enclosing_symbol).name, "second")
  end)
end)
