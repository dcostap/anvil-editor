local test = require "core.test"
local core = require "core"
local common = require "core.common"
local panes = require "core.panes"

local function wait_for(predicate)
  local deadline = system.get_time() + 30
  repeat
    if predicate() then return end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  test.ok(predicate(), "file open did not become ready")
end

test.describe("Large file opening", function()
  local started = false
  test.before_each(function(context)
    if not started then
      wait_for(function() return panes.count() > 0 end)
      started = true
    end
    context.old_view = core.active_view
    context.old_cwd = system.getcwd()
    panes.reset_for_tests()
    context.root = USERDIR .. PATHSEP .. "large-open-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    context.path = context.root .. PATHSEP .. "large.txt"
    local file = assert(io.open(context.path, "wb"))
    assert(file:write(string.rep(string.rep("ordinary source text for the loading fixture ", 3) .. "\n", 200000)))
    assert(file:close())
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    core.buffer_registry:collect()
    core.active_view = context.old_view
    system.chdir(context.old_cwd)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("returns a loading Editor and publishes the complete file without changing focus", function(context)
    local view = assert(core.open_file(context.path, { placement = "new" }))
    test.ok(view.buffer:is_loading(), "the command loaded the whole file before returning")
    test.same(view.buffer.lines, { "\n" })
    wait_for(function() return not view.buffer:is_loading() end)
    test.not_ok(view.buffer.load_error, view.buffer.load_error)
    test.equal(#view.buffer.lines, 200000)
    test.equal(view:get_selection_state().selections[1], 1)
    test.equal(core.active_view, view)
  end)

  test.it("keeps explicit file destinations synchronous", function(context)
    local view = assert(core.open_file(context.path, { placement = "new", line = 100000, col = 4 }))
    test.not_ok(view.buffer:is_loading())
    test.equal(#view.buffer.lines, 200000)
    test.equal(view:get_selection_state().selections[1], 100000)
    test.equal(view:get_selection_state().selections[2], 4)
  end)

  test.it("keeps immediate contents available through the synchronous Buffer API", function(context)
    local view = assert(core.open_file(context.path, { placement = "new" }))
    test.ok(view.buffer:is_loading())
    local buffer = core.open_buffer(context.path)
    test.equal(buffer, view.buffer)
    test.not_ok(buffer:is_loading())
    test.not_ok(buffer.load_error)
    test.equal(#buffer.lines, 200000)
  end)

  test.it("cancels loading when the last Editor closes", function(context)
    local view = assert(core.open_file(context.path, { placement = "new" }))
    local buffer = view.buffer
    test.ok(buffer:is_loading())
    test.ok(panes.close(panes.pane_for_view(view)))
    core.buffer_registry:collect()
    test.not_ok(buffer:is_loading())
    test.not_ok(core.buffer_registry:find(context.path))
  end)
end)
