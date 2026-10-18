local core = require "core"
local panes = require "core.panes"
local scale = require "plugins.scale"
local Workload = require "core.perf_workloads"
local test = require "core.test"

test.describe("Markdown caret burst benchmark", function()
  local path, old_scale, old_code_scale, active_view, force_focus

  test.before_each(function()
    old_scale, old_code_scale = scale.get(), scale.get_code()
    active_view = core.active_view
    force_focus = active_view and active_view.force_focus
    if active_view then active_view.force_focus = false end
    panes.reset_for_tests()
    path = USERDIR .. PATHSEP .. "scene.md"
    local file = assert(io.open(path, "wb"))
    for line = 1, 51 do file:write("Line ", line, "\n") end
    file:close()
  end)

  test.after_each(function()
    panes.reset_for_tests()
    if active_view then
      active_view.force_focus = force_focus
      core.set_active_view(active_view)
    else
      core.active_view = nil
    end
    scale.set(old_scale)
    scale.set_code(old_code_scale)
    os.remove(path)
  end)

  test.it("moves only the focused Pane through each burst without editing text", function()
    local workload = Workload.new({ kind = "editor", content = "markdown", lines = 51,
      wrap = true, code_scale = 1, action = "caret-burst", burst_count = 23 }, USERDIR)
    workload:setup()
    local ordered = panes.ordered()
    test.equal(#ordered, 3)
    core.root_panel:update()
    local deadline = system.get_time() + 5
    while not workload:setup_ready() and system.get_time() < deadline do
      require("core.worker_pool").current_system():drain({ max_ms = 5, max_messages = 64 })
      for _, pane in ipairs(ordered) do
        require("core.linewrapping").complete_async_reconstruction(pane.current_view)
      end
      system.sleep(0.001)
    end
    test.ok(workload:setup_ready())
    panes.focus(panes.pane_for_view(workload.view))
    core.set_active_view(workload.view)
    local inactive = { ordered[1].current_view:get_selection_state(),
      ordered[2].current_view:get_selection_state() }
    local text = workload.view.buffer:get_text(1, 1, math.huge, math.huge)

    workload:dispatch(1)
    test.ok(workload:action_ready())
    test.equal(workload.view:get_selection_state().selections[1], 31)
    workload:dispatch(2)
    test.ok(workload:action_ready())
    test.equal(workload.view:get_selection_state().selections[1], 8)
    test.equal(workload.view.buffer:get_text(1, 1, math.huge, math.huge), text)
    test.same(ordered[1].current_view:get_selection_state(), inactive[1])
    test.same(ordered[2].current_view:get_selection_state(), inactive[2])
    test.equal(core.active_view, workload.view)
    local state = workload:state()
    test.equal(state.editor_key_presses, 46)
    test.equal(state.editor_key_releases, 46)
    test.equal(state.editor_visible_panes, 3)
  end)
end)
