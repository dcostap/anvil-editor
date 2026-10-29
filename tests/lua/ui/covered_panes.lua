local core = require "core"
local common = require "core.common"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

-- Draws one frame of the Root Panel and returns how many Draw Captures it replayed.
local function draw_frame()
  renderer.begin_frame(core.window)
  core.root_panel:draw()
  renderer.end_frame()
  return renderer.get_last_frame_stats().capture_replays
end

test.describe("Panes behind the Fuzzy Searcher", function()
  test.before_each(function(context)
    context.root = USERDIR .. PATHSEP .. "covered-panes-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    local path = context.root .. PATHSEP .. "covered.txt"
    local fp = assert(io.open(path, "wb"))
    for line = 1, 200 do fp:write("line ", line, "\n") end
    fp:close()
    context.view = assert(core.open_file(path, { placement = "current", focus = true }))
    context.view:scroll_to_line(1, false, true)
    coroutine.yield(0.05)
    fuzzy_searcher.open(">")
    test.ok(core.fuzzy_searcher_active_view, "the Fuzzy Searcher did not open")
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    context.view.buffer:clear_undo_redo()
    context.view.buffer.new_file = true
    core.root_panel:close_all_views()
    test.ok(test.remove_tree(context.root))
  end)

  test.it("draws an unchanged Pane from its last draw", function()
    draw_frame()
    test.equal(draw_frame(), 1)
    test.equal(draw_frame(), 1)
  end)

  test.it("draws a Pane again after its text changes", function(context)
    draw_frame()
    context.view.buffer:insert(1, 1, "changed ")
    test.equal(draw_frame(), 0)
    test.equal(draw_frame(), 1)
  end)

  test.it("draws a Pane again after it scrolls", function(context)
    draw_frame()
    local view = context.view
    view.scroll.y = view.scroll.y + view:get_line_height() * 3
    view.scroll.to.y = view.scroll.y
    test.equal(draw_frame(), 0)
    test.equal(draw_frame(), 1)
  end)

  test.it("draws each Pane live after the Fuzzy Searcher closes", function()
    draw_frame()
    test.equal(draw_frame(), 1)
    core.fuzzy_searcher_active_view:close()
    test.equal(draw_frame(), 0)
  end)
end)
