local common = require "core.common"
local command = require "core.command"
local panes = require "core.panes"
local shell = require "core.shell"
local test = require "core.test"
local View = require "core.view"
local command_output = require "plugins.command_slots"

local function fake_capture(context)
  context.original_capture = shell.capture
  context.runs = {}
  shell.capture = function(command, opts)
    local run = { command = command, opts = opts }
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

local function write_file(path)
  local file = assert(io.open(path, "wb"))
  file:write("target\n")
  file:close()
end

test.describe("Command Output Views", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    command_output._reset_for_tests()
    fake_capture(context)
  end)

  test.after_each(function(context)
    shell.capture = context.original_capture
    panes.reset_for_tests()
    command_output._reset_for_tests()
    if context.file then pcall(os.remove, context.file) end
  end)

  test.it("presents a one-time run in the focused Pane", function(context)
    local source_pane = panes.create { factory = function() return View() end }
    local view = command_output.run_once("Write-Output hello", { cwd = "C:/work" })

    test.not_nil(view)
    test.equal(panes.count(), 1)
    test.equal(#panes.groups, 1)
    test.equal(panes.pane_for_view(view), source_pane)
    test.equal(source_pane.current_view, view)
    test.contains(view.buffer.output_text, "C:/work")
    test.contains(view.buffer.output_text, "Write-Output hello")
  end)

  test.it("streams bounded output and reports exit state", function(context)
    local view = command_output.run_once("echo hello", { cwd = "C:/work" })
    local run = context.runs[1]
    run.opts.on_output("hello\n")
    local selection = view:get_selection_state()
    run.opts.on_output("world\n")
    run.opts.on_exit { code = 3, elapsed = 0.2, truncated = true }

    test.contains(view.buffer.output_text, "hello\nworld")
    test.contains(view.buffer.output_text, "output truncated")
    test.contains(view.buffer.output_text, "exited with code 3")
    test.not_nil(selection)
  end)

  test.it("resolves output Points of Interest from the run directory", function(context)
    local root = USERDIR .. PATHSEP .. "command-output-poi-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    context.file = root .. PATHSEP .. "target.lua"
    write_file(context.file)
    local view = command_output.run_once("build", { cwd = root })
    context.runs[1].opts.on_output("target.lua:1:1: error\n")

    local points = view:get_points_of_interest { force_revalidate = true }
    test.ok(points[1] and common.path_equals(points[1].path, context.file))
    common.rm(root, true)
    context.file = nil
  end)

  test.it("continues an active run while its View is suspended", function(context)
    local view = command_output.run_once("long run")
    local pane = panes.pane_for_view(view)
    panes.present(View(), { pane = pane })
    context.runs[1].opts.on_output("background output\n")

    test.not_equal(pane.current_view, view)
    test.contains(view.buffer.output_text, "background output")
  end)

  test.it("opens an existing output View", function(context)
    local view = command_output.run_once("long run")
    local output_pane = panes.pane_for_view(view)
    panes.create { factory = function() return View() end }

    test.ok(command.perform("command_output:open"))
    test.equal(panes.active(), output_pane)
    test.equal(core.active_view, view)
  end)

  test.it("cancels an active run when its Pane closes", function(context)
    local view = command_output.run_once("long run")
    local pane = panes.pane_for_view(view)
    test.ok(panes.close(pane, { force = true }))
    test.ok(context.runs[1].cancelled)
  end)
end)
