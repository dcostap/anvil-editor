local core = require "core"
local test = require "core.test"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local autocomplete = require "plugins.autocomplete"
local Widget = require "widget"
local terminal = require "plugins.terminal"
local config = require "core.config"
local diffview = require "plugins.diffview"

local ListView = View:extend()
function ListView:new()
  ListView.super.new(self)
  self.scrollable = true
end
function ListView:get_scrollable_size() return 10000 end

test.describe("Middle-click autoscroll", function()
  local saved, root, now

  test.before_each(function()
    autocomplete.close()
    Widget.destroy_floating_widgets()
    panes.reset_for_tests()
    saved = {}
    for _, key in ipairs {
      "root_panel", "title_bar", "nag_view", "global_prompt_bar", "status_bar",
      "active_view", "last_active_view", "next_active_view", "cursor_change_req", "redraw",
    } do saved[key] = core[key] end
    saved.get_time = system.get_time
    saved.diff_layout = config.plugins.diffview.layout
    now = saved.get_time()
    system.get_time = function() return now end
    core.title_bar, core.nag_view, core.global_prompt_bar, core.status_bar = nil, nil, nil, nil
    root = RootPanel()
    root.size.x, root.size.y = 600, 400
    core.root_panel = root
  end)

  test.after_each(function()
    if saved.diff_view and not saved.diff_view.disposed then saved.diff_view:on_close() end
    config.plugins.diffview.layout = saved.diff_layout
    panes.reset_for_tests()
    system.get_time = saved.get_time
    for _, key in ipairs {
      "root_panel", "title_bar", "nag_view", "global_prompt_bar", "status_bar",
      "active_view", "last_active_view", "next_active_view", "cursor_change_req", "redraw",
    } do core[key] = saved[key] end
  end)

  local function show(view)
    panes.create { factory = function() return view end }
    root:update()
    return view
  end

  local function tick()
    now = now + 1 / 60
    root:update()
  end

  local function start()
    core.on_event("mousepressed", "middle", 200, 200, 1)
    core.on_event("mousereleased", "middle", 200, 200)
  end

  test.it("scrolls an Editor without changing its text or selection", function()
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, string.rep("line\n", 1000))
    local view = show(Editor(buffer))
    local selection = { view:get_selection_state().selections[1], view:get_selection_state().selections[2] }
    local text = table.concat(buffer.lines)
    start()
    core.on_event("mousemoved", 200, 280, 0, 80)
    tick()
    test.ok(view.scroll.y > 0, "moving below the anchor should scroll down")
    core.on_event("mousepressed", "left", 200, 320, 1)
    test.same({ view:get_selection_state().selections[1], view:get_selection_state().selections[2] }, selection)
    test.equal(table.concat(buffer.lines), text)
  end)

  test.it("scrolls a non-text View faster farther from the anchor and reverses above it", function()
    local view = show(ListView())
    view.scroll.y, view.scroll.to.y = 500, 500
    start()
    core.on_event("mousemoved", 200, 201, 0, 1)
    tick()
    test.equal(view.scroll.y, 500)
    core.on_event("mousemoved", 200, 240, 0, 40)
    tick()
    local near = view.scroll.y - 500
    test.ok(near > 0)
    local previous = view.scroll.y
    core.on_event("mousemoved", 200, 320, 0, 80)
    tick()
    test.ok(view.scroll.y - previous > near)
    previous = view.scroll.y
    core.on_event("mousemoved", 200, 80, 0, -240)
    tick()
    test.ok(view.scroll.y < previous)
  end)

  test.it("stops on Escape or another click", function()
    local view = show(ListView())
    start()
    core.on_event("mousemoved", 200, 320, 0, 120)
    tick()
    test.ok(view.scroll.y > 0)
    core.on_event("keypressed", "escape", {})
    local stopped = view.scroll.y
    tick()
    test.equal(view.scroll.y, stopped)
    test.is_nil(root:modal_input_owner())
    start()
    core.on_event("mousemoved", 200, 320, 0, 120)
    tick()
    test.ok(view.scroll.y > stopped)
    core.on_event("mousepressed", "left", 200, 320, 1)
    stopped = view.scroll.y
    tick()
    test.equal(view.scroll.y, stopped)
    test.is_nil(root:modal_input_owner())
  end)

  test.it("keeps scrolling the initial View when the pointer crosses a Pane", function()
    local view = show(ListView())
    local other = ListView()
    panes.split(panes.active(), "right", { factory = function() return other end })
    root:update()
    start()
    core.on_event("mousemoved", 500, 320, 300, 120)
    tick()
    test.ok(view.scroll.y > 0)
    test.equal(other.scroll.y, 0)
  end)

  test.it("stops when the initial View is no longer current", function()
    local view = show(ListView())
    start()
    core.on_event("mousemoved", 200, 320, 0, 120)
    tick()
    test.ok(view.scroll.y > 0)
    panes.present(ListView(), { pane = panes.active() })
    local stopped = view.scroll.y
    tick()
    test.equal(view.scroll.y, stopped)
    test.is_nil(root:modal_input_owner())
  end)

  test.it("clamps at the content ends and allows reversal", function()
    local view = show(ListView())
    view.scroll.y, view.scroll.to.y = 9599, 9599
    start()
    core.on_event("mousemoved", 200, 320, 0, 120)
    tick()
    test.equal(view.scroll.y, 9600)
    core.on_event("mousemoved", 200, 80, 0, -240)
    tick()
    test.ok(view.scroll.y < 9600)
    view.scroll.y, view.scroll.to.y = 1, 1
    tick()
    test.equal(view.scroll.y, 0)
  end)

  test.it("stops when the window loses focus or a new modal opens", function()
    local view = show(ListView())
    start()
    core.on_event("mousemoved", 200, 320, 0, 120)
    tick()
    root:on_focus_lost()
    local stopped = view.scroll.y
    tick()
    test.equal(view.scroll.y, stopped)
    test.is_nil(root:modal_input_owner())
    start()
    local owner = {}
    root:push_modal_input(owner)
    core.on_event("mousemoved", 200, 320, 0, 120)
    tick()
    test.equal(view.scroll.y, stopped)
    test.equal(root:modal_input_owner(), owner)
    root:pop_modal_input(owner)
    test.is_nil(root:modal_input_owner())
  end)

  test.it("returns to the previous modal after scrolling its content", function()
    local view = ListView()
    view.size.x, view.size.y = 600, 400
    root:push_modal_input(view)
    start()
    core.on_event("mousemoved", 200, 320, 0, 120)
    tick()
    test.ok(view.scroll.y > 0)
    core.on_event("keypressed", "escape", {})
    test.equal(root:modal_input_owner(), view)
    root:pop_modal_input(view)
    test.is_nil(root:modal_input_owner())
  end)

  test.it("scrolls terminal history in complete rows and retains fractional distance", function()
    -- The session is an external boundary. Do not launch a shell for this check.
    local offset = 100
    local view = setmetatable({}, terminal.TerminalView)
    View.new(view)
    view.cell_height = 20
    view.session = {
      scroll = function(_, kind, rows)
        test.equal(kind, "delta")
        offset = offset + rows
        return true
      end,
      snapshot = function() return { scrollbar = { total = 200, len = 24, offset = offset } } end,
    }
    local unused = view:autoscroll(15)
    test.equal(offset, 100)
    unused = view:autoscroll(15 + unused)
    test.equal(view.snapshot.scrollbar.offset, 101)
    test.equal(unused, 10)
    view:autoscroll(-50 + unused)
    test.equal(view.snapshot.scrollbar.offset, 99)
  end)

  local function terminal_screen(history, tracking)
    local view = setmetatable({}, terminal.TerminalView)
    View.new(view)
    view.cell_height, view.cell_width, view.native_cell_width = 20, 10, 10
    view.cols, view.rows, view.log_id, view.input_used = 80, 24, 0, true
    view.snapshot = { scrollbar = { total = 24 + history, len = 24, offset = history } }
    -- The native session owns history and encodes application input.
    local input = {}
    view.session = {
      scroll = function(_, _, rows)
        local bar = view.snapshot.scrollbar
        local before = bar.offset
        bar.offset = math.max(0, math.min(history, before + rows))
        return bar.offset ~= before
      end,
      snapshot = function() return view.snapshot end,
      mouse = function(_, action, button)
        if tracking then input[#input + 1] = { action, button } end
        return true, tracking
      end,
    }
    return view, input
  end

  test.it("sends wheel input in both directions only when the terminal has no history", function()
    local view, input = terminal_screen(0, true)
    local remainder = view:autoscroll(0.25)
    test.equal(#input, 0, "fractional movement must not send a whole wheel event")
    for _ = 1, 400 do remainder = view:autoscroll(0.25 + remainder) end
    test.ok(#input > 0, "fractional movement must accumulate into wheel input")
    for _, event in ipairs(input) do test.same(event, { "press", "five" }) end
    local before = #input
    view:autoscroll(-200)
    test.ok(#input > before, "movement above the anchor must send wheel input")
    for i = before + 1, #input do test.same(input[i], { "press", "four" }) end
    test.equal(view.snapshot.scrollbar.offset, 0)
  end)

  test.it("keeps terminal history at its boundaries without sending application input", function()
    local view, input = terminal_screen(100, true)
    view:autoscroll(200)
    test.equal(view.snapshot.scrollbar.offset, 100)
    view:autoscroll(-4000)
    test.equal(view.snapshot.scrollbar.offset, 0)
    view:autoscroll(-200)
    test.equal(view.snapshot.scrollbar.offset, 0)
    view:autoscroll(200)
    test.ok(view.snapshot.scrollbar.offset > 0, "reversal must still scroll history")
    test.equal(#input, 0)
  end)

  test.it("does not send application input when mouse reporting is off", function()
    local view, input = terminal_screen(0, false)
    view:autoscroll(200)
    view:autoscroll(-200)
    test.equal(#input, 0)
    test.equal(view.snapshot.scrollbar.offset, 0)
  end)

  test.it("keeps both Diff Sides aligned while autoscrolling one side", function()
    config.plugins.diffview.layout = "side_by_side"
    local view = diffview.open({
      contents = {
        diffview.content.text(string.rep("old line\n", 200)),
        diffview.content.text(string.rep("new line\n", 200)),
      },
      auto_reveal_first_change = false,
    }, true)
    saved.diff_view = view
    show(view)
    system.get_time = saved.get_time
    local deadline = saved.get_time() + 5
    while view.updater_idx do
      test.ok(saved.get_time() < deadline, "comparison did not finish")
      coroutine.yield(0.01)
    end
    now = saved.get_time()
    system.get_time = function() return now end
    root:update()
    start()
    core.on_event("mousemoved", 200, 320, 0, 120)
    tick()
    test.ok(view.buffer_view_a.scroll.y > 0)
    test.equal(view.buffer_view_a.scroll.y, view.buffer_view_b.scroll.y)
    test.equal(view.buffer_view_a.scroll.to.y, view.buffer_view_b.scroll.to.y)
  end)
end)
