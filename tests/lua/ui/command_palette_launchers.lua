local command = require "core.command"
local common = require "core.common"
local core = require "core"
local panes = require "core.panes"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local View = require "core.view"

local command_slots = require "plugins.command_slots"
local filetree = require "plugins.filetree"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local terminal = require "plugins.terminal"

local function set_query(picker, text)
  picker.input:set_text(text)
  picker.current_query_key = nil
  picker.force_refresh = true
  picker.dirty = true
  picker:refresh(text)
end

test.describe("Command Palette View launchers", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.projects = core.projects
    context.cwd = system.getcwd()
    context.terminal_open = terminal.open
    context.run_once = command_slots.run_once
    context.root = common.normalize_path(USERDIR .. PATHSEP
      .. "command-palette-launchers-" .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000))
    context.folder = context.root .. PATHSEP .. "outside"
    context.file = context.folder .. PATHSEP .. "file.txt"
    test.ok(common.mkdirp(context.folder))
    local fp = assert(io.open(context.file, "wb"))
    fp:write("test\n")
    fp:close()
    core.projects = { Project(context.root) }
    project_paths.configure_project {}
    fuzzy_searcher._test.clear_prompt_history()
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    terminal.open = context.terminal_open
    command_slots.run_once = context.run_once
    panes.reset_for_tests()
    project_paths.configure_project {}
    core.projects = context.projects
    if context.cwd then pcall(system.chdir, context.cwd) end
    if system.get_file_info(context.root) then
      local ok, err = common.rm(context.root, true)
      test.ok(ok, err)
    end
  end)

  test.it("shows user-facing launcher metadata in the Command Palette", function()
    fuzzy_searcher.open(">file tree path")
    local picker = core.fuzzy_searcher_active_view
    local found
    for _, result in ipairs(picker.results) do
      if result.command == "filetree:open-path" then found = result; break end
    end
    test.not_nil(found)
    test.equal(found.label, "Open File Tree at Path…")
    test.equal(found.info, "Select any existing folder without changing the Root Project")
    test.equal(command.get_metadata(found.command).supports_placement, true)
  end)

  test.it("reuses a matching File Tree from the source Pane history", function(context)
    local source = View()
    local pane = panes.create { factory = function() return source end }
    local invocation = { source_pane = pane, source_view = source, placement = "current" }

    test.ok(command.perform_with_context("filetree:open-project-root", invocation))
    local tree = pane.current_view
    test.equal(tree.root_dir, common.normalize_path(context.root))
    local replacement = View()
    panes.present(replacement, { pane = pane })

    invocation.source_view = replacement
    test.ok(command.perform_with_context("filetree:open-project-root", invocation))
    test.equal(pane.current_view, tree)
  end)

  test.it("uses alternate Command Palette activation for split-capable Views", function(context)
    local source = View()
    panes.create { factory = function() return source end }
    fuzzy_searcher.open(">file tree project root")
    local picker = core.fuzzy_searcher_active_view
    for index, result in ipairs(picker.results) do
      if result.command == "filetree:open-project-root" then picker.selected = index; break end
    end
    picker:confirm(true)

    test.equal(panes.count(), 2)
    local found
    for _, pane in ipairs(panes.ordered()) do
      if pane.current_view.root_dir
          and common.path_equals(pane.current_view.root_dir, context.root) then
        found = pane.current_view
      end
    end
    test.not_nil(found)
  end)

  test.it("selects only existing folders for a File Tree root", function(context)
    local source = View()
    source.current_dir = context.root
    local pane = panes.create { factory = function() return source end }
    test.ok(command.perform_with_context("filetree:open-path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local picker = core.fuzzy_searcher_active_view
    set_query(picker, "@" .. context.folder)
    for _, result in ipairs(picker.results) do
      if not result.header then
        test.ok(result.is_folder)
        test.not_equal(result.kind, "create_path")
      end
    end
    test.ok(#picker.results > 0)
    picker.selected = 1
    picker:confirm(false)

    test.equal(pane.current_view.root_dir, common.normalize_path(context.folder))
    test.equal(core.root_project().path, common.normalize_path(context.root))
  end)

  test.it("opens a Terminal at a selected folder with split placement", function(context)
    local source = View()
    local pane = panes.create { factory = function() return source end }
    local options
    terminal.open = function(value) options = value; return View() end
    test.ok(command.perform_with_context("terminal:open-path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local picker = core.fuzzy_searcher_active_view
    set_query(picker, "@" .. context.folder)
    picker.selected = 1
    picker:confirm(true)

    test.equal(options.cwd, common.normalize_path(context.folder))
    test.equal(options.pane, pane)
    test.equal(options.placement, "split")
  end)

  test.it("runs shell text only after explicit Shell mode activation", function(context)
    local source = View()
    source.current_dir = context.folder
    local pane = panes.create { factory = function() return source end }
    local run
    command_slots.run_once = function(text, opts)
      run = { text = text, opts = opts }
      return View()
    end

    fuzzy_searcher.open("Write-Output hello")
    test.is_nil(run)
    core.fuzzy_searcher_active_view:close()

    test.ok(command.perform_with_context("shell:run-command", {
      source_pane = pane, source_view = source, placement = "current",
    }))
    local picker = core.fuzzy_searcher_active_view
    set_query(picker, "!Write-Output hello")
    test.equal(#picker.results, 1)
    test.equal(picker.results[1].kind, "shell_command")
    picker:confirm(false)

    test.equal(run.text, "Write-Output hello")
    test.equal(run.opts.cwd, common.normalize_path(context.folder))
    test.same(fuzzy_searcher._test.prompt_history("!"), {})
  end)
end)
