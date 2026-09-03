local command = require "core.command"
local common = require "core.common"
local core = require "core"
local Editor = require "core.editor"
local panes = require "core.panes"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local View = require "core.view"
local view_icons = require "core.view_icons"

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
    context.detached = context.root .. "-detached"
    context.detached_file = context.detached .. PATHSEP .. "detached.txt"
    test.ok(common.mkdirp(context.folder))
    test.ok(common.mkdirp(context.detached))
    local fp = assert(io.open(context.file, "wb"))
    fp:write("test\n")
    fp:close()
    fp = assert(io.open(context.detached_file, "wb"))
    fp:write("detached\n")
    fp:close()
    core.projects = { Project(context.root) }
    project_paths.configure_workspace {}
    fuzzy_searcher._test.clear_prompt_history()
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    terminal.open = context.terminal_open
    command_slots.run_once = context.run_once
    panes.reset_for_tests()
    project_paths.configure_workspace {}
    core.projects = context.projects
    if context.cwd then pcall(system.chdir, context.cwd) end
    if system.get_file_info(context.root) then
      local ok, err = common.rm(context.root, true)
      test.ok(ok, err)
    end
    if system.get_file_info(context.detached) then
      local ok, err = common.rm(context.detached, true)
      test.ok(ok, err)
    end
  end)

  test.it("shows raw launcher identifiers in the Command Palette", function()
    fuzzy_searcher.open(">file tree path")
    local picker = core.fuzzy_searcher_active_view
    local found
    for _, result in ipairs(picker.results) do
      if result.command == "filetree:open_at_choose_path" then found = result; break end
    end
    test.not_nil(found)
    test.equal(found.label, "filetree:open_at_choose_path")
    test.equal(found.info, nil)
    test.equal(command.get_metadata(found.command).supports_placement, true)
    test.ok(command.get_metadata(found.command).opens_view)
    local icon = test.not_nil(view_icons.get("filetree"))
    local old_draw_text = renderer.draw_text
    local drawn = {}
    renderer.draw_text = function(_, glyph) drawn[glyph] = true end
    local ok, err = pcall(function()
      local width = view_icons.draw(icon, 0, 0, 20)
      view_icons.draw_opener_badge(0, 0, width, 20)
    end)
    renderer.draw_text = old_draw_text
    test.ok(ok, err)
    test.ok(drawn.d)
    test.ok(drawn["]"])
  end)

  test.it("marks View constructors with their prefix icon", function()
    local openers = {
      "command_output:run_shell_command",
      "diff:open",
      "editor:open",
      "filetree:open_at_current_path",
      "fuzzy:open_files",
      "git:open_log",
      "log:open",
      "project_paths:open",
      "settings:open",
      "terminal:open",
    }
    for _, name in ipairs(openers) do
      local metadata = test.not_nil(command.get_metadata(name), name)
      test.ok(metadata.opens_view, name)
      test.not_nil(view_icons.get(name:match("^([^:]+):")), name)
    end
  end)

  test.it("exposes Diff comparison actions in the Command Palette", function()
    local compare_commands = {
      "diff:select_text_for_compare",
      "diff:compare_text_with_selected",
      "diff:select_file_for_compare",
      "diff:compare_file_with_selected",
      "diff:compare_selection_with_clipboard",
      "diff:compare_file_with_clipboard",
    }
    for _, name in ipairs(compare_commands) do
      local metadata = test.not_nil(command.get_metadata(name), name)
      test.equal(metadata.palette, true, name)
    end
  end)

  test.it("offers selection comparisons for a selected Editor", function(context)
    local editor = Editor(core.open_buffer(context.file))
    editor.buffer:set_selection(1, 1, 1, 5)
    core.active_view = editor

    local valid = {}
    for _, name in ipairs(command.get_all_valid()) do valid[name] = true end
    for _, name in ipairs {
      "diff:select_text_for_compare",
      "diff:compare_selection_with_clipboard",
      "diff:compare_file_with_clipboard",
    } do
      test.ok(valid[name], name)
    end
  end)

  test.it("uses the current File Tree command names and search keywords", function()
    test.not_nil(command.map["filetree:apply_changes"])
    test.is_nil(command.map["filetree:apply"])
    test.not_nil(command.map["filetree:open_at_current_path"])
    test.is_nil(command.map["filetree:open"])
    test.is_nil(command.map["filetree:open_at_path"])
    test.is_nil(command.map["filetree:open_at_current_file"])
    test.is_nil(command.map["filetree:reveal_current_file"])
    test.is_nil(command.map["filetree:reveal_path"])

    local metadata = test.not_nil(command.get_metadata("filetree:open_at_current_path"))
    test.ok(metadata.opens_view)
    local keywords = {}
    for _, keyword in ipairs(metadata.keywords or {}) do keywords[keyword] = true end
    test.ok(keywords.reveal)
  end)

  test.it("reveals an Editor file with open at current path", function(context)
    local source = View()
    source.path = context.file
    local pane = panes.create { factory = function() return source end }

    test.ok(command.perform_with_context("filetree:open_at_current_path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local tree = pane.current_view
    test.equal(tree.root_dir, common.normalize_path(context.root))
    local entry = tree:entry_for_line(tree.buffer:get_selection(true))
    test.ok(entry and common.path_equals(entry.abs, context.file))
  end)

  test.it("opens a source directory with open at current path", function(context)
    local source = View()
    source.current_dir = context.folder
    local pane = panes.create { factory = function() return source end }

    test.ok(command.perform_with_context("filetree:open_at_current_path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local tree = pane.current_view
    test.equal(tree.root_dir, common.normalize_path(context.root))
    local entry = tree:entry_for_line(tree.buffer:get_selection(true))
    test.ok(entry and common.path_equals(entry.abs, context.folder))
  end)

  test.it("opens a selected File Tree folder as the root", function(context)
    local source = test.not_nil(filetree.new(context.root))
    local _, _, snapshot = source:build_entries(false)
    local selected
    for _, entry in pairs(snapshot.by_line) do
      if common.path_equals(entry.abs, context.folder) then selected = entry; break end
    end
    selected = test.not_nil(selected)
    source.buffer:set_selection(selected.line, 1)
    local pane = panes.create { factory = function() return source end }

    test.ok(command.perform_with_context("filetree:open_at_current_path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local tree = pane.current_view
    test.equal(tree.root_dir, common.normalize_path(context.root))
    local entry = tree:entry_for_line(tree.buffer:get_selection(true))
    test.ok(entry and common.path_equals(entry.abs, context.folder))
  end)

  test.it("keeps an outside file rooted at its parent", function(context)
    local source = View()
    source.path = context.detached_file
    local pane = panes.create { factory = function() return source end }

    test.ok(command.perform_with_context("filetree:open_at_current_path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local tree = pane.current_view
    test.equal(tree.root_dir, common.normalize_path(context.detached))
    local entry = tree:entry_for_line(tree.buffer:get_selection(true))
    test.ok(entry and common.path_equals(entry.abs, context.detached_file))
  end)

  test.it("reveals External and Vendored Project Directory files from the Root Project", function(context)
    local targets = {}
    local spec = { external = {}, vendored = {} }
    for _, role in ipairs({ "external", "vendored" }) do
      local folder = context.root .. PATHSEP .. role
      local path = folder .. PATHSEP .. role .. ".lua"
      test.ok(common.mkdirp(folder))
      local fp = assert(io.open(path, "wb"))
      fp:write("return true\n")
      fp:close()
      spec[role][1] = { path = folder, label = role }
      targets[#targets + 1] = path
    end
    project_paths.configure_workspace(spec)

    for _, path in ipairs(targets) do
      panes.reset_for_tests()
      local source = View()
      source.path = path
      local pane = panes.create { factory = function() return source end }

      test.ok(command.perform_with_context("filetree:open_at_current_path", {
        source_pane = pane, source_view = source, placement = "current",
      }))

      local tree = pane.current_view
      test.equal(tree.root_dir, common.normalize_path(context.root))
      local entry = tree:entry_for_line(tree.buffer:get_selection(true))
      test.ok(entry and common.path_equals(entry.abs, path))
    end
  end)

  test.it("opens a Standard Editor without a Tab icon", function()
    local source = View()
    local pane = panes.create { factory = function() return source end }
    test.ok(command.perform_with_context("editor:open", {
      source_pane = pane,
      source_view = source,
      placement = "current",
    }))
    test.ok(pane.current_view:extends(Editor))
    test.equal(pane.current_view.view_icon, nil)
  end)

  test.it("gives every non-core palette prefix a View Icon", function()
    local missing = {}
    for name, entry in pairs(command.map) do
      local metadata = entry.metadata
      local prefix = name:match("^([^:]+):")
      if metadata and metadata.palette and prefix ~= "core" and not view_icons.get(prefix) then
        missing[#missing + 1] = name
      end
    end
    table.sort(missing)
    test.same(missing, {})
  end)

  test.it("reuses a matching File Tree from the source Pane history", function(context)
    local source = View()
    local pane = panes.create { factory = function() return source end }
    local invocation = { source_pane = pane, source_view = source, placement = "current" }

    test.ok(command.perform_with_context("filetree:open_at_project_root", invocation))
    local tree = pane.current_view
    test.equal(tree.root_dir, common.normalize_path(context.root))
    local replacement = View()
    panes.present(replacement, { pane = pane })

    invocation.source_view = replacement
    test.ok(command.perform_with_context("filetree:open_at_project_root", invocation))
    test.equal(pane.current_view, tree)
  end)

  test.it("uses alternate Command Palette activation for split-capable Views", function(context)
    local source = View()
    panes.create { factory = function() return source end }
    fuzzy_searcher.open(">file tree project root")
    local picker = core.fuzzy_searcher_active_view
    for index, result in ipairs(picker.results) do
      if result.command == "filetree:open_at_project_root" then picker.selected = index; break end
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

  test.it("opens a File Tree at a selected file path", function(context)
    local source = View()
    source.current_dir = context.root
    local pane = panes.create { factory = function() return source end }
    test.ok(command.perform_with_context("filetree:open_at_choose_path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local picker = core.fuzzy_searcher_active_view
    set_query(picker, context.file)
    local selected
    for index, result in ipairs(picker.results) do
      local path = result.abs_path or result.file or result.path
      if path and common.path_equals(path, context.file) then
        selected = result
        picker.selected = index
        break
      end
    end
    test.not_nil(selected)
    test.equal(selected.is_folder, false)
    picker:confirm(false)

    test.equal(pane.current_view.root_dir, common.normalize_path(context.folder))
    local entry = pane.current_view:entry_for_line(pane.current_view.buffer:get_selection(true))
    test.ok(entry and common.path_equals(entry.abs, context.file))
    test.equal(core.root_project().path, common.normalize_path(context.root))
  end)

  test.it("keeps File Picker mode independent of its query text", function(context)
    local source = View()
    local pane = panes.create { factory = function() return source end }
    test.ok(command.perform_with_context("filetree:open_at_choose_path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local picker = core.fuzzy_searcher_active_view
    set_query(picker, context.folder)
    local selected
    for index, result in ipairs(picker.results) do
      local path = result.abs_path or result.file or result.path
      if path and common.path_equals(path, context.folder) then
        selected = result
        picker.selected = index
        break
      end
    end
    test.not_nil(selected)
    picker:confirm(false)

    test.equal(pane.current_view.root_dir, common.normalize_path(context.folder))
  end)

  test.it("opens a Terminal at a selected folder with split placement", function(context)
    local source = View()
    local pane = panes.create { factory = function() return source end }
    local options
    terminal.open = function(value) options = value; return View() end
    test.ok(command.perform_with_context("terminal:open_at_path", {
      source_pane = pane, source_view = source, placement = "current",
    }))

    local picker = core.fuzzy_searcher_active_view
    set_query(picker, context.folder)
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

    test.ok(command.perform_with_context("command_output:run_shell_command", {
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
