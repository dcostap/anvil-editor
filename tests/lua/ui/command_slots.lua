local core = require "core"
local command = require "core.command"
local config = require "core.config"
local common = require "core.common"
local process = require "core.process"
local panes = require "core.panes"
local storage = require "core.storage"
local test = require "core.test"
local View = require "core.view"
local Project = require "core.project"

local command_slots = require "plugins.command_slots"

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function write_file(path, content)
  local fp = assert(io.open(path, "wb"))
  fp:write(content or "")
  fp:close()
end

local function clear_prompt()
  if core.active_view == core.global_prompt_bar then
    core.global_prompt_bar:exit(false)
  end
end

test.describe("Command Slots", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
    context.previous_projects = core.projects
    context.previous_cwd = system.getcwd()
    context.previous_powershell_candidates = config.plugins.command_slots.powershell_candidates
    clear_prompt()
    storage.clear("command-slots")
    command_slots._reset_for_tests()
  end)

  test.after_each(function(context)
    clear_prompt()
    command_slots._reset_for_tests()
    storage.clear("command-slots")
    config.plugins.command_slots.powershell_candidates = context.previous_powershell_candidates
    if context.cleanup_views and core.root_panel and core.root_panel.root_node then
      for _, view in ipairs(context.cleanup_views) do
        local node = core.root_panel.root_node:get_node_for_view(view)
        if node then node:remove_view(core.root_panel.root_node, view) end
      end
    end
    if context.previous_projects then core.projects = context.previous_projects end
    if context.previous_cwd then system.chdir(context.previous_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      common.rm(context.temp_root, true)
    end
    if context.previous_active_view then
      core.set_active_view(context.previous_active_view)
    end
  end)

  test.it("ignores blank prompt submissions without clearing the stored command", function()
    local runs = {}
    command_slots._run_command_impl = function(slot, text)
      runs[#runs + 1] = { slot = slot.index, text = text }
    end

    command_slots.set_command(1, "Write-Output 'old'")
    test.ok(command.perform("command-slots:edit-a"))
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(core.global_prompt_bar:get_text(), "Write-Output 'old'")

    core.global_prompt_bar:set_text("")
    core.global_prompt_bar:submit()

    test.equal(command_slots.get_command(1), "Write-Output 'old'")
    test.equal(#runs, 0)
  end)

  test.it("stores and runs a nonblank command submitted from the prompt", function()
    local runs = {}
    command_slots._run_command_impl = function(slot, text)
      runs[#runs + 1] = { slot = slot.index, text = text }
    end

    test.ok(command.perform("command-slots:run-a"), "empty slot should open the prompt")
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(core.global_prompt_bar:get_text(), "")

    core.global_prompt_bar:set_text("Write-Output 'new'")
    core.global_prompt_bar:submit()

    test.equal(command_slots.get_command(1), "Write-Output 'new'")
    test.equal(#runs, 1)
    test.equal(runs[1].slot, 1)
    test.equal(runs[1].text, "Write-Output 'new'")
  end)

  test.it("shares command history suggestions across slots", function()
    command_slots.set_command(2, "Write-Output 'slot-s'")
    command_slots.record_history("Write-Output 'from-a'")
    command_slots.record_history("Get-ChildItem")

    local suggestions = command_slots.suggest_commands("Write")
    test.equal(#suggestions, 2)
    test.equal(suggestions[1].text, "Write-Output 'from-a'")
    test.equal(suggestions[2].text, "Write-Output 'slot-s'")
  end)

  test.it("keeps Command Output View text read-only while allowing internal appends", function()
    local doc = command_slots.CommandOutputDoc()
    doc:set_text("first\n")
    local original = doc:get_text(1, 1, math.huge, math.huge)

    doc:insert(1, 1, "typed ")
    doc:remove(1, 1, 1, 3)
    doc:text_input("typed")
    doc:delete_to_cursor()

    test.equal(doc:get_text(1, 1, math.huge, math.huge), original)
    doc:append("second\n")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first\nsecond\n")
    test.not_ok(doc:is_dirty())
  end)

  test.it("keeps Command Output View measurement caches valid after read-only text refreshes", function()
    config.plugins.command_slots.powershell_candidates = {}

    test.ok(command_slots.run_command(1, "Write-Output 'cache cache'"))
    local view = command_slots.slots[1].view
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 500, 200
    view.doc:set_selection(1, 1, 1, 6)

    local col1, col2 = view:get_visible_cols_range(1, 300)
    test.ok(col1 <= col2)
    test.ok(view:get_col_x_offset(1, 2) >= 0)

    view:append_text("cache cache\n")
    col1, col2 = view:get_visible_cols_range(1, 300)
    test.ok(col1 <= col2)
    test.ok(view:get_col_x_offset(1, 2) >= 0)
  end)

  test.it("only advances command output carets that were on the trailing blank line", function()
    local doc = command_slots.CommandOutputDoc()
    doc:set_text("first")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first\n")
    test.same({ 2, 1, 2, 1 }, doc.selections)

    doc:append(" second")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first second\n")
    test.same({ 2, 1, 2, 1 }, doc.selections)

    doc:append("\nthird\n")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first second\nthird\n")
    test.same({ 3, 1, 3, 1 }, doc.selections)

    doc:set_selection(1, 3, 1, 3)
    doc:append("fourth\n")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first second\nthird\nfourth\n")
    test.same({ 1, 3, 1, 3 }, doc.selections)
    test.not_ok(doc:is_dirty())
  end)

  test.it("extracts common real file location Points of Interest from output", function(context)
    context.temp_root = join_path(USERDIR, "command-output-poi")
    test.ok(common.mkdirp(join_path(context.temp_root, "src")))
    test.ok(common.mkdirp(join_path(context.temp_root, "nested")))
    local main_c = join_path(context.temp_root, "src", "main.c")
    local rust = join_path(context.temp_root, "src", "main.rs")
    local cpp = join_path(context.temp_root, "nested", "file.cpp")
    local py = join_path(context.temp_root, "src", "main.py")
    write_file(main_c, "int main(void) { return 0; }\n")
    write_file(rust, "fn main() {}\n")
    write_file(cpp, "int x;\n")
    write_file(py, "print('x')\n")
    core.projects = { Project(context.temp_root) }

    local output = table.concat({
      "src/main.c:10:2: error: nope",
      "--> src/main.rs:11:3",
      "nested/file.cpp(12,4): error C1234: nope",
      "File \"src/main.py\", line 13",
      main_c .. ":14:5: error: absolute",
      "src/main.c:15: error: missing column",
      "File \"src/main.py\", line 16, column 7",
      "both src/main.c:20:1 and src/main.rs:21:2",
      "file:///" .. main_c .. ":22:2",
      "file:src/main.c:23:2",
      "(file:src/main.c:24:2)",
      "x:src/main.c:25:2",
      "jar:file:src/main.c:26:2",
      "http://example.test/src/main.c:1:2",
      "missing.c:99:1",
    }, "\n")
    local points = command_slots.extract_output_location_pois(output, { root = context.temp_root })

    test.equal(#points, 9)
    test.ok(common.path_equals(points[1].path, main_c))
    test.equal(points[1].target_line, 10)
    test.equal(points[1].target_col, 2)
    test.ok(common.path_equals(points[2].path, rust))
    test.ok(common.path_equals(points[3].path, cpp))
    test.ok(common.path_equals(points[4].path, py))
    test.equal(points[4].target_col, 1)
    test.ok(common.path_equals(points[5].path, main_c))
    test.equal(points[5].target_line, 14)
    test.equal(points[5].target_col, 5)
    test.ok(common.path_equals(points[6].path, main_c))
    test.equal(points[6].target_line, 15)
    test.equal(points[6].target_col, 1)
    test.ok(common.path_equals(points[7].path, py))
    test.equal(points[7].target_line, 16)
    test.equal(points[7].target_col, 7)
    test.ok(common.path_equals(points[8].path, main_c))
    test.ok(common.path_equals(points[9].path, rust))
  end)

  test.it("navigates Command Output View POIs and activates them in the Left Pane", function(context)
    context.temp_root = join_path(USERDIR, "command-output-activate-poi")
    test.ok(common.mkdirp(join_path(context.temp_root, "src")))
    local target = join_path(context.temp_root, "src", "main.c")
    write_file(target, "one\ntwo\nthree\n")
    core.projects = { Project(context.temp_root) }
    system.chdir(context.temp_root)

    local view = command_slots.CommandOutputView({ label = "T" })
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 500, 200
    view.doc:set_text("header\nsrc/main.c:2:3: error: nope\n")
    view.doc:set_selection(1, 1)
    core.set_active_view(view)

    test.ok(command.perform("poi:next"))
    test.same(view.doc.selections, { 2, 1, 2, 1 })
    test.ok(command.perform("poi:activate"))

    local left_node = core.root_panel and core.root_panel:get_left_pane()
    local left = left_node and left_node.active_view
    context.cleanup_views = { left }
    test.equal(core.active_view, left)
    test.ok(left and left.doc and common.path_equals(left.doc.abs_filename, target))
    test.same(left:get_selection_state().selections, { 2, 3, 2, 3 })
  end)

  test.it("activates Command Output View POIs in the Right Pane on the right activation command", function(context)
    context.temp_root = join_path(USERDIR, "command-output-activate-side-poi")
    test.ok(common.mkdirp(join_path(context.temp_root, "src")))
    local target = join_path(context.temp_root, "src", "side.c")
    write_file(target, "one\ntwo\n")
    core.projects = { Project(context.temp_root) }
    system.chdir(context.temp_root)

    local view = command_slots.CommandOutputView({ label = "T" })
    view.doc:set_text("src/side.c:2:1: error: nope\n")
    view.doc:set_selection(1, 1)
    core.set_active_view(view)

    test.ok(command.perform("poi:activate-right"))

    test.ok(core.active_view and core.active_view.doc and common.path_equals(core.active_view.doc.abs_filename, target))
    test.equal(panes.pane_for_view(core.active_view), "right")
    context.cleanup_views = { core.active_view }
  end)

  test.it("does not expose language or legacy Git navigation commands in Command Output Views", function()
    local view = command_slots.CommandOutputView({ label = "T" })
    view.doc:set_text("anything\n")
    core.set_active_view(view)

    test.not_ok(command.is_valid("language:show-references"))
    test.not_ok(command.is_valid("language:go-to-declaration"))
    test.not_ok(command.is_valid("gitdiff:next-change"))
    test.not_ok(command.is_valid("gitdiff:previous-change"))
  end)

  test.it("does not activate stale Command Output POIs whose files disappeared", function(context)
    context.temp_root = join_path(USERDIR, "command-output-stale-poi")
    test.ok(common.mkdirp(join_path(context.temp_root, "src")))
    local target = join_path(context.temp_root, "src", "gone.c")
    write_file(target, "gone\n")
    core.projects = { Project(context.temp_root) }

    local view = command_slots.CommandOutputView({ label = "T" })
    view.doc:set_text("src/gone.c:1:1: error\n")
    local poi = view:get_points_of_interest()[1]
    test.ok(poi)
    test.ok(common.rm(target))

    test.equal(#view:get_points_of_interest({ force_revalidate = true }), 0)
    test.not_ok(view:activate_point_of_interest(poi))

    write_file(target, "back\n")
    local refreshed = view:get_points_of_interest({ force_revalidate = true })
    test.equal(#refreshed, 1)
    test.ok(common.path_equals(refreshed[1].path, target))
  end)

  test.it("draws Command Output underlines only for detected Text POI bounds", function(context)
    context.temp_root = join_path(USERDIR, "command-output-draw-poi")
    test.ok(common.mkdirp(join_path(context.temp_root, "src")))
    local target = join_path(context.temp_root, "src", "main.c")
    write_file(target, "x\n")
    core.projects = { Project(context.temp_root) }

    local view = command_slots.CommandOutputView({ label = "T" })
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 500, 200
    view.doc:set_text("src/main.c:1:1: ok\nmissing.c:1:1\n")

    local rects = {}
    local old_draw_rect = renderer.draw_rect
    renderer.draw_rect = function(x, y, w, h, color)
      rects[#rects + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    view:draw_poi_underlines(1, 0, 0)
    view:draw_poi_underlines(2, 0, view:get_line_height())
    renderer.draw_rect = old_draw_rect

    test.equal(#rects, 1)
    test.ok(rects[1].w > 0)
  end)

  test.it("keeps focus in the starting pane while stepping through Right Pane Command Output POIs", function(context)
    context.temp_root = join_path(USERDIR, "command-output-side-poi")
    test.ok(common.mkdirp(join_path(context.temp_root, "src")))
    local first = join_path(context.temp_root, "src", "first.c")
    local second = join_path(context.temp_root, "src", "second.c")
    write_file(first, "one\n")
    write_file(second, "one\ntwo\n")
    core.projects = { Project(context.temp_root) }
    system.chdir(context.temp_root)

    config.plugins.command_slots.powershell_candidates = {}
    test.ok(command_slots.run_command(1, "echo"))
    local panel = command_slots.output_panel
    local output = command_slots.slots[1].view
    panel:select_slot(1, { focus = false })
    output.poi_cache = nil
    output.doc:set_text("header\nsrc/first.c:1:1\nsrc/second.c:2:1\n")
    output.doc:set_selection(1, 1)

    local left_before = panes.show("left", { focus = true })
    test.ok(left_before)
    core.set_active_view(left_before)
    test.ok(command.perform("poi:right-next-activate"))
    local left_node = core.root_panel and core.root_panel:get_left_pane()
    test.equal(core.active_view, left_node and left_node.active_view)
    test.ok(core.active_view and core.active_view.doc and common.path_equals(core.active_view.doc.abs_filename, first))
    test.same(output.doc.selections, { 2, 1, 2, 1 })
    context.cleanup_views = { left_node and left_node.active_view }

    core.set_active_view(output)
    test.ok(command.perform("poi:right-next-activate"))
    test.equal(core.active_view, output)
    test.same(output.doc.selections, { 3, 1, 3, 1 })
    if left_node and left_node.active_view then
      context.cleanup_views[#context.cleanup_views + 1] = left_node.active_view
    end
  end)

  test.it("does not navigate hidden Right Pane Command Output POIs from the Left Pane", function(context)
    context.temp_root = join_path(USERDIR, "command-output-hidden-side-poi")
    test.ok(common.mkdirp(join_path(context.temp_root, "src")))
    local target = join_path(context.temp_root, "src", "hidden.c")
    write_file(target, "one\n")
    core.projects = { Project(context.temp_root) }
    system.chdir(context.temp_root)

    config.plugins.command_slots.powershell_candidates = {}
    test.ok(command_slots.run_command(1, "echo"))
    local output = command_slots.slots[1].view
    output.poi_cache = nil
    output.doc:set_text("header\nsrc/hidden.c:1:1\n")
    output.doc:set_selection(1, 1)
    panes.hide_right(false)
    local left_before = panes.show("left", { focus = true })
    test.ok(left_before)
    core.set_active_view(left_before)

    test.ok(command.perform("poi:right-next-activate"))

    test.equal(core.active_view, left_before)
    test.same(output.doc.selections, { 1, 1, 1, 1 })
  end)

  test.it("preserves command output horizontal scroll while following appended output", function()
    local view = command_slots.CommandOutputView({ label = "T" })
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 120, 60
    view.doc:set_text("first")
    view.scroll.x, view.scroll.to.x = 80, 80

    view:append_text(" second\nthird\n")

    test.equal(view.scroll.x, 80)
    test.equal(view.scroll.to.x, 80)
    test.same({ 3, 1, 3, 1 }, view.doc.selections)
  end)

  test.it("does not scroll command output when the caret is not on the trailing blank line", function()
    local view = command_slots.CommandOutputView({ label = "T" })
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 120, 60
    view.doc:set_text("one\ntwo")
    view.doc:set_selection(1, 2, 1, 2)
    view.scroll.x, view.scroll.to.x = 80, 80
    view.scroll.y, view.scroll.to.y = 40, 40

    view:append_text("\nthree\n")

    test.equal(view.scroll.x, 80)
    test.equal(view.scroll.to.x, 80)
    test.equal(view.scroll.y, 40)
    test.equal(view.scroll.to.y, 40)
    test.same({ 1, 2, 1, 2 }, view.doc.selections)
  end)

  test.it("shows one tabbed Command Output panel without stealing Left Pane focus", function()
    config.plugins.command_slots.powershell_candidates = {}
    if panes.pane_for_view(core.active_view) == "right" then
      panes.show("left", { focus = true })
    end
    local previous = core.active_view

    test.ok(command_slots.run_command(1, "Write-Output 'one'"))

    test.equal(core.active_view, previous)
    test.ok(command_slots.output_panel and command_slots.output_panel.command_output_panel)
    test.ok(panes.contains_view("right", command_slots.output_panel))
    test.equal(command_slots.output_panel.active_slot_index, 1)
    test.equal(command_slots.slots[1].view:get_name(), "A: Write-Output 'one'")
    test.equal(command_slots.output_panel:slot_view(command_slots.slots[2]):get_name(), "S: No commands")
  end)

  test.it("focuses Command Output panel on demand", function()
    if panes.pane_for_view(core.active_view) == "right" then
      panes.show("left", { focus = true })
    end

    test.ok(command.perform("command-slots:focus-output"))

    test.ok(command_slots.output_panel and command_slots.output_panel.command_output_panel)
    test.ok(panes.contains_view("right", command_slots.output_panel))
    test.ok(core.active_view and core.active_view.command_output_view)
    test.equal(core.active_view.slot.index, command_slots.output_panel.active_slot_index)
  end)

  test.it("restores focus to the visible Command Output slot after an unfocused run switches tabs", function()
    config.plugins.command_slots.powershell_candidates = {}
    if panes.pane_for_view(core.active_view) == "right" then
      panes.show("left", { focus = true })
    end
    local previous = core.active_view

    test.ok(command_slots.run_command(1, "Write-Output 'first'"))
    local panel = command_slots.output_panel
    panel:select_slot(1, { focus = true })
    test.equal(core.active_view, command_slots.slots[1].view)

    if previous then core.set_active_view(previous) end
    test.ok(command_slots.run_command(2, "Write-Output 'second'"))
    test.equal(core.active_view, previous)
    test.equal(panel.active_slot_index, 2)

    panes.show("right", { focus = true })

    test.equal(core.active_view, command_slots.slots[2].view)
  end)

  test.it("focuses Command Output when a command is run from another Right Pane view", function()
    config.plugins.command_slots.powershell_candidates = {}
    local dummy = View()
    panes.register_view("right", "command-slots-test-right", dummy)
    panes.show("right", { view = dummy, focus = true })
    test.equal(core.active_view, dummy)

    test.ok(command_slots.run_command(2, "Write-Output 'side'"))

    test.ok(core.active_view and core.active_view.command_output_view)
    test.equal(core.active_view.slot.index, 2)
    test.equal(command_slots.output_panel.active_slot_index, 2)
    panes.remove_view(dummy, { force = true, focus_left = false })
  end)

  test.it("navigates per-slot Command Output History and new runs switch to newest", function()
    config.plugins.command_slots.powershell_candidates = {}

    test.ok(command_slots.run_command(1, "Write-Output 'first'"))
    test.ok(command_slots.run_command(1, "Write-Output 'second'"))
    local slot = command_slots.slots[1]
    core.set_active_view(slot.view)

    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "second")
    test.ok(command.perform("command-slots:history-previous"))
    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "first")
    test.equal(slot.output_history_index, 1)

    test.ok(command.perform("command-slots:history-next"))
    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "second")
    test.equal(slot.output_history_index, 2)

    test.ok(command.perform("command-slots:history-previous"))
    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "first")
    test.ok(command_slots.run_command(1, "Write-Output 'third'"))
    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "third")
    test.equal(slot.output_history_index, #slot.output_history)
  end)

  test.it("explicit Command Output commands switch Command Output slots internally", function()
    config.plugins.command_slots.powershell_candidates = {}

    test.ok(command_slots.run_command(1, "Write-Output 'first'"))
    local panel = command_slots.output_panel
    panel:select_slot(1, { focus = true })
    test.equal(core.active_view, command_slots.slots[1].view)

    test.ok(command.perform("command-slots:switch-next"))

    test.equal(panel.active_slot_index, 2)
    test.equal(core.active_view, command_slots.slots[2].view)
    test.equal(command_slots.slots[2].view:get_name(), "S: No commands")
  end)

  test.it("sends payloads to disposable warm PowerShell workers and closes stdin", function()
    test.skip_if(PLATFORM ~= "Windows", "Command Slots use PowerShell on Windows")

    local token = "warm-test"
    local marker = "__ANVIL_COMMAND_SLOT_DONE__" .. token .. ":"
    local proc = process.start({ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command_slots._build_powershell_controller() }, {
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_STDOUT,
    })
    test.not_nil(proc, "expected Windows PowerShell to start")

    local payload = command_slots._build_powershell_payload("cmd.exe /d /s /c sort; Write-Output 'slot-payload-ok'", core.root_project().path, token)
    test.not_nil(proc.stdin:write(payload))
    test.not_nil(proc.stdin:close())

    local output = ""
    local deadline = system.get_time() + 4
    while system.get_time() < deadline and not output:find(marker, 1, true) do
      local chunk = proc:read_stdout(4096)
      if chunk and chunk ~= "" then
        output = output .. chunk
      elseif chunk == nil and not proc:running() then
        break
      else
        coroutine.yield(0.01)
      end
    end
    pcall(proc.kill, proc)

    test.contains(output, "slot-payload-ok")
    test.contains(output, marker .. "0")
  end)

  test.it("strips ANSI control sequences from command output", function()
    local slot = command_slots.slots[1]
    local chunks = {}
    slot.view = {
      append_text = function(_, text)
        chunks[#chunks + 1] = text
      end,
    }
    slot.running = true
    slot.token = "ansi"
    slot.start_time = system.get_time()
    slot.pending_output = ""
    slot.output_bytes = 0
    slot.truncated = false

    test.ok(command_slots._process_worker_output(slot, "\27[32;1mgreen\27[0m\n__ANVIL_COMMAND_SLOT_DONE__ansi:0\n"))

    local output = table.concat(chunks)
    test.contains(output, "green\n")
    test.is_nil(output:find("\27", 1, true))
    test.is_nil(output:find("[32;1m", 1, true))
  end)

  test.it("strips the private completion marker and appends an exit footer", function()
    local slot = command_slots.slots[1]
    local chunks = {}
    slot.view = {
      append_text = function(_, text)
        chunks[#chunks + 1] = text
      end,
    }
    slot.running = true
    slot.token = "tok"
    slot.start_time = system.get_time()
    slot.pending_output = ""
    slot.output_bytes = 0
    slot.truncated = false

    local marker = "__ANVIL_COMMAND_SLOT_DONE__tok:"
    test.not_ok(command_slots._process_worker_output(slot, "hello\n" .. marker:sub(1, 12)))
    test.ok(slot.running)
    test.ok(command_slots._process_worker_output(slot, marker:sub(13) .. "7\n"))

    local output = table.concat(chunks)
    test.contains(output, "hello\n")
    test.contains(output, "exited with code 7")
    test.is_nil(output:find("__ANVIL_COMMAND_SLOT_DONE__", 1, true))
    test.not_ok(slot.running)
  end)
end)
