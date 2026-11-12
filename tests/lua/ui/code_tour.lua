local core = require "core"
local test = require "core.test"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local View = require "core.view"
local command = require "core.command"

-- Seam: agent operations and the Code Tour's public View methods.
test.describe("Code Tour", function()
  local saved, root, control, tours
  local function write(name, text)
    local file = assert(io.open(root .. PATHSEP .. name, "wb"))
    file:write(text)
    file:close()
  end
  local function open(entries, key)
    local result = control:call("code_open", {
      title = "Follow the request", entries = entries, request_id = key or "tour",
    }, "test-agent")
    local deadline = system.get_time() + 30
    while result.status == "opening" do
      test.ok(system.get_time() < deadline, "Code Tour did not finish loading")
      coroutine.yield(0.01)
      result = control:call("operation_read", {operation = result.operation}, "test-agent")
    end
    if result.pane then tours[#tours + 1] = panes.find(result.pane).current_view end
    return result, result.pane and panes.find(result.pane).current_view
  end
  test.before_each(function()
    saved = {root = core.root_panel, active = core.active_view, focus = core.set_active_view}
    panes.reset_for_tests()
    core.root_panel = RootPanel()
    core.set_active_view = function(view) core.active_view = view end
    root = USERDIR .. PATHSEP .. "code-tour-" .. system.get_process_id()
    require("core.common").mkdirp(root)
    write("a.lua", "local a = 1\nlocal b = 2\nlocal c = 3\nlocal d = 4\nlocal e = 5\nlocal f = 6\nreturn a\n")
    write("b.lua", "local request = {}\nreturn request\n")
    control, tours = require("core.control").new(root), {}
  end)
  test.after_each(function()
    for _, tour in ipairs(tours) do tour:on_close() end
    panes.reset_for_tests()
    core.root_panel, core.active_view, core.set_active_view = saved.root, saved.active, saved.focus
    test.ok(test.remove_tree(root))
  end)

  test.it("shows live ranges with notes and follows the supplied order across files", function()
    local source = panes.create {factory = function() return View() end}
    local original = core.open_buffer(root .. PATHSEP .. "a.lua")
    original:insert(1, 1, "-- unsaved ")
    local result, tour = open {
      {path = "a.lua", line = 2, end_line = 3, text = "The **inputs**."},
      {path = "b.lua", line = 1},
      {path = "a.lua", line = 7},
    }
    test.equal(result.status, "ready", result.error)
    test.is_nil(result.error)
    test.equal(core.active_view, source.current_view, "Opening must keep keyboard focus")
    test.equal(tour:get_name(), "Follow the request")
    local editor = tour:get_focus_view()
    test.equal(editor.buffer, original, "The tour must reuse the open Buffer and its unsaved text")
    test.equal(editor.buffer.lines[1], "-- unsaved local a = 1\n")
    test.equal(editor.buffer.lines[2], "local b = 2\n")
    test.equal(core.buffer_registry:find(editor.buffer.abs_filename), editor.buffer)
    test.equal(require("core.file_context").view_path_target(tour).path, editor.buffer.abs_filename)
    tour.size.x, tour.size.y = 1000, 700
    tour:update()
    test.ok(#editor:get_collapsed_folds() > 0, "Unselected code must fold")
    local _, y3 = editor:get_line_screen_position(3, 1)
    local _, y4 = editor:get_line_screen_position(4, 1)
    test.ok(y4 - y3 > editor:get_line_height() * 2, "A note card must follow its range")
    editor:add_fold_region {line1 = 2, line2 = 3, collapsed = true}
    test.ok(tour:select_entry(1, false))
    test.is_nil(editor:get_collapsed_fold_at_line(2), "Selecting a section must reveal its code")
    core.set_active_view(editor)
    test.ok(command.perform("core:next_point_of_interest"))
    test.equal(tour:get_focus_view().buffer.lines[1], "local request = {}\n")
    test.equal(panes.owner_for_view(tour:get_focus_view()), tour)
    test.ok(command.perform("core:next_point_of_interest"))
    test.equal(tour:get_focus_view(), editor)
    test.equal(editor:get_selection_state().selections[1], 7)
    test.ok(command.perform("core:previous_point_of_interest"))
    test.equal(tour:get_focus_view().buffer.lines[1], "local request = {}\n")

    editor.buffer:insert(1, 1, "-- added\n")
    local state = tour:get_state()
    test.equal(state.entries[1].line, 3)
    test.equal(state.entries[1].end_line, 4)
    test.equal(state.entries[3].line, 8)
    test.equal(state.entries[1].text, "The **inputs**.")
    local restored = require("core.code_tour").from_state(state)
    tours[#tours + 1] = restored
    local deadline = system.get_time() + 30
    while not restored:get_focus_view() do
      test.ok(system.get_time() < deadline)
      coroutine.yield(0.01)
    end
    test.equal(restored:get_focus_view().buffer.lines[1], "local request = {}\n")
    editor.buffer:undo()
    editor.buffer:undo()
  end)

  test.it("refuses invalid ranges and reports missing or binary sources without opening a Pane", function()
    local source = panes.create {factory = function() return View() end}
    for _, entries in ipairs {
      {}, {{path = "a.lua", line = 4, end_line = 2}}, {{path = "a.lua", line = 0}},
    } do
      test.equal(pcall(function() open(entries, "invalid") end), false)
    end
    write("binary.dat", "abc\0def")
    for _, name in ipairs {"missing.lua", "binary.dat"} do
      local result = open({{path = name, line = 1}}, name)
      test.equal(result.status, "failed")
      test.ok(result.error)
      test.equal(#panes.ordered(), 1)
      test.equal(core.active_view, source.current_view)
    end
  end)

  test.it("keeps overlapping ranges visible and asks before closing an unsaved hidden file", function()
    panes.create {factory = function() return View() end}
    local result, tour = open {
      {path = "a.lua", line = 2, end_line = 4},
      {path = "a.lua", line = 3, text = "Inside the larger range."},
      {path = "b.lua", line = 1},
    }
    test.equal(result.status, "ready", result.error)
    local editor = tour:get_focus_view()
    for line = 2, 4 do test.is_nil(editor:get_collapsed_fold_at_line(line)) end
    local expanded = editor:get_collapsed_folds()[1]
    test.ok(expanded)
    editor:expand_fold_region(expanded)
    editor.buffer:insert(2, 1, "-- changed ")
    tour:update()
    test.equal(#editor:get_collapsed_folds(), 0, "An edit must not fold code that the user expanded")
    test.ok(tour:select_entry(3, true))
    local TextView = require "core.textview"
    local old_handler, old_enter = TextView.close_approval_handler, core.global_prompt_bar.enter
    local choice, approved
    TextView.close_approval_handler = nil
    core.global_prompt_bar.enter = function(_, _, options) choice = options end
    local ok, err = pcall(function()
      tour:can_close(function() approved = true end)
      test.ok(choice, "Closing must ask about the edited file, even while another file shows")
      test.ok(not approved)
      choice.submit(nil, {text = "Close Without Saving"})
      test.ok(approved)
    end)
    TextView.close_approval_handler, core.global_prompt_bar.enter = old_handler, old_enter
    assert(ok, err)
  end)

  test.it("skips a deleted range instead of attaching its note to other code", function()
    panes.create {factory = function() return View() end}
    local result, tour = open {
      {path = "a.lua", line = 1},
      {path = "a.lua", line = 3, end_line = 4, text = "This range will be removed."},
      {path = "b.lua", line = 2},
    }
    test.equal(result.status, "ready", result.error)
    local editor = tour:get_focus_view()
    editor.buffer:remove(3, 1, 5, 1)
    test.ok(tour:get_state().entries[2].removed)
    test.ok(tour:move_entry(1))
    test.equal(tour:get_focus_view().buffer.lines[1], "local request = {}\n")
    editor.buffer:undo()
  end)

  test.it("refuses cross-Project transfer instead of losing edits in its child Editors", function()
    panes.create {factory = function() return View() end}
    local result, tour = open {{path = "a.lua", line = 2}}
    test.equal(result.status, "ready", result.error)
    local editor = tour:get_focus_view()
    editor.buffer:insert(2, 1, "-- unsaved ")
    local copy = require("core.code_tour").from_state(tour:get_state(), {transfer = true})
    if copy then tours[#tours + 1] = copy end
    test.is_nil(copy, "Transfer cannot save or verify a Tour's child Buffers")
    test.equal(editor.buffer.lines[2], "-- unsaved local b = 2\n")
    editor.buffer:undo()
  end)
end)
