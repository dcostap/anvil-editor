local Buffer = require "core.buffer"
local core = require "core"
local common = require "core.common"
local Editor = require "core.editor"
local panes = require "core.panes"
local shell = require "core.shell"
local test = require "core.test"
local View = require "core.view"
local bar = require "core.pane_command_bar"
local command_slots = require "plugins.command_slots"
local terminal = require "plugins.terminal"

local function write_file(path)
  local file = assert(io.open(path, "wb"))
  file:write("return true\n")
  file:close()
end

test.describe("Pane Command Bar", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.original_capture = shell.capture
    context.runs = {}
    shell.capture = function(text, opts)
      local run = { text = text, opts = opts }
      function run:cancel() self.cancelled = true; return true end
      context.runs[#context.runs + 1] = run
      return run
    end
    context.root = USERDIR .. PATHSEP .. "pane-command-bar-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    context.file = context.root .. PATHSEP .. "target.lua"
    write_file(context.file)
  end)

  test.after_each(function(context)
    if core.global_prompt_bar.pane_scope then core.global_prompt_bar:exit(false) end
    shell.capture = context.original_capture
    panes.reset_for_tests()
    command_slots._reset_for_tests()
    if system.get_file_info(context.root) then common.rm(context.root, true) end
  end)

  test.it("anchors to the active Pane and cancel restores source focus", function()
    local source = View()
    local pane = panes.create { factory = function() return source end }
    pane.position = { x = 40, y = 50 }
    pane.size = { x = 500, y = 300 }
    test.ok(bar.open(pane))
    core.global_prompt_bar.size.y = 30
    core.root_panel:update_layout()

    test.equal(core.global_prompt_bar.pane_scope, pane)
    test.equal(core.global_prompt_bar.position.x, pane.position.x)
    core.global_prompt_bar:exit(false)
    test.equal(core.active_view, source)
  end)

  test.it("opens Untitled and file Editors in the source Pane", function(context)
    local source = View()
    source.current_dir = USERDIR
    local pane = panes.create { factory = function() return source end }
    test.ok(bar.execute(":edit", { pane = pane, source_view = source }))
    test.ok(pane.current_view:extends(Editor))
    test.is_nil(pane.current_view.buffer.abs_filename)

    test.ok(bar.execute(":edit " .. context.file, { pane = pane, source_view = source }))
    test.ok(common.path_equals(pane.current_view.buffer.abs_filename, context.file))
  end)

  test.it("applies File Tree target rules", function(context)
    local source = View()
    source.current_dir = context.root
    local pane = panes.create { factory = function() return source end }
    test.ok(bar.execute(":tree target.lua", { pane = pane, source_view = source }))
    test.equal(pane.current_view.root_dir, common.normalize_path(context.root))
    local entry = pane.current_view:entry_for_line(pane.current_view.buffer:get_selection(true))
    test.ok(entry and common.path_equals(entry.abs, context.file))
  end)

  test.it("opens Terminal in the current Pane with source context", function(context)
    local source = View()
    source.current_dir = context.root
    local pane = panes.create { factory = function() return source end }
    local original_open = terminal.open
    local options
    terminal.open = function(value) options = value; return View() end
    local ok = bar.execute(":terminal", { pane = pane, source_view = source })
    terminal.open = original_open

    test.ok(ok)
    test.equal(options.pane, pane)
    test.equal(options.placement, "current")
    test.equal(options.cwd, common.normalize_path(context.root))
  end)

  test.it("never sends an unknown colon command to the shell", function()
    local pane = panes.create { factory = function() return View() end }
    local original = command_slots.run_once
    local calls = 0
    command_slots.run_once = function() calls = calls + 1 end
    local ok = bar.execute(":unknown echo danger", { pane = pane })
    command_slots.run_once = original
    test.not_ok(ok)
    test.equal(calls, 0)
  end)

  test.it("runs plain input in a new end Pane from source context", function(context)
    local source = View()
    source.current_dir = context.root
    local pane = panes.create { factory = function() return source end }
    test.ok(bar.execute("Write-Output hello", { pane = pane, source_view = source }))

    test.equal(panes.count(), 2)
    test.equal(#panes.groups, 2)
    test.equal(context.runs[1].opts.cwd, common.normalize_path(context.root))
  end)

  test.it("lets non-suspendable replacement cancel the command", function(context)
    local blocker = View()
    function blocker:can_suspend() return false end
    function blocker:can_close() self.close_requested = true end
    local pane = panes.create { factory = function() return blocker end }
    test.not_ok(bar.execute(":tree " .. context.root, { pane = pane, source_view = blocker }))
    test.equal(pane.current_view, blocker)
    test.ok(blocker.close_requested)
  end)

  test.it("does not add Navigation Places when it opens and cancels", function()
    local pane = panes.create { factory = function() return View() end }
    local before = panes.history_length(pane)
    bar.open(pane)
    core.global_prompt_bar:exit(false)
    test.equal(panes.history_length(pane), before)
  end)
end)
