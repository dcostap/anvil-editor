local core = require "core"
local config = require "core.config"
local panes = require "core.panes"
local Scene = require "core.perf_scene"
local support = require "scenes.support"
local test = require "core.test"

local function select_line(view)
  return view:get_selection_state().selections[1]
end

test.describe("Markdown navigation benchmark", function()
  local root, active, transitions

  test.before_each(function()
    root = USERDIR .. PATHSEP .. "navigation-scene-" .. system.get_process_id()
    test.ok(require("core.common").mkdirp(root))
    local file = assert(io.open(root .. PATHSEP .. "note.md", "wb"))
    for index = 1, 40 do
      file:write("## Section ", index, "\n\nA **formatted** paragraph.\nMore text.\n\n")
    end
    file:close()
    active, transitions = core.active_view, config.transitions
    panes.reset_for_tests()
    config.transitions = false
  end)

  test.after_each(function()
    panes.reset_for_tests()
    core.active_view = active
    config.transitions = transitions
    test.ok(test.remove_tree(root))
  end)

  test.it("checks destinations and a fresh visible draw after every navigation action", function()
    local workload = Scene.new({ scene = "markdown_navigation", mode = "navigation",
      note = "note.md", line = 65, previous_line = 62, far_line = 155, burst_count = 23 }, root)
    workload:setup()
    support.wait_until(function()
      core.root_panel:update()
      return workload:setup_ready()
    end, 30)
    local view = workload.view
    local text = view.buffer:get_text(1, 1, math.huge, math.huge)
    -- Repeat the complete sequence. Later actions must not reuse an earlier draw.
    for index = 1, 12 do
      local before = select_line(view)
      workload:dispatch(index)
      test.not_ok(workload:action_drawn(), "the previous frame cannot complete a new action")
      support.wait_until(function()
        core.root_panel:update()
        return workload:action_ready()
      end, 30)
      local phase = (index - 1) % 6 + 1
      if phase == 1 then test.equal(select_line(view), 155) end
      if phase == 2 or phase == 4 then test.equal(select_line(view), 65) end
      if phase == 3 then test.equal(select_line(view), 62) end
      if phase == 5 then test.ok(select_line(view) > before) end
      if phase == 6 then test.ok(select_line(view) < before) end
      test.not_ok(workload:action_drawn(), "readiness alone does not prove a draw")
      renderer.begin_frame(core.window)
      core.root_panel:draw()
      renderer.end_frame()
      test.ok(workload:action_drawn(), "the target line must draw")
    end
    test.equal(view.buffer:get_text(1, 1, math.huge, math.huge), text)
    test.equal(core.active_view, view)
    test.equal(#panes.ordered(), 1)
  end)
end)
