local command = require "core.command"
local common = require "core.common"
local core = require "core"
local panes = require "core.panes"
local shell = require "core.shell"
local storage = require "core.storage"
local test = require "core.test"
local View = require "core.view"
local command_slots = require "plugins.command_slots"

local function install_fake_shell(context)
  context.original_capture = shell.capture
  context.runs = {}
  shell.capture = function(text, opts)
    local run = { text = text, opts = opts }
    function run:cancel()
      if self.cancelled then return false end
      self.cancelled = true
      opts.on_exit { cancelled = true, elapsed = 0, truncated = false }
      return true
    end
    context.runs[#context.runs + 1] = run
    return run
  end
end

local function finish(run, text, code)
  if text then run.opts.on_output(text) end
  run.opts.on_exit { code = code or 0, elapsed = 0.1, truncated = false }
end

test.describe("Command Slots", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    command_slots._reset_for_tests()
    storage.clear("command-slots")
    install_fake_shell(context)
  end)

  test.after_each(function(context)
    shell.capture = context.original_capture
    if context.original_root_project then core.root_project = context.original_root_project end
    if context.link_root and system.get_file_info(context.link_root) then
      local ok, err = common.rm(context.link_root, true)
      test.ok(ok, err)
    end
    panes.reset_for_tests()
    command_slots._reset_for_tests()
    storage.clear("command-slots")
  end)

  test.it("stores Project commands and shares command suggestions", function()
    command_slots.set_command(1, "Write-Output one")
    command_slots.set_command(2, "Write-Output two")
    command_slots.record_history("Get-ChildItem")
    test.equal(command_slots.get_command(1), "Write-Output one")
    local suggestions = command_slots.suggest_commands("Write")
    test.equal(#suggestions, 2)
  end)

  test.it("creates one Quick Command Output View and reuses Slot A", function(context)
    local first = command_slots.run_command(1, "first")
    local pane = panes.pane_for_view(first)
    local quick_output = pane.current_view
    finish(context.runs[1], "one\n")
    local second = command_slots.run_command(1, "second")

    test.equal(second, first)
    test.equal(panes.pane_for_view(second), pane)
    test.equal(pane.current_view, quick_output)
    test.equal(quick_output.quick_command_output_view, true)
    test.equal(quick_output:get_name(), "Quick Command Output")
    test.contains(quick_output:get_tab_bar():get_item_title(first), "A: second")
    test.equal(panes.count(), 1)
    test.equal(#command_slots.slots[1].output_history, 2)
  end)

  test.it("runs Slots A and S independently and reruns only A", function(context)
    command_slots.run_command(1, "a-one")
    local a_first = context.runs[1]
    command_slots.run_command(2, "s-one")
    local s_first = context.runs[2]
    command_slots.run_command(1, "a-two")
    local quick_output = panes.pane_for_view(command_slots.slots[1].view).current_view

    test.ok(a_first.cancelled)
    test.not_ok(s_first.cancelled)
    test.not_equal(command_slots.slots[1].view, command_slots.slots[2].view)
    test.equal(panes.pane_for_view(command_slots.slots[1].view), panes.pane_for_view(command_slots.slots[2].view))
    test.equal(quick_output:get_surface_focus_targets()[1], command_slots.slots[1].view)
    test.equal(quick_output:get_surface_focus_targets()[2], command_slots.slots[2].view)
    test.equal(panes.count(), 1)
  end)

  test.it("restores a suspended Quick Command Output View when rerun", function(context)
    local output = command_slots.run_command(1, "first")
    local pane = panes.pane_for_view(output)
    local quick_output = pane.current_view
    finish(context.runs[1], "done\n")
    panes.present(View(), { pane = pane })

    local restored = command_slots.run_command(1, "second")
    test.equal(restored, output)
    test.equal(pane.current_view, quick_output)
    test.equal(core.active_view, output)
  end)

  test.it("clears stale Pane identity after close and recreates it", function(context)
    local output = command_slots.run_command(1, "first")
    local old_pane = panes.pane_for_view(output)
    panes.close(old_pane, { force = true })
    local replacement = command_slots.run_command(1, "second")

    test.not_equal(panes.pane_for_view(replacement), old_pane)
    test.equal(panes.count(), 1)
  end)

  test.it("keeps output run history distinct from Pane Navigation History", function(context)
    local output = command_slots.run_command(1, "first")
    finish(context.runs[1], "first-output\n")
    command_slots.run_command(1, "second")
    finish(context.runs[2], "second-output\n")
    local pane = panes.pane_for_view(output)
    local pane_history_before = panes.history_length(pane)

    test.ok(command.perform("quick_command_output:history_previous"))
    test.contains(output.buffer.output_text, "first-output")
    test.equal(#command_slots.slots[1].output_history, 2)
    test.ok(panes.history_length(pane) > pane_history_before)
  end)

  test.it("keeps slot runtime state scoped to the Root Project", function(context)
    context.original_root_project = core.root_project
    local project = { path = "C:/project-one" }
    core.root_project = function() return project end
    command_slots.run_command(1, "one")
    local first_view = command_slots.slots[1].view

    project = { path = "C:/project-two" }
    command_slots.run_command(1, "two")
    local second_view = command_slots.slots[1].view

    test.not_equal(first_view, second_view)
    test.equal(command_slots.slots[1].project_path, "C:/project-two")
  end)

  test.it("opens the project Quick Command Output View without rerunning", function(context)
    local output = command_slots.run_command(1, "first")
    local output_pane = panes.pane_for_view(output)
    local quick_output = output_pane.current_view
    panes.create { factory = function() return View() end }

    test.ok(command.perform("quick_command_output:open"))
    test.equal(#context.runs, 1)
    test.equal(panes.active(), output_pane)
    test.equal(output_pane.current_view, quick_output)
    test.equal(core.active_view, output)
  end)

  test.it("cycles through all permanent Slot tabs and the sibling Pane", function(context)
    local output = command_slots.run_command(1, "first")
    local output_pane = panes.pane_for_view(output)
    local quick_output = output_pane.current_view
    local sibling = panes.split(output_pane, "right", {
      factory = function() return View() end,
      focus = false,
    })
    local targets = quick_output:get_surface_focus_targets()

    test.equal(#targets, 4)
    test.ok(quick_output:focus_surface_target(targets[1]))
    for index = 2, 4 do
      test.ok(command.perform("pane:focus_local_next"))
      test.equal(core.active_view, targets[index])
    end
    test.ok(command.perform("pane:focus_local_next"))
    test.equal(panes.active(), sibling)
    test.ok(command.perform("pane:focus_local_next"))
    test.equal(core.active_view, targets[1])
  end)

  test.it("selects a permanent Slot tab with the mouse", function(context)
    local output = command_slots.run_command(1, "first")
    local quick_output = panes.pane_for_view(output).current_view
    quick_output.position.x, quick_output.position.y = 10, 20
    quick_output.size.x, quick_output.size.y = 800, 500
    quick_output:update()
    local x, y, w, h = quick_output:get_tab_bar():get_tab_rect(3)

    test.ok(quick_output:on_mouse_pressed(1, x + w / 2, y + h / 2, 1))
    test.equal(core.active_view, quick_output:get_surface_focus_targets()[3])
  end)

  test.it("detects JAI, rustc, and clang file links", function(context)
    context.original_root_project = core.root_project
    local root = USERDIR .. PATHSEP .. "command-slot-links-" .. system.get_process_id()
    context.link_root = root
    test.ok(common.mkdirp(root .. PATHSEP .. "game_platform_windows"))
    local files = {
      root .. PATHSEP .. "editor.jai",
      root .. PATHSEP .. "game_platform_windows" .. PATHSEP .. "main.rs",
      root .. PATHSEP .. "sdl_asteroids.cpp",
    }
    for _, path in ipairs(files) do
      local fp = assert(io.open(path, "wb"))
      fp:write("test\n")
      fp:close()
    end
    core.root_project = function() return { path = root } end

    local points = command_slots.extract_output_location_pois(table.concat({
      "// JAI link format:   " .. files[1]:gsub("\\", "/") .. ":4801,5",
      "// rustc link format: game_platform_windows/main.rs:6:1",
      "// clang link format: sdl_asteroids.cpp:1:10",
    }, "\n"), { root = root })

    test.equal(#points, 3)
    test.same({ points[1].target_line, points[1].target_col }, { 4801, 5 })
    test.same({ points[2].target_line, points[2].target_col }, { 6, 1 })
    test.same({ points[3].target_line, points[3].target_col }, { 1, 10 })
  end)
end)
